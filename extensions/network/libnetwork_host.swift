import Cocoa
import LuaSkin
import CFNetwork
import SystemConfiguration

private let USERDATA_TAG = "hs.network.host"
private var refTable: LSRefTable = LUA_NOREF

private func getPtr(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<HSHostData> {
    return luaL_checkudata(L, idx, USERDATA_TAG)!.assumingMemoryBound(to: HSHostData.self)
}

// MARK: - Support Functions and Classes

private struct HSHostData {
    var theHostObj: CFHost?
    var callbackRef: Int32
    var resolveType: CFHostInfoType
    var selfRef: Int32
    var running: Bool
    var lsCanary: LSGCCanary
}

private func pushCFHost(_ L: UnsafeMutablePointer<lua_State>!, _ theHost: CFHost, _ resolveType: CFHostInfoType) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let thePtr = lua_newuserdata(L, MemoryLayout<HSHostData>.size)!.assumingMemoryBound(to: HSHostData.self)
    memset(thePtr, 0, MemoryLayout<HSHostData>.size)

    thePtr.pointee.theHostObj = theHost
    thePtr.pointee.callbackRef = LUA_NOREF
    thePtr.pointee.resolveType = resolveType
    thePtr.pointee.selfRef = LUA_NOREF
    thePtr.pointee.running = false
    thePtr.pointee.lsCanary = skin.createGCCanary()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    // capture reference so __gc doesn't accidentally collect before callback if they don't save a reference to the object
    lua_pushvalue(L, -1)
    thePtr.pointee.selfRef = skin.luaRef(refTable)
    return 1
}

private func pushQueryResults(_ L: UnsafeMutablePointer<lua_State>!, synchronous: Bool, theHost: CFHost, typeInfo: CFHostInfoType) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    var available: DarwinBoolean = false
    var argCount: Int32 = synchronous ? 1 : 2
    switch typeInfo {
    case .addresses:
        if !synchronous { lua_pushstring(L, "addresses") }
        if let theAddresses = CFHostGetAddressing(theHost, &available)?.takeUnretainedValue() as? [Data], available.boolValue {
            lua_createtable(L, 0, 0)
            for thisAddr in theAddresses {
                var addrStr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let err = thisAddr.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int32 in
                    let sockaddrPtr = rawPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                    return getnameinfo(sockaddrPtr, socklen_t(thisAddr.count), &addrStr, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST | NI_WITHSCOPEID | NI_NUMERICSERV)
                }
                if err == 0 {
                    lua_pushstring(L, addrStr)
                    lua_rawseti(L, -2, luaL_len(L, -2) + 1)
                } else {
                    let errMsg = "** error:\(String(cString: gai_strerror(err)!))"
                    lua_pushstring(L, errMsg)
                }
            }
        } else {
            lua_pushnil(L)
        }
    case .names:
        if !synchronous { lua_pushstring(L, "names") }
        if let theNames = CFHostGetNames(theHost, &available)?.takeUnretainedValue(), available.boolValue {
            skin.pushNSObject(theNames as NSArray)
        } else {
            lua_pushnil(L)
        }
    case .reachability:
        if !synchronous { lua_pushstring(L, "reachability") }
        if let theAvailability = CFHostGetReachability(theHost, &available)?.takeUnretainedValue(), available.boolValue {
            var flags: SCNetworkReachabilityFlags = SCNetworkReachabilityFlags()
            (theAvailability as Data).withUnsafeBytes { rawPtr in
                let src = rawPtr.baseAddress!
                memcpy(&flags, src, MemoryLayout<SCNetworkReachabilityFlags>.size)
            }
            lua_pushinteger(L, lua_Integer(flags.rawValue))
        } else {
            lua_pushnil(L)
        }
    default:
        lua_pushstring(L, "** unknown:\(typeInfo.rawValue)")
        argCount = 1
    }
    return argCount
}

private func expandCFStreamError(domain: CFIndex, errorNum: Int32) -> String {
    if domain == CFIndex(kCFStreamErrorDomainNetDB) {
        return "Error domain:NetDB, message:\(String(cString: gai_strerror(errorNum)))"
    } else if domain == CFIndex(kCFStreamErrorDomainNetServices) {
        return "Error domain:NetServices, code:\(errorNum) (see CFNetServices.h)"
    } else if domain == CFIndex(kCFStreamErrorDomainMach) {
        return "Error domain:Mach, code:\(errorNum) (see mach/error.h)"
    } else if domain == CFIndex(kCFStreamErrorDomainFTP) {
        return "Error domain:FTP, code:\(errorNum)"
    } else if domain == CFIndex(kCFStreamErrorDomainHTTP) {
        return "Error domain:HTTP, code:\(errorNum)"
    } else if domain == CFIndex(kCFStreamErrorDomainSOCKS) {
        return "Error domain:SOCKS, code:\(errorNum)"
    } else if domain == CFIndex(kCFStreamErrorDomainSystemConfiguration) {
        return "Error domain:SystemConfiguration, code:\(errorNum) (see SystemConfiguration.h)"
    } else if domain == CFIndex(kCFStreamErrorDomainSSL) {
        return "Error domain:SSL, code:\(errorNum) (see SecureTransport.h)"
    } else if domain == -1 /* kCFStreamErrorDomainCustom */ {
        return "Error domain:Custom, code:\(errorNum)"
    } else if domain == 1 /* kCFStreamErrorDomainPOSIX */ {
        return "Error domain:POSIX, code:\(errorNum) (see errno.h)"
    } else if domain == 2 /* kCFStreamErrorDomainMacOSStatus */ {
        return "Error domain:MacOSStatus, code:\(errorNum) (see MacErrors.h)"
    } else {
        return "Unknown domain:\(domain), code:\(errorNum)"
    }
}

private let handleCallback: CFHostClientCallBack = { theHost, typeInfo, error, info in
    guard let info = info else { return }
    let theRef = info.assumingMemoryBound(to: HSHostData.self)
    var domain: CFIndex = 0
    var errorNum: Int32 = 0
    if let error = error {
        domain = error.pointee.domain
        errorNum = error.pointee.error
    }

    DispatchQueue.main.async {
        let skin = LuaSkin.skin(with: nil)
        if theRef.pointee.callbackRef != LUA_NOREF {
            let L = skin.l!
            if !skin.check(theRef.pointee.lsCanary) {
                return
            }
            _lua_stackguard_entry(L)
            var argCount: Int32
            skin.pushLuaRef(refTable, ref: theRef.pointee.callbackRef)
            if domain == 0 && errorNum == 0 {
                argCount = pushQueryResults(L, synchronous: false, theHost: theRef.pointee.theHostObj!, typeInfo: theRef.pointee.resolveType)
            } else {
                skin.pushNSObject("resolution error:\(expandCFStreamError(domain: domain, errorNum: errorNum))" as NSString)
                argCount = 1
            }
            skin.protectedCallAndError("hs.network.host callback", nargs: argCount, nresults: 0)
            _lua_stackguard_exit(L)
        }
        CFHostSetClient(theRef.pointee.theHostObj!, nil, nil)
        CFHostUnscheduleFromRunLoop(theRef.pointee.theHostObj!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
        CFHostCancelInfoResolution(theRef.pointee.theHostObj!, theRef.pointee.resolveType)
        theRef.pointee.running = false
        // allow __gc when their stored version goes away
        if theRef.pointee.selfRef != LUA_NOREF {
            theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
        }
    }
}

private func commonConstructor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)

    let theRef = getPtr(L, 1)
    var streamError = CFStreamError()
    var argCount: Int32 = 1
    if lua_type(L, 2) == LUA_TNIL {
        theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
        if CFHostStartInfoResolution(theRef.pointee.theHostObj!, theRef.pointee.resolveType, &streamError) {
            argCount = pushQueryResults(L, synchronous: true, theHost: theRef.pointee.theHostObj!, typeInfo: theRef.pointee.resolveType)
        } else {
            lua_pushstring(L, "resolution error:" + expandCFStreamError(domain: streamError.domain, errorNum: streamError.error))
            return lua_error(L)
        }
    } else {
        lua_pushvalue(L, 2)
        theRef.pointee.callbackRef = skin.luaRef(refTable)
        var context = CFHostClientContext(version: 0, info: theRef, retain: nil, release: nil, copyDescription: nil)
        if CFHostSetClient(theRef.pointee.theHostObj!, handleCallback, &context) {
            CFHostScheduleWithRunLoop(theRef.pointee.theHostObj!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
            if CFHostStartInfoResolution(theRef.pointee.theHostObj!, theRef.pointee.resolveType, &streamError) {
                theRef.pointee.running = true
                lua_pushvalue(L, 1)
            } else {
                CFHostUnscheduleFromRunLoop(theRef.pointee.theHostObj!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
                theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
                lua_pushstring(L, "resolution error:" + expandCFStreamError(domain: streamError.domain, errorNum: streamError.error))
                return lua_error(L)
            }
        } else {
            theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
            lua_pushnil(L)
        }
    }
    return 1
}

private func commonForHostName(_ L: UnsafeMutablePointer<lua_State>!, _ resolveType: CFHostInfoType) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let synchronous = lua_isnoneornil(L, 2)

    let theHost = CFHostCreateWithName(kCFAllocatorDefault, skin.toNSObject(atIndex: 1) as! CFString).takeRetainedValue()

    lua_pushcfunction(L, commonConstructor)
    _ = pushCFHost(L, theHost, resolveType)
    if !synchronous {
        lua_pushvalue(L, 2)
    } else {
        lua_pushnil(L)
    }
    lua_call(L, 2, 1) // error as if the error occurred here
    return 1
}

private func commonForAddress(_ L: UnsafeMutablePointer<lua_State>!, _ resolveType: CFHostInfoType) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let synchronous = lua_isnoneornil(L, 2)

    luaL_checkstring(L, 1) // force number to be a string
    var results: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | AI_V4MAPPED_CFG
    hints.ai_family = PF_UNSPEC
    let addrString = (skin.toNSObject(atIndex: 1) as! NSString).utf8String!
    let ecode = getaddrinfo(addrString, nil, &hints, &results)
    if ecode != 0 {
        if results != nil { freeaddrinfo(results) }
        lua_pushstring(L, "address parse error: \(String(cString: gai_strerror(ecode)!))")
        return lua_error(L)
    }

    let theSocket = CFDataCreate(kCFAllocatorDefault, UnsafeRawPointer(results!.pointee.ai_addr).assumingMemoryBound(to: UInt8.self), CFIndex(results!.pointee.ai_addrlen))!
    let theHost = CFHostCreateWithAddress(kCFAllocatorDefault, theSocket).takeRetainedValue()
    lua_pushcfunction(L, commonConstructor)
    _ = pushCFHost(L, theHost, resolveType)
    freeaddrinfo(results)
    if !synchronous {
        lua_pushvalue(L, 2)
    } else {
        lua_pushnil(L)
    }
    lua_call(L, 2, 1) // error as if the error occurred here
    return 1
}

// MARK: - Module Functions

/// hs.network.host.addressesForHostname(name[, fn]) -> table | hostObject
/// Function
/// Get IP addresses for the hostname specified.
///
/// Parameters:
///  * name - the hostname to lookup IP addresses for
///  * fn   - an optional callback function which, when provided, will perform the address resolution in an asynchronous, non-blocking manner.
///
/// Returns:
///  * If this function is called without a callback function, returns a table containing the IP addresses for the specified name.  If a callback function is specified, then a host object is returned.
///
/// Notes:
///  * If no callback function is provided, the resolution occurs in a blocking manner which may be noticeable when network access is slow or erratic.
///  * If a callback function is provided, this function acts as a constructor, returning a host object and the callback function will be invoked when resolution is complete.  The callback function should take two parameters: the string "addresses", indicating that an address resolution occurred, and a table containing the IP addresses identified.
///  * Generates an error if network access is currently disabled or the hostname is invalid.
private func getAddressesForHostName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return commonForHostName(L, .addresses)
}

/// hs.network.host.hostnamesForAddress(address[, fn]) -> table | hostObject
/// Function
/// Get hostnames for the IP address specified.
///
/// Parameters:
///  * address - a string or number representing an IPv4 or IPv6 network address to lookup hostnames for.  If the argument is a number, it is treated as the 32 bit numerical representation of an IPv4 address.
///  * fn      - an optional callback function which, when provided, will perform the hostname resolution in an asynchronous, non-blocking manner.
///
/// Returns:
///  * If this function is called without a callback function, returns a table containing the hostnames for the specified address.  If a callback function is specified, then a host object is returned.
///
/// Notes:
///  * If no callback function is provided, the resolution occurs in a blocking manner which may be noticeable when network access is slow or erratic.
///  * If a callback function is provided, this function acts as a constructor, returning a host object and the callback function will be invoked when resolution is complete.  The callback function should take two parameters: the string "names", indicating that hostname resolution occurred, and a table containing the hostnames identified.
///  * Generates an error if network access is currently disabled or the IP address is invalid.
private func getNamesForAddress(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return commonForAddress(L, .names)
}

/// hs.network.host.reachabilityForAddress(address[, fn]) -> integer | hostObject
/// Function
/// Get the reachability status for the IP address specified.
///
/// Parameters:
///  * address - a string or number representing an IPv4 or IPv6 network address to check the reachability for.  If the argument is a number, it is treated as the 32 bit numerical representation of an IPv4 address.
///  * fn      - an optional callback function which, when provided, will determine the address reachability in an asynchronous, non-blocking manner.
///
/// Returns:
///  * If this function is called without a callback function, returns the numeric representation of the address reachability status.  If a callback function is specified, then a host object is returned.
///
/// Notes:
///  * If no callback function is provided, the resolution occurs in a blocking manner which may be noticeable when network access is slow or erratic.
///  * If a callback function is provided, this function acts as a constructor, returning a host object and the callback function will be invoked when resolution is complete.  The callback function should take two parameters: the string "reachability", indicating that reachability was determined, and the numeric representation of the address reachability status.
///  * Generates an error if network access is currently disabled or the IP address is invalid.
///  * The numeric representation is made up from a combination of the flags defined in `hs.network.reachability.flags`.
///  * Performs the same reachability test as `hs.network.reachability.forAddress`.
private func getReachabilityForAddress(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return commonForAddress(L, .reachability)
}

/// hs.network.host.reachabilityForHostname(name[, fn]) -> integer | hostObject
/// Function
/// Get the reachability status for the IP address specified.
///
/// Parameters:
///  * name - the hostname to check the reachability for.  If the argument is a number, it is treated as the 32 bit numerical representation of an IPv4 address.
///  * fn   - an optional callback function which, when provided, will determine the address reachability in an asynchronous, non-blocking manner.
///
/// Returns:
///  * If this function is called without a callback function, returns the numeric representation of the hostname reachability status.  If a callback function is specified, then a host object is returned.
///
/// Notes:
///  * If no callback function is provided, the resolution occurs in a blocking manner which may be noticeable when network access is slow or erratic.
///  * If a callback function is provided, this function acts as a constructor, returning a host object and the callback function will be invoked when resolution is complete.  The callback function should take two parameters: the string "reachability", indicating that reachability was determined, and the numeric representation of the hostname reachability status.
///  * Generates an error if network access is currently disabled or the IP address is invalid.
///  * The numeric representation is made up from a combination of the flags defined in `hs.network.reachability.flags`.
///  * Performs the same reachability test as `hs.network.reachability.forHostName`.
private func getReachabilityForHostName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return commonForHostName(L, .reachability)
}

// MARK: - Module Methods

/// hs.network.host:isRunning() -> boolean
/// Method
/// Returns whether or not resolution is still in progress for an asynchronous query.
///
/// Parameters:
///  * None
///
/// Returns:
///  * true, if resolution is still in progress, or false if resolution has already completed.
private func resolutionIsRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = getPtr(L, 1)
    lua_pushboolean(L, theRef.pointee.running ? 1 : 0)
    return 1
}

/// hs.network.host:cancel() -> hostObject
/// Method
/// Cancels an in-progress asynchronous host resolution.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the hostObject
///
/// Notes:
///  * This method has no effect if the resolution has already completed.
private func cancelResolution(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = getPtr(L, 1)
    if theRef.pointee.running {
        CFHostSetClient(theRef.pointee.theHostObj!, nil, nil)
        CFHostCancelInfoResolution(theRef.pointee.theHostObj!, theRef.pointee.resolveType)
        CFHostUnscheduleFromRunLoop(theRef.pointee.theHostObj!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
        theRef.pointee.running = false
    }
    // allow __gc when their stored version goes away
    theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
    lua_settop(L, 1)
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject("\(USERDATA_TAG): (\(String(describing: ptr)))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let theHost1 = getPtr(L, 1).pointee.theHostObj!
        let theHost2 = getPtr(L, 2).pointee.theHostObj!
        lua_pushboolean(L, CFEqual(theHost1, theHost2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theRef = getPtr(L, 1)
    theRef.pointee.callbackRef = skin.luaUnref(refTable, ref: theRef.pointee.callbackRef)
    // in case __gc forced by reload
    theRef.pointee.selfRef = skin.luaUnref(refTable, ref: theRef.pointee.selfRef)
    skin.destroy(&theRef.pointee.lsCanary)

    lua_pushcfunction(L, cancelResolution)
    lua_pushvalue(L, 1)
    lua_pcall(L, 1, 1, 0)
    lua_pop(L, 1)

    theRef.pointee.theHostObj = nil
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for userdata objects
private let userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: ("isRunning" as NSString).utf8String, func: resolutionIsRunning),
    luaL_Reg(name: ("cancel" as NSString).utf8String, func: cancelResolution),

    luaL_Reg(name: ("__tostring" as NSString).utf8String, func: userdata_tostring),
    luaL_Reg(name: ("__eq" as NSString).utf8String, func: userdata_eq),
    luaL_Reg(name: ("__gc" as NSString).utf8String, func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: ("addressesForHostname" as NSString).utf8String, func: getAddressesForHostName),
    luaL_Reg(name: ("hostnamesForAddress" as NSString).utf8String, func: getNamesForAddress),
    luaL_Reg(name: ("reachabilityForHostname" as NSString).utf8String, func: getReachabilityForHostName),
    luaL_Reg(name: ("reachabilityForAddress" as NSString).utf8String, func: getReachabilityForAddress),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libnetworkhost")
public func luaopen_hs_libnetworkhost(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: userdata_metaLib)

    return 1
}
