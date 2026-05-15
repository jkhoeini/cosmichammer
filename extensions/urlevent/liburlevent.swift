import Cocoa
import Carbon
import CoreServices
import LuaSkin

private var refTable: LSRefTable = 0
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
    @objc var startupEvent: NSAppleEventDescriptor? { get set }
    @objc var startupFile: String? { get set }
    @objc var openFileDelegate: (any NSObjectProtocol)? { get set }
}

// MARK: - HSURLEventHandler

private class HSURLEventHandler: NSObject, HSOpenFileDelegate {
    var appleEventManager: NSAppleEventManager?
    var fnCallback: Int32 = LUA_NOREF
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
        let skin = LuaSkin.skin(with: L)

        appleEventManager?.removeEventHandler(forEventClass: AEEventClass(kInternetEventClass),
                                              andEventID: AEEventID(kAEGetURL))

        appDelegate?.openFileDelegate = nil

        fnCallback = skin.luaUnref(refTable, ref: fnCallback)

        for key in restoreHandlers.allKeys {
            guard let scheme = key as? NSString,
                  let bundleID = restoreHandlers[key] as? NSString else { continue }

            LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)

            if scheme == "http" || scheme == "https" {
                if let contentTypes = defaultContentTypes {
                    for type in contentTypes {
                        let status = LSSetDefaultRoleHandlerForContentType(type as CFString, LSRolesMask.viewer, bundleID as CFString)
                        if status != noErr {
                            NSLog("Unable to set role handler for %@: %@", type,
                                  NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil).localizedDescription)
                        }
                    }
                }
            }
        }
        restoreHandlers.removeAllObjects()
    }

    func handleStartupEvents() {
        if let startupEvent = appDelegate?.startupEvent {
            handleAppleEvent(startupEvent, withReplyEvent: nil)
            appDelegate?.startupEvent = nil
        }

        if let startupFile = appDelegate?.startupFile {
            eventHandler?.callback(withURL: startupFile, senderPID: -1)
            appDelegate?.startupFile = nil
        }
    }

    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor?) {
        // Workaround for macOS 10.15+ revealing Dock icon before receiving Apple Events
        MJDockIconSetVisible(MJDockIconVisible())

        // Get the process id for the application that sent the current Apple Event
        let appleEventDescriptor = NSAppleEventManager.shared().currentAppleEvent
        let processSerialDescriptor = appleEventDescriptor?.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
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
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!
        _lua_stackguard_entry(L)

        if fnCallback == LUA_NOREF || fnCallback == LUA_REFNIL {
            skin.logWarn("hs.urlevent callbackWithURL received a URL with no callback set: \(openUrl)")
            _lua_stackguard_exit(L)
            return
        }

        var urlString = openUrl
        if urlString.hasPrefix("/") {
            urlString = "file://\(urlString)"
            urlString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
        }

        guard let url = URL(string: urlString) else {
            NSLog("ERROR: Unable to parse '%@' as a URL", urlString)
            _lua_stackguard_exit(L)
            return
        }

        let query = url.query ?? ""
        let queryPairs = query.components(separatedBy: "&")
        let pairs = NSMutableDictionary()

        for queryPair in queryPairs {
            let bits = queryPair.components(separatedBy: "=")
            if bits.count != 2 { continue }

            let key = bits[0].removingPercentEncoding ?? bits[0]
            let value = bits[1].removingPercentEncoding ?? bits[1]
            pairs[key] = value
        }

        skin.pushLuaRef(refTable, ref: fnCallback)
        skin.pushNSObject(url.scheme?.lowercased() as NSString?)
        skin.pushNSObject(url.host?.lowercased() as NSString?)
        skin.pushNSObject(pairs)
        skin.pushNSObject(url.absoluteString as NSString)
        lua_pushinteger(L, lua_Integer(pid))
        skin.protectedCallAndError("hs.urlevent callback for \(url.absoluteString)", nargs: 5, nresults: 0)
        _lua_stackguard_exit(L)
    }
}

private var eventHandler: HSURLEventHandler?

// MARK: - C / Lua bridge functions

// Rather than manage complex callback state from C, we just have one path into Lua for all events, and events are directed to their callbacks from there
private func urleventSetCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    luaL_checktype(L, 1, LUA_TFUNCTION)
    lua_pushvalue(L, 1)
    eventHandler?.fnCallback = skin.luaRef(refTable)

    return 0
}

/// hs.urlevent.setRestoreHandler(scheme, bundleID)
/// Function
/// Stores a URL handler that will be restored when Hammerspoon or reloads its config
///
/// Parameters:
///  * scheme - A string containing the URL scheme to change. This must be 'http' (although both http:// and https:// URLs will be affected)
///  * bundleID - A string containing an application bundle identifier (e.g. 'com.apple.Safari') for the application to set as the default handler when Hammerspoon exits or reloads its config
///
/// Returns:
///  * None
///
/// Notes:
///  * You don't have to call this function if you want Hammerspoon to permanently be your default handler. Only use this if you want the handler to be automatically reverted to something else when Hammerspoon exits/reloads.
private func urleventsetRestoreHandler(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)

    eventHandler?.restoreHandlers[skin.toNSObject(atIndex: 1)!] = skin.toNSObject(atIndex: 2)

    return 0
}

/// hs.urlevent.setDefaultHandler(scheme[, bundleID])
/// Function
/// Sets the default system handler for URLs of a given scheme
///
/// Parameters:
///  * scheme - A string containing the URL scheme to change. This must be 'http' or 'https' (although entering either will change the handler for both)
///  * bundleID - An optional string containing an application bundle identifier for the application to set as the default handler. Defaults to `org.hammerspoon.Hammerspoon`.
///
/// Returns:
///  * None
///
/// Notes:
///  * Changing the default handler for http/https URLs will display a system prompt asking the user to confirm the change
private func urleventsetDefaultHandler(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    let scheme = String(cString: lua_tostring(L, 1)!).lowercased()
    var bundleID = Bundle.main.bundleIdentifier ?? "org.hammerspoon.Hammerspoon"

    if lua_type(L, 2) == LUA_TSTRING {
        bundleID = String(cString: lua_tostring(L, 2)!)
    }

    let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
    if status != noErr {
        skin.logError("hs.urlevent.setDefaultHandler() unable to set the handler for \(scheme) to \(bundleID): \(NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil).localizedDescription)")
    } else {
        eventHandler?.restoreHandlers.removeObject(forKey: scheme)
    }

    if scheme == "http" || scheme == "https" {
        // If we're dealing with http/https, also register ourselves for various filetypes that are relevant
        if let contentTypes = defaultContentTypes {
            for type in contentTypes {
                let typeStatus = LSSetDefaultRoleHandlerForContentType(type as CFString, LSRolesMask.viewer, bundleID as CFString)
                if typeStatus != noErr {
                    skin.logWarn("Unable to set role handler for \(type): \(NSError(domain: NSOSStatusErrorDomain, code: Int(typeStatus), userInfo: nil).localizedDescription)")
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
private func urleventgetDefaultHandler(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let scheme = String(cString: lua_tostring(L, 1)!)
    if let bundleID = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() {
        lua_pushstring(L, (bundleID as String))
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
private func urleventgetAllHandlersForScheme(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let scheme = String(cString: lua_tostring(L, 1)!)
    let array = LSCopyAllHandlersForURLScheme(scheme as CFString)?.takeRetainedValue()

    var i: lua_Integer = 1
    lua_newtable(L)

    if let handlers = array as? [String] {
        for bundleID in handlers {
            lua_pushinteger(L, i)
            lua_pushstring(L, bundleID)
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
private func urleventopenURLWithBundle(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)

    var result = false

    let urlString = skin.toNSObject(atIndex: 1) as? String ?? ""
    if let url = URL(string: urlString) {
        let bundleID = String(cString: lua_tostring(L, 2)!)
        result = NSWorkspace.shared.open([url],
                                         withAppBundleIdentifier: bundleID,
                                         options: .default,
                                         additionalEventParamDescriptor: nil,
                                         launchIdentifiers: nil)
    }

    lua_pushboolean(L, result ? 1 : 0)
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

private func urlevent_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    eventHandler?.gc(withState: L)
    eventHandler = nil

    return 0
}

// MARK: - luaL_Reg tables

private var urleventlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("setCallback"), func: { urleventSetCallback($0) }),
    luaL_Reg(name: strdup("setRestoreHandler"), func: { urleventsetRestoreHandler($0) }),
    luaL_Reg(name: strdup("setDefaultHandler"), func: { urleventsetDefaultHandler($0) }),
    luaL_Reg(name: strdup("getDefaultHandler"), func: { urleventgetDefaultHandler($0) }),
    luaL_Reg(name: strdup("getAllHandlersForScheme"), func: { urleventgetAllHandlersForScheme($0) }),
    luaL_Reg(name: strdup("openURLWithBundle"), func: { urleventopenURLWithBundle($0) }),
    luaL_Reg(name: nil, func: nil),
]

private var urlevent_gclib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: { urlevent_gc($0) }),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

/* NOTE: The substring "hs_urlevent_internal" in the following function's name
         must match the require-path of this file, i.e. "hs.urlevent.internal". */

@_cdecl("luaopen_hs_liburlevent")
public func luaopen_hs_liburlevent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    urlevent_setup()

    refTable = skin.registerLibrary("hs.urlevent", functions: &urleventlib, metaFunctions: &urlevent_gclib)

    return 1
}
