import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.bonjour"

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

private func pushBonjourCallbackArgument(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) {
    if let service = obj as? NetService {
        pushNSNetService(L, service)
    } else {
        lua_pushany(L, obj)
    }
}

@objc private class HSNetServiceBrowser: NetServiceBrowser, NetServiceBrowserDelegate {
    var callback: LuaValue?
    var generation: UInt64 = 0
    private var tornDown = false

    override init() {
        super.init()
        self.delegate = self
    }

    /// Idempotent teardown: stop browsing, drop the Lua callback reference,
    /// clear delegate.  Called from the explicit __gc closure while the
    /// lua_State is still alive, AND from performCallback when the generation
    /// canary fires.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        super.stop()
        callback = nil
        delegate = nil
    }

    func performCallback(with argument: Any?) {
        guard lua_isStateGenerationValid(generation) else {
            teardown()
            return
        }
        guard callback != nil else { return }

        let L = lua_getCurrentState()!
        var argCount: Int32 = 1
        callback?.push(onto: L)
        L.push(userdata: self)
        if let argument = argument {
            if let args = argument as? [Any] {
                for obj in args {
                    pushBonjourCallbackArgument(L, obj)
                }
                argCount += Int32(args.count)
            } else {
                pushBonjourCallbackArgument(L, argument)
                argCount += 1
            }
        }
        if lua_pcall(L, argCount, 0, 0) != LUA_OK {
            os_log(.error, "%{public}s", "\(USERDATA_TAG):callback error:\(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1)
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
    browser.generation = lua_currentStateGeneration()
    L.push(userdata: browser)
    return 1
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libbonjour")
public func luaopen_hs_libbonjour(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    L.register(Metatable<HSNetServiceBrowser>(
        fields: [
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
            "includesPeerToPeer": .closure { L in
                let browser: HSNetServiceBrowser = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(browser.includesPeerToPeer)
                } else {
                    browser.includesPeerToPeer = lua_toboolean(L, 2) != 0
                    lua_pushvalue(L, 1)
                }
                return 1
            },
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
            "findBrowsableDomains": .closure { L in
                let browser: HSNetServiceBrowser = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TFUNCTION)
                if browser.callback != nil {
                    browser.stop()
                    browser.callback = nil
                }
                browser.callback = L.ref(index: 2)
                browser.searchForBrowsableDomains()
                lua_pushvalue(L, 1)
                return 1
            },
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
            "findRegistrationDomains": .closure { L in
                let browser: HSNetServiceBrowser = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TFUNCTION)
                if browser.callback != nil {
                    browser.stop()
                    browser.callback = nil
                }
                browser.callback = L.ref(index: 2)
                browser.searchForRegistrationDomains()
                lua_pushvalue(L, 1)
                return 1
            },
            // hs.bonjour:findServices is documented with its wrapper in init.lua
            "findServices": .closure { L in
                let browser: HSNetServiceBrowser = try L.checkArgument(1)
                var service = "_services._dns-sd._udp."
                var domain = ""
                switch lua_gettop(L) {
                case 2:
                    luaL_checktype(L, 2, LUA_TFUNCTION)
                case 3:
                    service = lua_tovalue(L, at: 2) as! String
                default:
                    service = lua_tovalue(L, at: 2) as! String
                    domain = lua_tovalue(L, at: 3) as! String
                }
                if browser.callback != nil {
                    browser.stop()
                    browser.callback = nil
                }
                browser.callback = L.ref(index: lua_gettop(L))
                browser.searchForServices(ofType: service, inDomain: domain)
                lua_pushvalue(L, 1)
                return 1
            },
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
            "stop": .closure { L in
                let browser: HSNetServiceBrowser = try L.checkArgument(1)
                browser.stop()
                browser.callback = nil
                lua_pushvalue(L, 1)
                return 1
            },
        ],
        eq: .closure { L in
            if let obj1: HSNetServiceBrowser = L.touserdata(1),
               let obj2: HSNetServiceBrowser = L.touserdata(2) {
                L.push(obj1.isEqual(to: obj2))
            } else {
                L.push(false)
            }
            return 1
        },
        tostring: .closure { L in
            L.push("\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1))))")
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // LuaSwift's register() always installs its own gcUserdata as __gc, which
    // only deinitializes the Any box. We MUST replace it with a custom __gc
    // that first calls teardown() (stop browsing, drop the LuaValue callback)
    // and THEN deinitializes the Any box.
    L.pushMetatable(for: HSNetServiceBrowser.self)

    // Replace __gc with our explicit teardown + deinitialize
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let browser: HSNetServiceBrowser = L.touserdata(1) {
            browser.teardown()
        }
        // Now deinitialize the Any box (same as LuaSwift's gcUserdata)
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.bonjour") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Module table
    lua_createtable(L, 0, 1)
    L.push(browser_new)
    lua_setfield(L, -2, "new")

    return 1
}
