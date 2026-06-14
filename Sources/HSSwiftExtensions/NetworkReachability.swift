import Cocoa
import CLua
import Lua
import CFNetwork
import SystemConfiguration

private let USERDATA_TAG = "hs.network.reachability"
private var reachabilityQueue: DispatchQueue! = nil

// MARK: - Support Functions and Classes

private class HSReachability: NSObject {
    var reachabilityObj: SCNetworkReachability?
    var callback: LuaValue?
    var selfRefValue: LuaValue?
    var watcherEnabled: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    /// Idempotent teardown: stop the watcher, drop the Lua callback and self
    /// references, mark as torn down.  Called from __gc while the lua_State is
    /// still alive.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if watcherEnabled, let r = reachabilityObj {
            SCNetworkReachabilitySetCallback(r, nil, nil)
            SCNetworkReachabilitySetDispatchQueue(r, nil)
            watcherEnabled = false
        }
        callback = nil
        selfRefValue = nil
        reachabilityObj = nil
    }
}

private let doReachabilityCallback: SCNetworkReachabilityCallBack = { target, flags, info in
    guard let info = info else { return }
    let obj = Unmanaged<HSReachability>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async {
        guard let cb = obj.callback else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(obj.generation) else { return }
        cb.push(onto: L)
        L.push(userdata: obj)
        L.push(lua_Integer(flags.rawValue))
        if lua_pcall(L, 2, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }
}

private func statusString(_ flags: SCNetworkReachabilityFlags) -> String {
    return String(format: "%c%c%c%c%c%c%c%c",
        flags.contains(.transientConnection)  ? Character("t").asciiValue! : Character("-").asciiValue!,
        flags.contains(.reachable)            ? Character("R").asciiValue! : Character("-").asciiValue!,
        flags.contains(.connectionRequired)   ? Character("c").asciiValue! : Character("-").asciiValue!,
        flags.contains(.connectionOnTraffic)  ? Character("C").asciiValue! : Character("-").asciiValue!,
        flags.contains(.interventionRequired) ? Character("i").asciiValue! : Character("-").asciiValue!,
        flags.contains(.connectionOnDemand)   ? Character("D").asciiValue! : Character("-").asciiValue!,
        flags.contains(.isLocalAddress)       ? Character("l").asciiValue! : Character("-").asciiValue!,
        flags.contains(.isDirect)             ? Character("d").asciiValue! : Character("-").asciiValue!)
}

// MARK: - Module Functions

/// hs.network.reachability.forAddress(address) -> reachabilityObject
/// Constructor
/// Returns a reachability object for the specified network address.
///
/// Parameters:
///  * address - a string or number representing an IPv4 or IPv6 network address to get or track reachability status for.  If the argument is a number, it is treated as the 32 bit numerical representation of an IPv4 address.
///
/// Returns:
///  * a reachability object for the specified network address.
///
/// Notes:
///  * this object will reflect reachability status for any interface available on the computer.  To check for reachability from a specific interface, use [hs.network.reachability.forAddressPair](#addressPair).
private func reachabilityForAddress(_ L: LuaState) throws -> CInt {
    _ = luaL_checkstring(L, 1) // force number to be a string
    var results: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = PF_UNSPEC
    let addrStr = String(cString: lua_tostring(L, 1)!)
    let ecode = getaddrinfo(addrStr, nil, &hints, &results)
    if ecode != 0 {
        if results != nil { freeaddrinfo(results) }
        throw LuaCallError("address parse error: \(String(cString: gai_strerror(ecode)!))")
    }
    let scRef = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, results!.pointee.ai_addr)!
    let obj = HSReachability()
    obj.reachabilityObj = scRef
    obj.generation = lua_currentStateGeneration()
    L.push(userdata: obj)
    if results != nil { freeaddrinfo(results) }
    return 1
}

/// hs.network.reachability.forAddressPair(localAddress, remoteAddress) -> reachabilityObject
/// Constructor
/// Returns a reachability object for the specified network address from the specified localAddress.
///
/// Parameters:
///  * localAddress - a string or number representing a local IPv4 or IPv6 network address. If the address specified is not present on the computer, the remote address will be unreachable.
///  * remoteAddress - a string or number representing an IPv4 or IPv6 network address to get or track reachability status for.  If the argument is a number, it is treated as the 32 bit numerical representation of an IPv4 address.
///
/// Returns:
///  * a reachability object for the specified network address.
///
/// Notes:
///  * this object will reflect reachability status for a specific interface on the computer.  To check for reachability from any interface, use [hs.network.reachability.forAddress](#address).
///  * this constructor can be used to test for a specific local network.
private func reachabilityForAddressPair(_ L: LuaState) throws -> CInt {
    _ = luaL_checkstring(L, 1) // force number to be a string
    var results1: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = PF_UNSPEC
    let addrStr1 = String(cString: lua_tostring(L, 1)!)
    let ecode1 = getaddrinfo(addrStr1, nil, &hints, &results1)
    if ecode1 != 0 {
        if results1 != nil { freeaddrinfo(results1) }
        throw LuaCallError("local address parse error: \(String(cString: gai_strerror(ecode1)!))")
    }

    _ = luaL_checkstring(L, 2) // force number to be a string
    var results2: UnsafeMutablePointer<addrinfo>?
    let addrStr2 = String(cString: lua_tostring(L, 2)!)
    let ecode2 = getaddrinfo(addrStr2, nil, &hints, &results2)
    if ecode2 != 0 {
        if results1 != nil { freeaddrinfo(results1) }
        if results2 != nil { freeaddrinfo(results2) }
        throw LuaCallError("remote address parse error: \(String(cString: gai_strerror(ecode2)!))")
    }

    let scRef = SCNetworkReachabilityCreateWithAddressPair(kCFAllocatorDefault, results1!.pointee.ai_addr, results2!.pointee.ai_addr)!
    let obj = HSReachability()
    obj.reachabilityObj = scRef
    obj.generation = lua_currentStateGeneration()
    L.push(userdata: obj)

    if results1 != nil { freeaddrinfo(results1) }
    if results2 != nil { freeaddrinfo(results2) }
    return 1
}

/// hs.network.reachability.forHostName(hostName) -> reachabilityObject
/// Constructor
/// Returns a reachability object for the specified host.
///
/// Parameters:
///  * hostName - a string containing the hostname of a machine to check or track the reachability status for.
///
/// Returns:
///  * a reachability object for the specified host.
///
/// Notes:
///  * this object will reflect reachability status for any interface available on the computer.
///  * this constructor relies on the hostname being resolvable, possibly through DNS, Bonjour, locally defined, etc.
private func reachabilityForHostName(_ L: LuaState) throws -> CInt {
    let internalName = luaL_checkstring(L, 1)!
    let scRef = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, internalName)!
    let obj = HSReachability()
    obj.reachabilityObj = scRef
    obj.generation = lua_currentStateGeneration()
    L.push(userdata: obj)
    return 1
}

// MARK: - Module Constants

/// hs.network.reachability.flags[]
/// Constant
/// A table containing the numeric value for the possible flags returned by the [hs.network.reachability:status](#status) method or in the `flags` parameter of the callback function.
///
/// * transientConnection  - indicates if the destination is reachable through a transient connection
/// * reachable            - indicates if the destination is reachable
/// * connectionRequired   - indicates that a connection of some sort is required for the destination to be reachable
/// * connectionOnTraffic  - indicates if the destination requires a connection which will be initiated when traffic to the destination is present
/// * interventionRequired - indicates if the destination requires a connection which will require user activity to initiate
/// * connectionOnDemand   - indicates if the destination requires a connection which will be initiated on demand through the CFSocketStream interface
/// * isLocalAddress       - indicates if the destination is actually a local address
/// * isDirect             - indicates if the destination is directly connected
private func pushReachabilityFlags(_ L: LuaState) throws -> CInt {
    lua_createtable(L, 0, 0)
    L.push(lua_Integer(SCNetworkReachabilityFlags.transientConnection.rawValue))
    lua_setfield(L, -2, "transientConnection")
    L.push(lua_Integer(SCNetworkReachabilityFlags.reachable.rawValue))
    lua_setfield(L, -2, "reachable")
    L.push(lua_Integer(SCNetworkReachabilityFlags.connectionRequired.rawValue))
    lua_setfield(L, -2, "connectionRequired")
    L.push(lua_Integer(SCNetworkReachabilityFlags.connectionOnTraffic.rawValue))
    lua_setfield(L, -2, "connectionOnTraffic")
    L.push(lua_Integer(SCNetworkReachabilityFlags.interventionRequired.rawValue))
    lua_setfield(L, -2, "interventionRequired")
    L.push(lua_Integer(SCNetworkReachabilityFlags.connectionOnDemand.rawValue))
    lua_setfield(L, -2, "connectionOnDemand")
    L.push(lua_Integer(SCNetworkReachabilityFlags.isLocalAddress.rawValue))
    lua_setfield(L, -2, "isLocalAddress")
    L.push(lua_Integer(SCNetworkReachabilityFlags.isDirect.rawValue))
    lua_setfield(L, -2, "isDirect")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

@_cdecl("luaopen_hs_libnetworkreachability")
public func luaopen_hs_libnetworkreachability(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register idiomatic Metatable<HSReachability> with LuaSwift.
        L.register(Metatable<HSReachability>(
            fields: [
                /// hs.network.reachability:status() -> number
                /// Method
                /// Returns the reachability status for the object
                ///
                /// Parameters:
                ///  * None
                ///
                /// Returns:
                ///  * a numeric representation of the reachability status
                ///
                /// Notes:
                ///  * The numeric representation is made up from a combination of the flags defined in [hs.network.reachability.flags](#flags).
                "status": .closure { L in
                    let obj: HSReachability = try L.checkArgument(1)
                    var flags = SCNetworkReachabilityFlags()
                    guard let r = obj.reachabilityObj, SCNetworkReachabilityGetFlags(r, &flags) else {
                        throw LuaCallError("unable to get reachability flags:\(String(cString: SCErrorString(SCError())))")
                    }
                    L.push(lua_Integer(flags.rawValue))
                    return 1
                },
                /// hs.network.reachability:statusString() -> string
                /// Method
                /// Returns a string representation of the reachability status for the object
                ///
                /// Parameters:
                ///  * None
                ///
                /// Returns:
                ///  * a string representation of the reachability status for the object
                ///
                /// Notes:
                ///  * This is included primarily for debugging, but may be more useful when you just want a quick look at the reachability status for display or testing.
                ///  * The string will be made up of the following flags:
                ///    * 't'|'-' indicates if the destination is reachable through a transient connection
                ///    * 'R'|'-' indicates if the destination is reachable
                ///    * 'c'|'-' indicates that a connection of some sort is required for the destination to be reachable
                ///    * 'C'|'-' indicates if the destination requires a connection which will be initiated when traffic to the destination is present
                ///    * 'i'|'-' indicates if the destination requires a connection which will require user activity to initiate
                ///    * 'D'|'-' indicates if the destination requires a connection which will be initiated on demand through the CFSocketStream interface
                ///    * 'l'|'-' indicates if the destination is actually a local address
                ///    * 'd'|'-' indicates if the destination is directly connected
                "statusString": .closure { L in
                    let obj: HSReachability = try L.checkArgument(1)
                    var flags = SCNetworkReachabilityFlags()
                    guard let r = obj.reachabilityObj, SCNetworkReachabilityGetFlags(r, &flags) else {
                        throw LuaCallError("unable to get reachability flags:\(String(cString: SCErrorString(SCError())))")
                    }
                    L.push(statusString(flags))
                    return 1
                },
                /// hs.network.reachability:setCallback(function) -> reachabilityObject
                /// Method
                /// Set or remove the callback function for a reachability object
                ///
                /// Parameters:
                ///  * a function or nil to set or remove the reachability object callback function
                ///
                /// Returns:
                ///  * the reachability object
                ///
                /// Notes:
                ///  * The callback function will be invoked each time the status for the given reachability object changes.  The callback function should expect 2 arguments, the reachability object itself and a numeric representation of the reachability flags, and should not return anything.
                ///  * This method just sets the callback function.  You can start or stop the watcher with [hs.network.reachability:start](#start) or [hs.network.reachability:stop](#stop)
                "setCallback": .closure { L in
                    let obj: HSReachability = try L.checkArgument(1)
                    let argType = lua_type(L, 2)
                    guard argType == LUA_TFUNCTION || argType == LUA_TNIL else {
                        throw LuaCallError("expected function or nil for argument 2")
                    }

                    if argType == LUA_TFUNCTION {
                        obj.callback = L.ref(index: 2)
                        if obj.selfRefValue == nil {
                            lua_pushvalue(L, 1)
                            obj.selfRefValue = L.ref(index: -1)
                            lua_pop(L, 1)
                        }
                    } else {
                        obj.callback = nil
                        obj.selfRefValue = nil
                    }

                    lua_pushvalue(L, 1)
                    return 1
                },
                /// hs.network.reachability:start() -> reachabilityObject
                /// Method
                /// Starts watching the reachability object for changes and invokes the callback function (if any) when a change occurs.
                ///
                /// Parameters:
                ///  * None
                ///
                /// Returns:
                ///  * the reachability object
                ///
                /// Notes:
                ///  * The callback function should be specified with [hs.network.reachability:setCallback](#setCallback).
                "start": .closure { L in
                    let obj: HSReachability = try L.checkArgument(1)
                    if !obj.watcherEnabled {
                        var context = SCNetworkReachabilityContext(
                            version: 0,
                            info: Unmanaged.passUnretained(obj).toOpaque(),
                            retain: nil,
                            release: nil,
                            copyDescription: nil
                        )
                        guard let r = obj.reachabilityObj else {
                            throw LuaCallError("reachability object is invalid")
                        }
                        if SCNetworkReachabilitySetCallback(r, doReachabilityCallback, &context) {
                            if SCNetworkReachabilitySetDispatchQueue(r, reachabilityQueue) {
                                obj.watcherEnabled = true
                            } else {
                                SCNetworkReachabilitySetCallback(r, nil, nil)
                                throw LuaCallError("unable to set watcher dispatch queue:\(String(cString: SCErrorString(SCError())))")
                            }
                        } else {
                            throw LuaCallError("unable to set watcher callback:\(String(cString: SCErrorString(SCError())))")
                        }
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                /// hs.network.reachability:stop() -> reachabilityObject
                /// Method
                /// Stops watching the reachability object for changes.
                ///
                /// Parameters:
                ///  * None
                ///
                /// Returns:
                ///  * the reachability object
                "stop": .closure { L in
                    let obj: HSReachability = try L.checkArgument(1)
                    if let r = obj.reachabilityObj {
                        SCNetworkReachabilitySetCallback(r, nil, nil)
                        SCNetworkReachabilitySetDispatchQueue(r, nil)
                    }
                    obj.watcherEnabled = false
                    // Release self-reference so the object can be GC'd when stopped
                    obj.selfRefValue = nil
                    lua_pushvalue(L, 1)
                    return 1
                },
            ],
            tostring: .closure { L in
                let obj: HSReachability = try L.checkArgument(1)
                let flagString: String
                if let r = obj.reachabilityObj {
                    var flags = SCNetworkReachabilityFlags()
                    if SCNetworkReachabilityGetFlags(r, &flags) {
                        flagString = statusString(flags)
                    } else {
                        flagString = "** unable to get reachability flags*"
                    }
                } else {
                    flagString = "** reachability object is nil*"
                }
                let ptr = lua_topointer(L, 1)
                L.push("\(USERDATA_TAG): \(flagString) (\(String(describing: ptr)))")
                return 1
            }
        ))

        // -- Post-registration metatable patching --
        // Replace LuaSwift's default __gc with custom teardown + deinitialize.
        L.pushMetatable(for: HSReachability.self)

        // __eq: compare via CFEqual on the underlying SCNetworkReachability
        L.push({ (L: LuaState!) -> CInt in
            if let obj1: HSReachability = L.touserdata(1),
               let obj2: HSReachability = L.touserdata(2),
               let r1 = obj1.reachabilityObj,
               let r2 = obj2.reachabilityObj {
                L.push(CFEqual(r1, r2))
            } else {
                L.push(false)
            }
            return 1
        })
        lua_setfield(L, -2, "__eq")

        // Replace __gc with our explicit teardown + deinitialize
        L.push({ (L: LuaState!) -> CInt in
            if let obj: HSReachability = L.touserdata(1) {
                obj.teardown()
            }
            // Now deinitialize the Any box (same as LuaSwift's gcUserdata)
            let rawptr = lua_touserdata(L, 1)!
            let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
            anyPtr.deinitialize(count: 1)
            return 0
        })
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the legacy registry name so that
        // core_getObjectMetatable("hs.network.reachability") still resolves.
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(reachabilityForAddressPair)
        lua_setfield(L, -2, "forAddressPair")
        L.push(reachabilityForAddress)
        lua_setfield(L, -2, "forAddress")
        L.push(reachabilityForHostName)
        lua_setfield(L, -2, "forHostName")

        // Set module metatable (for __gc to clean up reachabilityQueue)
        lua_createtable(L, 0, 1)
        L.push({ (L: LuaState!) -> CInt in
            reachabilityQueue = nil
            return 0
        })
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        reachabilityQueue = DispatchQueue.global(qos: .utility)
        _ = try pushReachabilityFlags(L)
        lua_setfield(L, -2, "flags")
    }
}
