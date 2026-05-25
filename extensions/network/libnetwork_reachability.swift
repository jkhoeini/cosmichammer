import Cocoa
import LuaSkin
import CFNetwork
import SystemConfiguration

private let USERDATA_TAG = "hs.network.reachability"
private var refTable: LSRefTable = LUA_NOREF
private var reachabilityQueue: DispatchQueue! = nil

private func getPtr(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<ReachabilityData> {
    return luaL_checkudata(L, idx, USERDATA_TAG)!.assumingMemoryBound(to: ReachabilityData.self)
}

// MARK: - Support Functions and Classes

private struct ReachabilityData {
    var reachabilityObj: SCNetworkReachability?
    var callbackRef: Int32
    var selfRef: Int32
    var watcherEnabled: Bool
    var lsCanary: LSGCCanary
}

private func pushSCNetworkReachability(_ L: UnsafeMutablePointer<lua_State>!, _ theRef: SCNetworkReachability) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let thePtr = lua_newuserdata(L, MemoryLayout<ReachabilityData>.size)!.assumingMemoryBound(to: ReachabilityData.self)
    memset(thePtr, 0, MemoryLayout<ReachabilityData>.size)

    thePtr.pointee.reachabilityObj = theRef
    thePtr.pointee.callbackRef = LUA_NOREF
    thePtr.pointee.selfRef = LUA_NOREF
    thePtr.pointee.watcherEnabled = false
    thePtr.pointee.lsCanary = skin.createGCCanary()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private let doReachabilityCallback: SCNetworkReachabilityCallBack = { target, flags, info in
    guard let info = info else { return }
    let theRef = info.assumingMemoryBound(to: ReachabilityData.self)
    DispatchQueue.main.async {
        if theRef.pointee.callbackRef != LUA_NOREF && theRef.pointee.selfRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            if !skin.check(theRef.pointee.lsCanary) {
                return
            }
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: theRef.pointee.callbackRef)
            skin.pushLuaRef(refTable, ref: theRef.pointee.selfRef)
            lua_pushinteger(L, lua_Integer(flags.rawValue))
            skin.protectedCallAndError("hs.network.reachability", nargs: 2, nresults: 0)
            _lua_stackguard_exit(L)
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
private func reachabilityForAddress(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER, LS_TBREAK)

    luaL_checkstring(L, 1) // force number to be a string
    var results: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = PF_UNSPEC
    let ecode = getaddrinfo((skin.toNSObject(atIndex: 1) as! NSString).utf8String, nil, &hints, &results)
    if ecode != 0 {
        if results != nil { freeaddrinfo(results) }
        return luaL_error(L, "address parse error: \(String(cString: gai_strerror(ecode)!))")
    }
    let theRef = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, results!.pointee.ai_addr)!
    _ = pushSCNetworkReachability(L, theRef)
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
private func reachabilityForAddressPair(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER, LS_TSTRING | LS_TNUMBER, LS_TBREAK)

    luaL_checkstring(L, 1) // force number to be a string
    var results1: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = PF_UNSPEC
    let ecode1 = getaddrinfo((skin.toNSObject(atIndex: 1) as! NSString).utf8String, nil, &hints, &results1)
    if ecode1 != 0 {
        if results1 != nil { freeaddrinfo(results1) }
        return luaL_error(L, "local address parse error: \(String(cString: gai_strerror(ecode1)!))")
    }

    luaL_checkstring(L, 2) // force number to be a string
    var results2: UnsafeMutablePointer<addrinfo>?
    let ecode2 = getaddrinfo((skin.toNSObject(atIndex: 2) as! NSString).utf8String, nil, &hints, &results2)
    if ecode2 != 0 {
        if results1 != nil { freeaddrinfo(results1) }
        if results2 != nil { freeaddrinfo(results2) }
        return luaL_error(L, "remote address parse error: \(String(cString: gai_strerror(ecode2)!))")
    }

    let theRef = SCNetworkReachabilityCreateWithAddressPair(kCFAllocatorDefault, results1!.pointee.ai_addr, results2!.pointee.ai_addr)!
    _ = pushSCNetworkReachability(L, theRef)

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
private func reachabilityForHostName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let internalName = (skin.toNSObject(atIndex: 1) as! NSString).utf8String!
    let theRef = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, internalName)!
    _ = pushSCNetworkReachability(L, theRef)
    return 1
}

// MARK: - Module Methods

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
private func reachabilityStatus(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = getPtr(L, 1).pointee.reachabilityObj!
    var flags = SCNetworkReachabilityFlags()
    let valid = SCNetworkReachabilityGetFlags(theRef, &flags)
    if valid {
        lua_pushinteger(L, lua_Integer(flags.rawValue))
    } else {
        return luaL_error(L, "unable to get reachability flags:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

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
private func reachabilityStatusString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = getPtr(L, 1).pointee.reachabilityObj!
    var flags = SCNetworkReachabilityFlags()
    let valid = SCNetworkReachabilityGetFlags(theRef, &flags)
    if valid {
        skin.pushNSObject(statusString(flags) as NSString)
    } else {
        return luaL_error(L, "unable to get reachability flags:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

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
private func reachabilityCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theRef = getPtr(L, 1)

    // in either case, we need to remove an existing callback, so...
    theRef.pointee.callbackRef = skin.luaUnref(refTable, ref: theRef.pointee.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theRef.pointee.callbackRef = skin.luaRef(refTable)
        if theRef.pointee.selfRef == LUA_NOREF {
            lua_pushvalue(L, 1)
            theRef.pointee.selfRef = skin.luaRef(refTable)
        }
    } else {
        theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
    }

    lua_pushvalue(L, 1)
    return 1
}

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
private func reachabilityStartWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = getPtr(L, 1)
    if !theRef.pointee.watcherEnabled {
        var context = SCNetworkReachabilityContext(version: 0, info: theRef, retain: nil, release: nil, copyDescription: nil)
        if SCNetworkReachabilitySetCallback(theRef.pointee.reachabilityObj!, doReachabilityCallback, &context) {
            if SCNetworkReachabilitySetDispatchQueue(theRef.pointee.reachabilityObj!, reachabilityQueue) {
                theRef.pointee.watcherEnabled = true
            } else {
                SCNetworkReachabilitySetCallback(theRef.pointee.reachabilityObj!, nil, nil)
                return luaL_error(L, "unable to set watcher dispatch queue:\(String(cString: SCErrorString(SCError())))")
            }
        } else {
            return luaL_error(L, "unable to set watcher callback:\(String(cString: SCErrorString(SCError())))")
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.reachability:stop() -> reachabilityObject
/// Method
/// Stops watching the reachability object for changes.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the reachability object
private func reachabilityStopWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = getPtr(L, 1)
    SCNetworkReachabilitySetCallback(theRef.pointee.reachabilityObj!, nil, nil)
    SCNetworkReachabilitySetDispatchQueue(theRef.pointee.reachabilityObj!, nil)
    theRef.pointee.watcherEnabled = false
    lua_pushvalue(L, 1)
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
private func pushReachabilityFlags(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_createtable(L, 0, 0)
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.transientConnection.rawValue))
    lua_setfield(L, -2, "transientConnection")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.reachable.rawValue))
    lua_setfield(L, -2, "reachable")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.connectionRequired.rawValue))
    lua_setfield(L, -2, "connectionRequired")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.connectionOnTraffic.rawValue))
    lua_setfield(L, -2, "connectionOnTraffic")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.interventionRequired.rawValue))
    lua_setfield(L, -2, "interventionRequired")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.connectionOnDemand.rawValue))
    lua_setfield(L, -2, "connectionOnDemand")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.isLocalAddress.rawValue))
    lua_setfield(L, -2, "isLocalAddress")
    lua_pushinteger(L, lua_Integer(SCNetworkReachabilityFlags.isDirect.rawValue))
    lua_setfield(L, -2, "isDirect")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theRef = getPtr(L, 1).pointee.reachabilityObj!
    var flags = SCNetworkReachabilityFlags()
    let valid = SCNetworkReachabilityGetFlags(theRef, &flags)
    let flagString: String
    if valid {
        flagString = statusString(flags)
    } else {
        flagString = "** unable to get reachability flags*"
    }
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject("\(USERDATA_TAG): \(flagString) (\(String(describing: ptr)))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let theRef1 = getPtr(L, 1).pointee.reachabilityObj!
        let theRef2 = getPtr(L, 2).pointee.reachabilityObj!
        lua_pushboolean(L, CFEqual(theRef1, theRef2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theRef = getPtr(L, 1)
    if theRef.pointee.callbackRef != LUA_NOREF {
        theRef.pointee.callbackRef = skin.luaUnref(refTable, ref: theRef.pointee.callbackRef)
        SCNetworkReachabilitySetCallback(theRef.pointee.reachabilityObj!, nil, nil)
        SCNetworkReachabilitySetDispatchQueue(theRef.pointee.reachabilityObj!, nil)
    }
    theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
    skin.destroy(&theRef.pointee.lsCanary)

    theRef.pointee.reachabilityObj = nil
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    reachabilityQueue = nil
    return 0
}

// Metatable for userdata objects
private let userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: ("status" as NSString).utf8String, func: reachabilityStatus),
    luaL_Reg(name: ("statusString" as NSString).utf8String, func: reachabilityStatusString),
    luaL_Reg(name: ("setCallback" as NSString).utf8String, func: reachabilityCallback),
    luaL_Reg(name: ("start" as NSString).utf8String, func: reachabilityStartWatcher),
    luaL_Reg(name: ("stop" as NSString).utf8String, func: reachabilityStopWatcher),

    luaL_Reg(name: ("__tostring" as NSString).utf8String, func: userdata_tostring),
    luaL_Reg(name: ("__eq" as NSString).utf8String, func: userdata_eq),
    luaL_Reg(name: ("__gc" as NSString).utf8String, func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: ("forAddressPair" as NSString).utf8String, func: reachabilityForAddressPair),
    luaL_Reg(name: ("forAddress" as NSString).utf8String, func: reachabilityForAddress),
    luaL_Reg(name: ("forHostName" as NSString).utf8String, func: reachabilityForHostName),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private let module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: ("__gc" as NSString).utf8String, func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libnetworkreachability")
public func luaopen_hs_libnetworkreachability(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: moduleLib,
                                    metaFunctions: module_metaLib,
                                    objectFunctions: userdata_metaLib)

    // unlike dispatch_get_main_queue, this is concurrent... make sure to invoke lua part of callback
    // on main queue, though...
    reachabilityQueue = DispatchQueue.global(qos: .utility)
    _ = pushReachabilityFlags(L)
    lua_setfield(L, -2, "flags")

    return 1
}
