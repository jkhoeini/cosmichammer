import Cocoa
import CLua
import Lua
import HSDSTCore
import Carbon
import CoreServices
import os.log

private var defaultContentTypes: [String]?

// MARK: - ObjC bridge protocol

/// Mirror of the HSOpenFileDelegate protocol declared in MJAppDelegate.h.
/// The ObjC header is compiled inside the HSExtensions (ObjC) target and is
/// not visible from the pure-Swift HSSwiftExtensions target, so we redeclare
/// the protocol here with the same ObjC name so that the runtime recognises
/// conformance.
@objc protocol HSOpenFileDelegate: NSObjectProtocol {
    @objc func callback(withURL openUrl: String, senderPID pid: pid_t)
}

/// Minimal @objc protocol exposing the MJAppDelegate properties we need.
@objc protocol HSAppDelegateURLAccess: NSObjectProtocol {
    @objc var startupEvents: [NSAppleEventDescriptor] { get set }
    @objc var startupFile: String? { get set }
    @objc var openFileDelegate: (any NSObjectProtocol)? { get set }
}

// MARK: - URL parsing (internal, testable)

/// Result of normalizing and parsing a raw URL string.
struct URLParseResult {
    let scheme: String?
    let host: String?
    let params: [String: String]
    let fullURL: String
}

/// Normalize a raw URL string (handling bare paths) and parse it into
/// components.  Returns `nil` when the string cannot be parsed as a URL.
func parseURLEvent(_ rawURL: String) -> URLParseResult? {
    var urlString = rawURL
    if urlString.hasPrefix("/") {
        let fileURL = URL(fileURLWithPath: urlString)
        urlString = fileURL.absoluteString
    }

    guard let url = URL(string: urlString) else { return nil }

    let query = url.query ?? ""
    let queryPairs = query.components(separatedBy: "&")
    var params: [String: String] = [:]

    for queryPair in queryPairs {
        let bits = queryPair.components(separatedBy: "=")
        if bits.count != 2 { continue }
        let key = bits[0].removingPercentEncoding ?? bits[0]
        let value = bits[1].removingPercentEncoding ?? bits[1]
        params[key] = value
    }

    return URLParseResult(
        scheme: url.scheme?.lowercased(),
        host: url.host?.lowercased(),
        params: params,
        fullURL: url.absoluteString
    )
}

// MARK: - HSURLEventHandler

private class HSURLEventHandler: NSObject, HSOpenFileDelegate {
    var appleEventManager: NSAppleEventManager?
    var fnCallback: LuaValue?
    var generation: UInt64 = 0
    var restoreHandlers: NSMutableDictionary = NSMutableDictionary()
    weak var appDelegate: (any HSAppDelegateURLAccess)?

    override init() {
        super.init()

        appleEventManager = NSAppleEventManager.shared()
        appleEventManager?.setEventHandler(self,
                                           andSelector: #selector(handleAppleEvent(_:withReplyEvent:)),
                                           forEventClass: AEEventClass(kInternetEventClass),
                                           andEventID: AEEventID(kAEGetURL))

        let delegate = NSApplication.shared.delegate as? (any HSAppDelegateURLAccess)
        delegate?.openFileDelegate = self
        appDelegate = delegate
    }

    func gc(withState L: UnsafeMutablePointer<lua_State>!) {

        appleEventManager?.removeEventHandler(forEventClass: AEEventClass(kInternetEventClass),
                                              andEventID: AEEventID(kAEGetURL))

        appDelegate?.openFileDelegate = nil

        fnCallback = nil

        for key in restoreHandlers.allKeys {
            guard let scheme = key as? NSString,
                  let bundleID = restoreHandlers[key] as? NSString else { continue }

            LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)

            if scheme == "http" || scheme == "https" {
                if let contentTypes = defaultContentTypes {
                    for type in contentTypes {
                        let status = LSSetDefaultRoleHandlerForContentType(type as CFString, LSRolesMask.viewer, bundleID as CFString)
                        if status != noErr {
                            os_log(.error, "Unable to set role handler for %{public}s: %{public}s", type,
                                   NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil).localizedDescription)
                        }
                    }
                }
            }
        }
        restoreHandlers.removeAllObjects()
    }

    func handleStartupEvents() {
        if let events = appDelegate?.startupEvents, !events.isEmpty {
            for event in events {
                handleAppleEvent(event, withReplyEvent: nil)
            }
            appDelegate?.startupEvents.removeAll()
        }

        if let startupFile = appDelegate?.startupFile {
            eventHandler?.callback(withURL: startupFile, senderPID: -1)
            appDelegate?.startupFile = nil
        }
    }

    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor?) {
        // Workaround for macOS 10.15+ revealing Dock icon before receiving Apple Events
        MJDockIconSetVisible(MJDockIconVisible())

        // Use the event parameter directly — currentAppleEvent is nil when
        // replaying stored startup events via handleStartupEvents().
        let appleEventDescriptor = event
        let processSerialDescriptor = appleEventDescriptor.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        let pidDescriptor = processSerialDescriptor?.coerce(toDescriptorType: typeKernelProcessID)

        let pid: pid_t
        if let pidDesc = pidDescriptor, let data = pidDesc.data as NSData? {
            pid = data.bytes.assumingMemoryBound(to: pid_t.self).pointee
        } else {
            pid = -1
        }

        callback(withURL: event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? "",
                 senderPID: pid)
    }

    func callback(withURL openUrl: String, senderPID pid: pid_t) {
        guard lua_isStateGenerationValid(generation) else { return }
        let L = lua_getCurrentState()!

        guard let cb = fnCallback else {
            os_log(.info, "%{public}s", "hs.urlevent callbackWithURL received a URL with no callback set: \(openUrl)")
            return
        }

        guard let parsed = parseURLEvent(openUrl) else {
            os_log(.error, "ERROR: Unable to parse '%{public}s' as a URL", openUrl)
            return
        }

        let pairs = NSMutableDictionary(dictionary: parsed.params)

        cb.push(onto: L)
        lua_pushany(L, parsed.scheme as NSString?)
        lua_pushany(L, parsed.host as NSString?)
        lua_pushany(L, pairs)
        lua_pushany(L, parsed.fullURL as NSString)
        L.push(lua_Integer(pid))
        if lua_pcall(L, 5, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
}

private var eventHandler: HSURLEventHandler?

// MARK: - C / Lua bridge functions

// Rather than manage complex callback state from C, we just have one path into Lua for all events, and events are directed to their callbacks from there
private func urleventSetCallback(_ L: LuaState) throws -> CInt {

    luaL_checktype(L, 1, LUA_TFUNCTION)
    eventHandler?.fnCallback = L.ref(index: 1)
    eventHandler?.generation = lua_currentStateGeneration()

    return 0
}

/// hs.urlevent.setRestoreHandler(scheme, bundleID)
/// Function
/// Stores a URL handler that will be restored when Cosmic Hammer or reloads its config
///
/// Parameters:
///  * scheme - A string containing the URL scheme to change. This must be 'http' (although both http:// and https:// URLs will be affected)
///  * bundleID - A string containing an application bundle identifier (e.g. 'com.apple.Safari') for the application to set as the default handler when Cosmic Hammer exits or reloads its config
///
/// Returns:
///  * None
///
/// Notes:
///  * You don't have to call this function if you want Cosmic Hammer to permanently be your default handler. Only use this if you want the handler to be automatically reverted to something else when Cosmic Hammer exits/reloads.
private func urleventsetRestoreHandler(_ L: LuaState) throws -> CInt {

    eventHandler?.restoreHandlers[lua_tovalue(L, at: 1)!] = lua_tovalue(L, at: 2)

    return 0
}

/// hs.urlevent.setDefaultHandler(scheme[, bundleID])
/// Function
/// Sets the default system handler for URLs of a given scheme
///
/// Parameters:
///  * scheme - A string containing the URL scheme to change. This must be 'http' or 'https' (although entering either will change the handler for both)
///  * bundleID - An optional string containing an application bundle identifier for the application to set as the default handler. Defaults to `org.cosmic-hammer.CosmicHammer`.
///
/// Returns:
///  * None
///
/// Notes:
///  * Changing the default handler for http/https URLs will display a system prompt asking the user to confirm the change
private func urleventsetDefaultHandler(_ L: LuaState) throws -> CInt {

    let scheme = String(cString: lua_tostring(L, 1)!).lowercased()
    var bundleID = Bundle.main.bundleIdentifier ?? "org.cosmic-hammer.CosmicHammer"

    if lua_type(L, 2) == LUA_TSTRING {
        bundleID = String(cString: lua_tostring(L, 2)!)
    }

    let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
    if status != noErr {
        os_log(.error, "%{public}s", "hs.urlevent.setDefaultHandler() unable to set the handler for \(scheme) to \(bundleID): \(NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil).localizedDescription)")
    } else {
        eventHandler?.restoreHandlers.removeObject(forKey: scheme)
    }

    if scheme == "http" || scheme == "https" {
        // If we're dealing with http/https, also register ourselves for various filetypes that are relevant
        if let contentTypes = defaultContentTypes {
            for type in contentTypes {
                let typeStatus = LSSetDefaultRoleHandlerForContentType(type as CFString, LSRolesMask.viewer, bundleID as CFString)
                if typeStatus != noErr {
                    os_log(.info, "%{public}s", "Unable to set role handler for \(type): \(NSError(domain: NSOSStatusErrorDomain, code: Int(typeStatus), userInfo: nil).localizedDescription)")
                }
            }
        }

        // Handle any startup events for http/https/file
        eventHandler?.handleStartupEvents()
    }

    return 0
}

/// hs.urlevent.getDefaultHandler(scheme) -> string
/// Function
/// Gets the application bundle identifier of the application currently registered to handle a URL scheme
///
/// Parameters:
///  * scheme - A string containing a URL scheme (e.g. 'http')
///
/// Returns:
///  * A string containing the bundle identifier of the current default application
private func urleventgetDefaultHandler(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let scheme = String(cString: lua_tostring(L, 1)!)
    if let bundleID = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() {
        L.push(bundleID as String)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.urlevent.getAllHandlersForScheme(scheme) -> table
/// Function
/// Gets all of the application bundle identifiers of applications able to handle a URL scheme
///
/// Parameters:
///  * scheme - A string containing a URL scheme (e.g. 'http')
///
/// Returns:
///  * A table containing the bundle identifiers of all applications that can handle the scheme
private func urleventgetAllHandlersForScheme(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let scheme = String(cString: lua_tostring(L, 1)!)
    let array = LSCopyAllHandlersForURLScheme(scheme as CFString)?.takeRetainedValue()

    var i: lua_Integer = 1
    lua_newtable(L)

    if let handlers = array as? [String] {
        for bundleID in handlers {
            L.push(i)
            L.push(bundleID)
            lua_settable(L, -3)
            i += 1
        }
    }

    return 1
}

/// hs.urlevent.openURLWithBundle(url, bundleID) -> boolean
/// Function
/// Opens a URL with a specified application
///
/// Parameters:
///  * url - A string containing a URL
///  * bundleID - A string containing an application bundle identifier (e.g. "com.apple.Safari")
///
/// Returns:
///  * True if the application was launched successfully, otherwise false
private func urleventopenURLWithBundle(_ L: LuaState) throws -> CInt {

    var result = false

    let urlString = lua_tovalue(L, at: 1) as? String ?? ""
    if let url = URL(string: urlString) {
        let bundleID = String(cString: lua_tostring(L, 2)!)
        result = NSWorkspace.shared.open([url],
                                         withAppBundleIdentifier: bundleID,
                                         options: .default,
                                         additionalEventParamDescriptor: nil,
                                         launchIdentifiers: nil)
    }

    L.push(result)
    return 1
}

private func urlevent_setup() {
    eventHandler = HSURLEventHandler()

    defaultContentTypes = [
        kUTTypeURL as String,
        kUTTypeFileURL as String,
        kUTTypeText as String,
    ]
}

// MARK: - Lua/hs glue

private func urlevent_gc(_ L: LuaState) throws -> CInt {
    eventHandler?.gc(withState: L)
    eventHandler = nil

    return 0
}

// MARK: - Module entry point

/* NOTE: The substring "hs_urlevent_internal" in the following function's name
         must match the require-path of this file, i.e. "hs.urlevent.internal". */

@_cdecl("luaopen_hs_liburlevent")
public func luaopen_hs_liburlevent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        urlevent_setup()

        // Create module table
        lua_createtable(L, 0, 6)
        L.push(urleventSetCallback)
        lua_setfield(L, -2, "setCallback")
        L.push(urleventsetRestoreHandler)
        lua_setfield(L, -2, "setRestoreHandler")
        L.push(urleventsetDefaultHandler)
        lua_setfield(L, -2, "setDefaultHandler")
        L.push(urleventgetDefaultHandler)
        lua_setfield(L, -2, "getDefaultHandler")
        L.push(urleventgetAllHandlersForScheme)
        lua_setfield(L, -2, "getAllHandlersForScheme")
        L.push(urleventopenURLWithBundle)
        lua_setfield(L, -2, "openURLWithBundle")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(urlevent_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
