import Cocoa
import CLua
import os.log

private let USERDATA_TAG: StaticString = "hs.bonjour"
private var USERDATA_TAG_STR: String { "\(USERDATA_TAG)" }
private var refTable: Int32 = Int32(LUA_NOREF)

// MARK: - Support Functions and Classes

private func netServiceErrorToString(_ error: [String: Any]) -> String {
    var message = "unrecognized error dictionary:\(error)"

    if let errorCode = error[NetService.errorCode as String] as? NSNumber {
        switch errorCode.intValue {
        case Int(NetService.ErrorCode.activityInProgress.rawValue):
            message = "activity in progress; cannot process new request"
        case Int(NetService.ErrorCode.badArgumentError.rawValue):
            message = "invalid argument"
        case Int(NetService.ErrorCode.cancelledError.rawValue):
            message = "request was cancelled"
        case Int(NetService.ErrorCode.collisionError.rawValue):
            message = "name already in use"
        case Int(NetService.ErrorCode.invalidError.rawValue):
            message = "service improperly configured"
        case Int(NetService.ErrorCode.notFoundError.rawValue):
            message = "service could not be found"
        case Int(NetService.ErrorCode.timeoutError.rawValue):
            message = "timed out"
        case Int(NetService.ErrorCode.unknownError.rawValue):
            message = "an unknown error has occurred"
        default:
            message = "unrecognized error code:\(errorCode)"
        }
    }
    return message
}

@objc private class HSNetServiceBrowser: NetServiceBrowser, NetServiceBrowserDelegate {
    var callbackRef: Int32 = Int32(LUA_NOREF)
    var selfRefCount: Int = 0

    override init() {
        super.init()
        self.delegate = self
    }

    func stop(withState L: UnsafeMutablePointer<lua_State>!) {
        super.stop()
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, callbackRef)

        callbackRef = LUA_NOREF
    }

    func performCallback(with argument: Any?) {
        if callbackRef != Int32(LUA_NOREF) {
            let L = lua_getCurrentState()!
            var argCount: Int32 = 1
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
            lua_pushany(L, self)
            if let argument = argument {
                if let args = argument as? [Any] {
                    for obj in args {
                        lua_pushany(L, obj as? NSObject)
                    }
                    argCount += Int32(args.count)
                } else {
                    lua_pushany(L, argument as? NSObject)
                    argCount += 1
                }
            }
            if lua_pcall(L, argCount, 0, 0) != LUA_OK {
                os_log(.error, "%{public}s", "\(USERDATA_TAG):callback error:\(String(cString: lua_tostring(L, -1)!))")
                lua_pop(L, -1)
            }
        }
    }

    // MARK: Delegate Methods

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFindDomain domainString: String,
                           moreComing: Bool) {
        performCallback(with: ["domain", true, domainString, moreComing] as [Any])
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemoveDomain domainString: String,
                           moreComing: Bool) {
        performCallback(with: ["domain", false, domainString, moreComing] as [Any])
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        performCallback(with: ["error", netServiceErrorToString(errorDict as [String: Any])] as [Any])
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        performCallback(with: ["service", true, service, moreComing] as [Any])
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        performCallback(with: ["service", false, service, moreComing] as [Any])
    }
}

// MARK: - Module Functions

/// hs.bonjour.new() -> browserObject
/// Constructor
/// Creates a new network service browser that finds published services on a network using multicast DNS.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a new browserObject or nil if an error occurs
private func browser_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let browser = HSNetServiceBrowser()
    lua_pushany(L, browser)
    return 1
}

// MARK: - Module Methods

/// hs.bonjour:includesPeerToPeer([value]) -> current value | browserObject
/// Method
/// Get or set whether to also browse over peer-to-peer Bluetooth and Wi-Fi, if available.
///
/// Parameters:
///  * `value` - an optional boolean, default false, value specifying whether to also browse over peer-to-peer Bluetooth and Wi-Fi, if available.
///
/// Returns:
///  * if `value` is provided, returns the browserObject; otherwise returns the current value for this property
///
/// Notes:
///  * This property must be set before initiating a search to have an effect.
private func browser_includesPeerToPeer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let browser: HSNetServiceBrowser = lua_tovalue(L, at: 1) as! HSNetServiceBrowser
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, browser.includesPeerToPeer ? 1 : 0)
    } else {
        browser.includesPeerToPeer = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.bonjour:findBrowsableDomains(callback) -> browserObject
/// Method
/// Return a list of zero-conf and bonjour domains visible to the users computer.
///
/// Parameters:
///  * `callback` - a function which will be invoked as visible domains are discovered. The function should accept the following parameters and return none:
///    * `browserObject`    - the userdata object for the browserObject which initiated the search
///    * `type`             - a string which will be 'domain' or 'error'
///      * if `type` == 'domain', the remaining arguments will be:
///        * `added`        - a boolean value indicating whether this callback invocation represents a newly discovered or added domain (true) or that the domain has been removed from the network (false)
///        * `domain`       - a string specifying the name of the domain discovered or removed
///        * `moreExpected` - a boolean value indicating whether or not the browser expects to discover additional domains or not.
///      * if `type` == 'error', the remaining arguments will be:
///        * `errorString`  - a string specifying the error which has occurred
///
/// Returns:
///  * the browserObject
///
/// Notes:
///  * This method returns domains which are visible to your machine; however, your machine may or may not be able to access or publish records within the returned domains. See  [hs.bonjour:findRegistrationDomains](#findRegistrationDomains)
///
///  * For most non-corporate network users, it is likely that the callback will only be invoked once for the `local` domain. This is normal. Corporate networks or networks including Linux machines using additional domains defined with Avahi may see additional domains as well, though most Avahi installations now use only 'local' by default unless specifically configured to do otherwise.
///
///  * When `moreExpected` becomes false, it is the macOS's best guess as to whether additional records are available.
///    * Generally macOS is fairly accurate in this regard concerning domain searches, so to reduce the impact on system resources, it is recommended that you use [hs.bonjour:stop](#stop) when this parameter is false
private func browser_searchForBrowsableDomains(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)

    luaL_checktype(L, 2, LUA_TFUNCTION)
    let browser: HSNetServiceBrowser = lua_tovalue(L, at: 1) as! HSNetServiceBrowser
    if browser.callbackRef != Int32(LUA_NOREF) { browser.stop(withState: L) }
    lua_pushvalue(L, 2)
    browser.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    browser.searchForBrowsableDomains()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.bonjour:findRegistrationDomains(callback) -> browserObject
/// Method
/// Return a list of zero-conf and bonjour domains this computer can register services in.
///
/// Parameters:
///  * `callback` - a function which will be invoked as domains are discovered. The function should accept the following parameters and return none:
///    * `browserObject`    - the userdata object for the browserObject which initiated the search
///    * `type`             - a string which will be 'domain' or 'error'
///      * if `type` == 'domain', the remaining arguments will be:
///        * `added`        - a boolean value indicating whether this callback invocation represents a newly discovered or added domain (true) or that the domain has been removed from the network (false)
///        * `domain`       - a string specifying the name of the domain discovered or removed
///        * `moreExpected` - a boolean value indicating whether or not the browser expects to discover additional domains or not.
///      * if `type` == 'error', the remaining arguments will be:
///        * `errorString`  - a string specifying the error which has occurred
///
/// Returns:
///  * the browserObject
///
/// Notes:
///  * This is the preferred method for accessing domains as it guarantees that the host machine can connect to services in the returned domains. Access to domains outside this list may be more limited. See also [hs.bonjour:findBrowsableDomains](#findBrowsableDomains)
///
///  * For most non-corporate network users, it is likely that the callback will only be invoked once for the `local` domain. This is normal. Corporate networks or networks including Linux machines using additional domains defined with Avahi may see additional domains as well, though most Avahi installations now use only 'local' by default unless specifically configured to do otherwise.
///
///  * When `moreExpected` becomes false, it is the macOS's best guess as to whether additional records are available.
///    * Generally macOS is fairly accurate in this regard concerning domain searches, so to reduce the impact on system resources, it is recommended that you use [hs.bonjour:stop](#stop) when this parameter is false
private func browser_searchForRegistrationDomains(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)

    luaL_checktype(L, 2, LUA_TFUNCTION)
    let browser: HSNetServiceBrowser = lua_tovalue(L, at: 1) as! HSNetServiceBrowser
    if browser.callbackRef != Int32(LUA_NOREF) { browser.stop(withState: L) }
    lua_pushvalue(L, 2)
    browser.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    browser.searchForRegistrationDomains()
    lua_pushvalue(L, 1)
    return 1
}

// hs.bonjour:findServices is documented with its wrapper in init.lua
private func browser_searchForServices(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let browser: HSNetServiceBrowser = lua_tovalue(L, at: 1) as! HSNetServiceBrowser
    var service = "_services._dns-sd._udp."
    var domain = ""
    switch lua_gettop(L) {
    case 2:
        luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)

        luaL_checktype(L, 2, LUA_TFUNCTION)
    case 3:
        service = lua_tovalue(L, at: 2) as! String
    default:
        service = lua_tovalue(L, at: 2) as! String
        domain = lua_tovalue(L, at: 3) as! String
    }
    if browser.callbackRef != Int32(LUA_NOREF) { browser.stop(withState: L) }
    lua_pushvalue(L, -1)
    browser.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    browser.searchForServices(ofType: service, inDomain: domain)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.bonjour:stop() -> browserObject
/// Method
/// Stops a currently running search or resolution for the browser object
///
/// Parameters:
///  * None
///
/// Returns:
///  * the browserObject
///
/// Notes:
///  * This method should be invoked when you have identified the services or hosts you require to reduce the consumption of system resources.
///  * Invoking this method on an already idle browser will do nothing
///
///  * In general, when your callback function for [hs.bonjour:findBrowsableDomains](#findBrowsableDomains), [hs.bonjour:findRegistrationDomains](#findRegistrationDomains), or [hs.bonjour:findServices](#findServices) receives false for the `moreExpected` parameter, you should invoke this method on the browserObject unless there are specific reasons not to. Possible reasons you might want to extend the life of the browserObject are documented within each method.
private func browser_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let browser: HSNetServiceBrowser = lua_tovalue(L, at: 1) as! HSNetServiceBrowser
    browser.stop(withState: L)
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

private func pushHSNetServiceBrowser(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    guard let value = obj as? HSNetServiceBrowser else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG_STR)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSNetServiceBrowserFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    if luaL_testudata(L, idx, USERDATA_TAG_STR) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG_STR)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        return Unmanaged<HSNetServiceBrowser>.fromOpaque(ptr.pointee).takeUnretainedValue()
    } else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushany(L, "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1))))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, USERDATA_TAG_STR) != nil && luaL_testudata(L, 2, USERDATA_TAG_STR) != nil {
        let obj1 = lua_tovalue(L, at: 1) as! HSNetServiceBrowser
        let obj2 = lua_tovalue(L, at: 2) as! HSNetServiceBrowser
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard luaL_testudata(L, 1, USERDATA_TAG_STR) != nil else { return 0 }
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG_STR)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let obj = Unmanaged<HSNetServiceBrowser>.fromOpaque(ptr.pointee).takeRetainedValue()
    obj.selfRefCount -= 1
    if obj.selfRefCount == 0 {
        obj.delegate = nil
        obj.stop(withState: L)
    }
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("includesPeerToPeer"),      func: browser_includesPeerToPeer),
    luaL_Reg(name: strdup("findBrowsableDomains"),    func: browser_searchForBrowsableDomains),
    luaL_Reg(name: strdup("findRegistrationDomains"), func: browser_searchForRegistrationDomains),
    luaL_Reg(name: strdup("findServices"),            func: browser_searchForServices),
    luaL_Reg(name: strdup("stop"),                    func: browser_stop),
    luaL_Reg(name: strdup("__tostring"),              func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                    func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),                    func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: browser_new),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libbonjour")
public func luaopen_hs_libbonjour(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG_STR)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    return 1
}
