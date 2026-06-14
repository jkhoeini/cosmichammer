import Cocoa
import CLua
import Lua
import CFNetwork
import SystemConfiguration

private let USERDATA_TAG = "hs.network.host"

// MARK: - Support Functions and Classes

private class HSHost: NSObject {
    var theHostObj: CFHost?
    var callback: LuaValue?
    var resolveType: CFHostInfoType
    var selfRefValue: LuaValue?
    var running: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    init(host: CFHost, resolveType: CFHostInfoType) {
        self.theHostObj = host
        self.resolveType = resolveType
        super.init()
        self.generation = lua_currentStateGeneration()
    }

    /// Idempotent teardown: cancel resolution, drop callback and self-ref,
    /// release CFHost resources.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running, let host = theHostObj {
            CFHostSetClient(host, nil, nil)
            CFHostCancelInfoResolution(host, resolveType)
            CFHostUnscheduleFromRunLoop(host, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
            running = false
        }
        callback = nil
        selfRefValue = nil
        theHostObj = nil
    }
}

private func pushCFHost(_ L: UnsafeMutablePointer<lua_State>!, _ theHost: CFHost, _ resolveType: CFHostInfoType) -> Int32 {
    let obj = HSHost(host: theHost, resolveType: resolveType)
    L.push(userdata: obj)

    // Capture a self-ref in the registry so __gc doesn't collect the userdata
    // before the async callback fires (if the caller doesn't save a reference).
    obj.selfRefValue = L.ref(index: -1)
    return 1
}

private func pushQueryResults(_ L: UnsafeMutablePointer<lua_State>!, synchronous: Bool, theHost: CFHost, typeInfo: CFHostInfoType) -> Int32 {
    var available: DarwinBoolean = false
    var argCount: Int32 = synchronous ? 1 : 2
    switch typeInfo {
    case .addresses:
        if !synchronous { L.push("addresses") }
        if let theAddresses = CFHostGetAddressing(theHost, &available)?.takeUnretainedValue() as? [Data], available.boolValue {
            lua_createtable(L, 0, 0)
            for thisAddr in theAddresses {
                var addrStr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let err = thisAddr.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int32 in
                    let sockaddrPtr = rawPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                    return getnameinfo(sockaddrPtr, socklen_t(thisAddr.count), &addrStr, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST | NI_WITHSCOPEID | NI_NUMERICSERV)
                }
                if err == 0 {
                    L.push(String(cString: addrStr))
                    lua_rawseti(L, -2, luaL_len(L, -2) + 1)
                } else {
                    let errMsg = "** error:\(String(cString: gai_strerror(err)!))"
                    L.push(errMsg)
                }
            }
        } else {
            lua_pushnil(L)
        }
    case .names:
        if !synchronous { L.push("names") }
        if let theNames = CFHostGetNames(theHost, &available)?.takeUnretainedValue(), available.boolValue {
            lua_pushany(L, theNames as NSArray)
        } else {
            lua_pushnil(L)
        }
    case .reachability:
        if !synchronous { L.push("reachability") }
        if let theAvailability = CFHostGetReachability(theHost, &available)?.takeUnretainedValue(), available.boolValue {
            var flags: SCNetworkReachabilityFlags = SCNetworkReachabilityFlags()
            (theAvailability as Data).withUnsafeBytes { rawPtr in
                let src = rawPtr.baseAddress!
                memcpy(&flags, src, MemoryLayout<SCNetworkReachabilityFlags>.size)
            }
            L.push(lua_Integer(flags.rawValue))
        } else {
            lua_pushnil(L)
        }
    default:
        L.push("** unknown:\(typeInfo.rawValue)")
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
    // Recover the HSHost object from the Unmanaged pointer stored in the CFHost context.
    let obj = Unmanaged<HSHost>.fromOpaque(info).takeUnretainedValue()
    var domain: CFIndex = 0
    var errorNum: Int32 = 0
    if let error = error {
        domain = error.pointee.domain
        errorNum = error.pointee.error
    }

    DispatchQueue.main.async {
        let L = lua_getCurrentState()!
        if let cb = obj.callback {
            guard lua_isStateGenerationValid(obj.generation) else { return }
            var argCount: Int32
            cb.push(onto: L)
            if domain == 0 && errorNum == 0 {
                argCount = pushQueryResults(L, synchronous: false, theHost: obj.theHostObj!, typeInfo: obj.resolveType)
            } else {
                L.push("resolution error:\(expandCFStreamError(domain: domain, errorNum: errorNum))")
                argCount = 1
            }
            if lua_pcall(L, argCount, 0, 0) != LUA_OK {
                lua_pop(L, 1)
            }
        }
        if let host = obj.theHostObj {
            CFHostSetClient(host, nil, nil)
            CFHostUnscheduleFromRunLoop(host, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
            CFHostCancelInfoResolution(host, obj.resolveType)
        }
        obj.running = false
        // Allow __gc when their stored version goes away
        obj.selfRefValue = nil
    }
}

private func commonConstructor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let obj: HSHost = L.touserdata(1) else {
        L.push("\(USERDATA_TAG): internal error - could not extract host object")
        return lua_error(L)
    }
    var streamError = CFStreamError()
    if lua_type(L, 2) == LUA_TNIL {
        // Synchronous resolution -- release self-ref since caller gets the result directly
        obj.selfRefValue = nil
        if CFHostStartInfoResolution(obj.theHostObj!, obj.resolveType, &streamError) {
            let argCount = pushQueryResults(L, synchronous: true, theHost: obj.theHostObj!, typeInfo: obj.resolveType)
            return argCount
        } else {
            L.push("resolution error:" + expandCFStreamError(domain: streamError.domain, errorNum: streamError.error))
            return lua_error(L)
        }
    } else {
        // Async resolution -- store callback and set up CFHost client
        obj.callback = L.ref(index: 2)
        // Use Unmanaged to pass a stable pointer to the HSHost (an NSObject) as
        // the info context for CFHostSetClient. passUnretained is correct because
        // selfRefValue keeps the Lua userdata (and thus the HSHost) alive.
        let infoPtr = Unmanaged.passUnretained(obj).toOpaque()
        var context = CFHostClientContext(version: 0, info: infoPtr, retain: nil, release: nil, copyDescription: nil)
        if CFHostSetClient(obj.theHostObj!, handleCallback, &context) {
            CFHostScheduleWithRunLoop(obj.theHostObj!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
            if CFHostStartInfoResolution(obj.theHostObj!, obj.resolveType, &streamError) {
                obj.running = true
                lua_pushvalue(L, 1)
            } else {
                CFHostUnscheduleFromRunLoop(obj.theHostObj!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
                obj.selfRefValue = nil
                L.push("resolution error:" + expandCFStreamError(domain: streamError.domain, errorNum: streamError.error))
                return lua_error(L)
            }
        } else {
            obj.selfRefValue = nil
            lua_pushnil(L)
        }
    }
    return 1
}

private func commonForHostName(_ L: UnsafeMutablePointer<lua_State>!, _ resolveType: CFHostInfoType) -> Int32 {
    let hostName = String(cString: luaL_checkstring(L, 1)!)
    let synchronous: Bool = lua_isnoneornil(L, 2)

    let theHost = CFHostCreateWithName(kCFAllocatorDefault, hostName as CFString).takeRetainedValue()

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
    let synchronous: Bool = lua_isnoneornil(L, 2)

    _ = luaL_checkstring(L, 1) // force number to be a string
    var results: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | AI_V4MAPPED_CFG
    hints.ai_family = PF_UNSPEC
    let addrString = String(cString: lua_tostring(L, 1)!)
    let ecode = getaddrinfo(addrString, nil, &hints, &results)
    if ecode != 0 {
        if results != nil { freeaddrinfo(results) }
        L.push("address parse error: \(String(cString: gai_strerror(ecode)!))")
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
private func getAddressesForHostName(_ L: LuaState) throws -> CInt {
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
private func getNamesForAddress(_ L: LuaState) throws -> CInt {
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
private func getReachabilityForAddress(_ L: LuaState) throws -> CInt {
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
private func getReachabilityForHostName(_ L: LuaState) throws -> CInt {
    return commonForHostName(L, .reachability)
}

// MARK: - Cosmic Hammer/Lua Infrastructure

@_cdecl("luaopen_hs_libnetworkhost")
public func luaopen_hs_libnetworkhost(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        L.register(Metatable<HSHost>(
            fields: [
                /// hs.network.host:isRunning() -> boolean
                /// Method
                /// Returns whether or not resolution is still in progress for an asynchronous query.
                ///
                /// Parameters:
                ///  * None
                ///
                /// Returns:
                ///  * true, if resolution is still in progress, or false if resolution has already completed.
                "isRunning": .closure { L in
                    let obj: HSHost = try L.checkArgument(1)
                    L.push(obj.running)
                    return 1
                },
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
                "cancel": .closure { L in
                    let obj: HSHost = try L.checkArgument(1)
                    if obj.running, let host = obj.theHostObj {
                        CFHostSetClient(host, nil, nil)
                        CFHostCancelInfoResolution(host, obj.resolveType)
                        CFHostUnscheduleFromRunLoop(host, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
                        obj.running = false
                    }
                    // Allow __gc when their stored version goes away
                    obj.selfRefValue = nil
                    lua_settop(L, 1)
                    return 1
                },
            ],
            tostring: .closure { L in
                let ptr = lua_topointer(L, 1)
                L.push("\(USERDATA_TAG): (\(String(describing: ptr)))")
                return 1
            }
        ))

        // Post-registration: replace __gc with teardown + deinitialize
        L.pushMetatable(for: HSHost.self)

        L.push({ (L: LuaState!) -> CInt in
            if let obj: HSHost = L.touserdata(1) {
                obj.teardown()
            }
            let rawptr = lua_touserdata(L, 1)!
            let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
            anyPtr.deinitialize(count: 1)
            return 0
        })
        lua_setfield(L, -2, "__gc")

        // __eq: compare underlying CFHost objects
        L.push({ (L: LuaState!) -> CInt in
            if let obj1: HSHost = L.touserdata(1), let obj2: HSHost = L.touserdata(2),
               let host1 = obj1.theHostObj, let host2 = obj2.theHostObj {
                L.push(CFEqual(host1, host2))
            } else {
                L.push(false)
            }
            return 1
        })
        lua_setfield(L, -2, "__eq")

        // Set __type and __name for compatibility
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the legacy registry name
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(getAddressesForHostName)
        lua_setfield(L, -2, "addressesForHostname")
        L.push(getNamesForAddress)
        lua_setfield(L, -2, "hostnamesForAddress")
        L.push(getReachabilityForHostName)
        lua_setfield(L, -2, "reachabilityForHostname")
        L.push(getReachabilityForAddress)
        lua_setfield(L, -2, "reachabilityForAddress")
    }
}
