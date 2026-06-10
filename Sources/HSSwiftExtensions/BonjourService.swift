import Cocoa
import CLua
import Lua
import os.log
import Darwin.POSIX.netinet
import Darwin.POSIX.netdb

private let USERDATA_TAG: StaticString = "hs.bonjour.service"
private var USERDATA_TAG_STR: String { "\(USERDATA_TAG)" }
private var refTable: Int32 = Int32(LUA_NOREF)

private var serviceUDRecords: NSMapTable<HSNetServiceWrapper, NSNumber>!

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

private func ensureBonjourServiceModuleLoaded(_ L: UnsafeMutablePointer<lua_State>!) {
    guard serviceUDRecords == nil else { return }
    "hs.libbonjourservice".withCString { moduleName in
        luaL_requiref(L, moduleName, luaopen_hs_libbonjourservice, 0)
        lua_pop(L, 1)
    }
}

private func pushNetServiceCallbackArgument(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) {
    if let service = obj as? NetService {
        pushNSNetService(L, service)
    } else {
        lua_pushany(L, obj)
    }
}

@objc private class HSNetServiceWrapper: NSObject, NetServiceDelegate {
    var service: NetService!
    var callbackRef: Int32 = Int32(LUA_NOREF)
    var monitorCallbackRef: Int32 = Int32(LUA_NOREF)
    var selfRefCount: Int = 0
    var selfRef: Int32 = Int32(LUA_NOREF)

    // stupid macOS API will cause an exception if we try to publish a discovered service (or one created to
    // be resolved) but won't give us a method telling us which it is, so we'll have to track on our own and
    // assume that if this module didn't create it, we can't publish it.
    var canPublish: Bool = false

    init(service: NetService) {
        self.service = service
        super.init()
        service.delegate = self
    }

    func performCallback(with argument: Any?, usingCallback fnRef: Int32) {
        if fnRef != Int32(LUA_NOREF) {
            let L = lua_getCurrentState()!
            var argCount: Int32 = 1
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fnRef))
            pushHSNetServiceWrapper(L, self)
            if let argument = argument {
                if let args = argument as? [Any] {
                    for obj in args {
                        pushNetServiceCallbackArgument(L, obj)
                    }
                    argCount += Int32(args.count)
                } else {
                    pushNetServiceCallbackArgument(L, argument)
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

    func netServiceDidPublish(_ sender: NetService) {
        performCallback(with: "published", usingCallback: callbackRef)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        if callbackRef != Int32(LUA_NOREF) {
            performCallback(with: ["error", netServiceErrorToString(errorDict as [String: Any])] as [Any],
                            usingCallback: callbackRef)
        } else {
            os_log(.default, "%{public}s","\(USERDATA_TAG):publish error:\(netServiceErrorToString(errorDict as [String: Any]))")
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        performCallback(with: "resolved", usingCallback: callbackRef)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if callbackRef != Int32(LUA_NOREF) {
            performCallback(with: ["error", netServiceErrorToString(errorDict as [String: Any])] as [Any],
                            usingCallback: callbackRef)
        } else {
            os_log(.default, "%{public}s","\(USERDATA_TAG):resolve error:\(netServiceErrorToString(errorDict as [String: Any]))")
        }
    }

    // we clear the callback before stopping, but resolveWithTimeout uses this for indicating that the
    // timeout has been reached.
    func netServiceDidStop(_ sender: NetService) {
        performCallback(with: "stop", usingCallback: callbackRef)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        let dataDictionary: Any = NetService.dictionary(fromTXTRecord: data) as Any? ?? NSNull()
        performCallback(with: ["txtRecord", dataDictionary] as [Any], usingCallback: monitorCallbackRef)
    }
}

// MARK: - Module Functions

// hs.bonjour.service.remote is documented with its wrapper in init.lua
private func service_newForResolve(_ L: LuaState) throws -> CInt {
    let name: String = lua_tovalue(L, at: 1) as! String
    let type: String = lua_tovalue(L, at: 2) as! String
    let domain: String = lua_gettop(L) > 2 ? lua_tovalue(L, at: 3) as! String : ""
    let service = NetService(domain: domain, type: type, name: name)
    let wrapper = HSNetServiceWrapper(service: service)
    pushHSNetServiceWrapper(L, wrapper)
    return 1
}

// hs.bonjour.service.new is documented with its wrapper in init.lua
private func service_newForPublish(_ L: LuaState) throws -> CInt {
    let name: String = lua_tovalue(L, at: 1) as! String
    let type: String = lua_tovalue(L, at: 2) as! String
    let port = Int32(lua_tointeger(L, 3))
    let domain: String = lua_gettop(L) > 3 ? lua_tovalue(L, at: 4) as! String : ""
    let service = NetService(domain: domain, type: type, name: name, port: port)
    let wrapper = HSNetServiceWrapper(service: service)
    wrapper.canPublish = true
    pushHSNetServiceWrapper(L, wrapper)
    return 1
}

// MARK: - Module Methods

/// hs.bonjour.service:addresses() -> table
/// Method
/// Returns a table listing the addresses for the service represented by the serviceObject
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array table of strings representing the IPv4 and IPv6 address of the machine which provides the services represented by the serviceObject
///
/// Notes:
///  * for remote serviceObjects, the table will be empty if this method is invoked before [hs.bonjour.service:resolve](#resolve).
///  * for local (published) serviceObjects, this table will always be empty.
private func service_addresses(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper

    lua_newtable(L)
    if let addresses = wrapper.service.addresses {
        for thisAddr in addresses {
            var addrStr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = thisAddr.withUnsafeBytes { ptr -> Int32 in
                let sockAddr = ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                return getnameinfo(sockAddr, socklen_t(thisAddr.count),
                                   &addrStr, socklen_t(addrStr.count),
                                   nil, 0, NI_NUMERICHOST | NI_WITHSCOPEID | NI_NUMERICSERV)
            }
            if err == 0 {
                lua_pushstring(L, addrStr)
                lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            } else {
                lua_pushstring(L, "** error:\(String(cString: gai_strerror(err)!))")
            }
        }
    }
    return 1
}

/// hs.bonjour.service:domain() -> string
/// Method
/// Returns the domain the service represented by the serviceObject belongs to.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the domain the service represented by the serviceObject belongs to.
///
/// Notes:
///  * for remote serviceObjects, this domain will be the domain the service was discovered in.
///  * for local (published) serviceObjects, this domain will be the domain the service is published in; if you did not specify a domain with [hs.bonjour.service.new](#new) then this will be an empty string until [hs.bonjour.service:publish](#publish) is invoked.
private func service_domain(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    lua_pushany(L, wrapper.service.domain as NSString)
    return 1
}

/// hs.bonjour.service:name() -> string
/// Method
/// Returns the name of the service represented by the serviceObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the name of the service represented by the serviceObject.
private func service_name(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    lua_pushany(L, wrapper.service.name as NSString)
    return 1
}

/// hs.bonjour.service:hostname() -> string
/// Method
/// Returns the hostname of the machine the service represented by the serviceObject belongs to.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the hostname of the machine the service represented by the serviceObject belongs to.
///
/// Notes:
///  * for remote serviceObjects, this will be nil if this method is invoked before [hs.bonjour.service:resolve](#resolve).
///  * for local (published) serviceObjects, this method will always return nil.
private func service_hostName(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    lua_pushany(L, wrapper.service.hostName as NSString?)
    return 1
}

/// hs.bonjour.service:type() -> string
/// Method
/// Returns the type of service represented by the serviceObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the type of service represented by the serviceObject.
private func service_type(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    lua_pushany(L, wrapper.service.type as NSString)
    return 1
}

/// hs.bonjour.service:port() -> integer
/// Method
/// Returns the port the service represented by the serviceObject is available on.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a number specifying the port the service represented by the serviceObject is available on.
///
/// Notes:
///  * for remote serviceObjects, this will be -1 if this method is invoked before [hs.bonjour.service:resolve](#resolve).
///  * for local (published) serviceObjects, this method will always return the number specified when the serviceObject was created with the [hs.bonjour.service.new](#new) constructor.
private func service_port(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    lua_pushinteger(L, lua_Integer(wrapper.service.port))
    return 1
}

/// hs.bonjour.service:txtRecord([records]) -> table | serviceObject | false
/// Method
/// Get or set the text records associated with the serviceObject.
///
/// Parameters:
///  * `records` - an optional table specifying the text record for the advertised service as a series of key-value entries. All keys and values must be specified as strings.
///
/// Returns:
///  * if an argument is provided to this method, returns the serviceObject or false if there was a problem setting the text record for this service. If no argument is provided, returns the current table of text records.
///
/// Notes:
///  * for remote serviceObjects, this method will return nil if invoked before [hs.bonjour.service:resolve](#resolve)
///  * setting the text record for a service replaces the existing records for the serviceObject. If the serviceObject is remote, this change is only visible on the local machine. For a service you are advertising, this change will be advertised to other machines.
///
///  * Text records are usually used to provide additional information concerning the service and their purpose and meanings are service dependant; for example, when advertising an `_http._tcp.` service, you can specify a specific path on the server by specifying a table of text records containing the "path" key.
private func service_TXTRecordData(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    if lua_gettop(L) == 1 {
        if let txtRecord = wrapper.service.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtRecord) as NSDictionary
            lua_pushany(L, dict)
        } else {
            lua_pushnil(L)
        }
    } else {
        var txtRecord: Data? = nil
        if lua_type(L, 2) == LUA_TTABLE {
            let dict = lua_tovalue(L, at: 2) as? NSDictionary
            var errMsg: String? = nil
            if let dict = dict as? [String: Any] {
                for (key, value) in dict {
                    if !(value is String) && !(value is Data) {
                        errMsg = "value for key \(key) must be a string"
                        break
                    }
                }
            } else {
                errMsg = "expected table of key-value pairs"
            }
            if let errMsg = errMsg {
                throw LuaCallError("bad argument #2 (\(errMsg))")
            }
            txtRecord = NetService.data(fromTXTRecord: dict as! [String: Data])
        }
        if wrapper.service.setTXTRecord(txtRecord) {
            lua_pushvalue(L, 1)
        } else {
            lua_pushboolean(L, 0)
        }
    }
    return 1
}

/// hs.bonjour.service:includesPeerToPeer([value]) -> boolean | serviceObject
/// Method
/// Get or set whether the service represented by the service object should be published or resolved over peer-to-peer Bluetooth and Wi-Fi, if available.
///
/// Parameters:
///  * `value` - an optional boolean, default false, specifying whether advertising and resolving should occur over peer-to-peer Bluetooth and Wi-Fi, if available.
///
/// Returns:
///  * if `value` is provided, returns the serviceObject; otherwise returns the current value.
///
/// Notes:
///  * if you are changing the value of this property, you must call this method before invoking [hs.bonjour.service:publish](#publish] or [hs.bonjour.service:resolve](#resolve), or after stopping publishing or resolving with [hs.bonjour.service:stop](#stop).
///
///  * for remote serviceObjects, this flag determines if resolution and text record monitoring should occur over peer-to-peer network interfaces.
///  * for local (published) serviceObjects, this flag determines if advertising should occur over peer-to-peer network interfaces.
private func service_includesPeerToPeer(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, wrapper.service.includesPeerToPeer ? 1 : 0)
    } else {
        wrapper.service.includesPeerToPeer = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.bonjour.service:publish([allowRename], [callback]) -> serviceObject
/// Method
/// Begin advertising the specified local service.
///
/// Parameters:
///  * `allowRename` - an optional boolean, default true, specifying whether to automatically rename the service if the name and type combination is already being published in the service's domain. If renaming is allowed and a conflict occurs, the service name will have `-#` appended to it where `#` is an increasing integer starting at 2.
///  * `callback`    - an optional callback function which should expect 2 or 3 arguments and return none. The arguments to the callback function will be one of the following sets:
///    * on successful publishing:
///      * the serviceObject userdata
///      * the string "published"
///    * if an error occurs during publishing:
///      * the serviceObject userdata
///      * the string "error"
///      * a string specifying the specific error that occurred
///
/// Returns:
///  * the serviceObject
///
/// Notes:
///  * this method should only be called on serviceObjects which were created with [hs.bonjour.service.new](#new).
private func service_publish(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    if !wrapper.canPublish { throw LuaCallError("can't publish a service created for resolution") }

    var allowRename = true
    var hasFunction = false
    switch lua_gettop(L) {
    case 1:
        break
    case 2:
        hasFunction = lua_type(L, 2) != LUA_TBOOLEAN
        if !hasFunction { allowRename = lua_toboolean(L, 2) != 0 }
    default:
        hasFunction = true
        allowRename = lua_toboolean(L, 2) != 0
    }

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, wrapper.callbackRef)


    wrapper.callbackRef = LUA_NOREF
    wrapper.service.stop()
    if hasFunction {
        lua_pushvalue(L, -1)
        wrapper.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    wrapper.service.publish(options: allowRename ? [] : .noAutoRename)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.bonjour.service:resolve([timeout], [callback]) -> serviceObject
/// Method
/// Resolve the address and details for a discovered service.
///
/// Parameters:
///  * `timeout`  - an optional number, default 0.0, specifying the maximum number of seconds to attempt to resolve the details for this service. Specifying 0.0 means that the resolution should not timeout and that resolution should continue indefinitely.
///  * `callback` - an optional callback function which should expect 2 or 3 arguments and return none.
///    * on successful resolution:
///      * the serviceObject userdata
///      * the string "resolved"
///    * if an error occurs during resolution:
///      * the serviceObject userdata
///      * the string "error"
///      * a string specifying the specific error that occurred
///    * if `timeout` is specified and is any number other than 0.0, the following will be sent to the callback when the timeout has been reached:
///      * the serviceObject userdata
///      * the string "stop"
///
/// Returns:
///  * the serviceObject
///
/// Notes:
///  * this method should only be called on serviceObjects which were returned by an `hs.bonjour` browserObject or created with [hs.bonjour.service.remote](#remote).
///
///  * For a remote service, this method must be called in order to retrieve the [addresses](#addresses), the [port](#port), the [hostname](#hostname), and any the associated [text records](#txtRecord) for the service.
///  * To reduce the usage of system resources, you should generally specify a timeout value or make sure to invoke [hs.bonjour.service:stop](#stop) after you have verified that you have received the details you require.
private func service_resolveWithTimeout(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    if wrapper.canPublish { throw LuaCallError("can't resolve a service created for publishing") }

    var duration: TimeInterval = 0.0
    var hasFunction = false
    switch lua_gettop(L) {
    case 1:
        break
    case 2:
        hasFunction = lua_type(L, 2) != LUA_TNUMBER
        if !hasFunction { duration = lua_tonumber(L, 2) }
    default:
        hasFunction = true
        duration = lua_tonumber(L, 2)
    }

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, wrapper.callbackRef)


    wrapper.callbackRef = LUA_NOREF
    wrapper.service.stop()
    if hasFunction {
        lua_pushvalue(L, -1)
        wrapper.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    wrapper.service.resolve(withTimeout: duration)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.bonjour.service:monitor([callback]) -> serviceObject
/// Method
/// Monitor the service for changes to its associated text records.
///
/// Parameters:
///  * `callback` - an optional callback function which should expect 3 arguments:
///    * the serviceObject userdata
///    * the string "txtRecord"
///    * a table containing key-value pairs specifying the new text records for the service
///
/// Returns:
///  * the serviceObject
///
/// Notes:
///  * When monitoring is active, [hs.bonjour.service:txtRecord](#txtRecord) will return the most recent text records observed. If this is the only method by which you check the text records, but you wish to ensure you have the most recent values, you should invoke this method without specifying a callback.
///
///  * When [hs.bonjour.service:resolve](#resolve) is invoked, the text records at the time of resolution are captured for retrieval with [hs.bonjour.service:txtRecord](#txtRecord). Subsequent changes to the text records will not be reflected by [hs.bonjour.service:txtRecord](#txtRecord) unless this method has been invoked (with or without a callback function) and is currently active.
///
///  * You *can* monitor for text changes on local serviceObjects that were created by [hs.bonjour.service.new](#new) and that you are publishing. This can be used to invoke a callback when one portion of your code makes changes to the text records you are publishing and you need another portion of your code to be aware of this change.
private func service_startMonitoring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, wrapper.monitorCallbackRef)


    wrapper.monitorCallbackRef = LUA_NOREF
    wrapper.service.stopMonitoring()
    if lua_gettop(L) == 2 {
        lua_pushvalue(L, -1)
        wrapper.monitorCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    wrapper.service.startMonitoring()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.bonjour.service:stop() -> serviceObject
/// Method
/// Stop advertising or resolving the service specified by the serviceObject
///
/// Parameters:
///  * None
///
/// Returns:
///  * the serviceObject
///
/// Notes:
///  * this method will stop the advertising of a service which has been published with [hs.bonjour.service:publish](#publish) or is being resolved with [hs.bonjour.service:resolve](#resolve).
///
///  * To reduce the usage of system resources, you should make sure to use this method when resolving a remote service if you did not specify a timeout for [hs.bonjour.service:resolve](#resolve) or specified a timeout of 0.0 once you have verified that you have the details you need.
private func service_stop(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, wrapper.callbackRef)

    wrapper.callbackRef = LUA_NOREF
    wrapper.service.stop()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.bonjour.service:stopMonitoring() -> serviceObject
/// Method
/// Stop monitoring a service for changes to its text records.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the serviceObject
///
/// Notes:
///  * This method will stop updating [hs.bonjour.service:txtRecord](#txtRecord) and invoking the callback, if any, assigned with [hs.bonjour.service:monitor](#monitor).
private func service_stopMonitoring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG.utf8Start)
    let wrapper: HSNetServiceWrapper = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, wrapper.monitorCallbackRef)

    wrapper.monitorCallbackRef = LUA_NOREF
    wrapper.service.stopMonitoring()
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

@discardableResult
private func pushHSNetServiceWrapper(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    guard let value = obj as? HSNetServiceWrapper else { return 0 }
    if value.selfRefCount == 0 {
        let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
        luaL_getmetatable(L, USERDATA_TAG_STR)
        lua_setmetatable(L, -2)
        value.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        serviceUDRecords.setObject(NSNumber(value: value.selfRef), forKey: value)
    }
    value.selfRefCount += 1
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(value.selfRef))
    return 1
}

private func toHSNetServiceWrapperFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    if luaL_testudata(L, idx, USERDATA_TAG_STR) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG_STR)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        return Unmanaged<HSNetServiceWrapper>.fromOpaque(ptr.pointee).takeUnretainedValue()
    } else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

@discardableResult
func pushNSNetService(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    guard let netService = obj as? NetService else { return 0 }
    ensureBonjourServiceModuleLoaded(L)
    var valueRef: NSNumber? = nil
    var value: HSNetServiceWrapper? = nil

    let enumerator = serviceUDRecords.keyEnumerator()
    while let key = enumerator.nextObject() as? HSNetServiceWrapper {
        if key.service.isEqual(to: netService) {
            valueRef = serviceUDRecords.object(forKey: key)
            break
        }
    }

    if let valueRef = valueRef {
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(valueRef.int32Value))
        value = lua_toAnyObject(L, at: -1) as? HSNetServiceWrapper
        lua_pop(L, 1)
    } else {
        value = HSNetServiceWrapper(service: netService)
    }

    if let value = value {
        pushHSNetServiceWrapper(L, value)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
    let title = "\(obj.service.name) (\(obj.service.type)\(obj.service.domain))"
    lua_pushany(L, "\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1))))" as NSString)
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, USERDATA_TAG_STR) != nil && luaL_testudata(L, 2, USERDATA_TAG_STR) != nil {
        let obj1 = toHSNetServiceWrapperFromLua(L, 1) as! HSNetServiceWrapper
        let obj2 = toHSNetServiceWrapperFromLua(L, 2) as! HSNetServiceWrapper
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    guard luaL_testudata(L, 1, USERDATA_TAG_STR) != nil else { return 0 }
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG_STR)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let obj = Unmanaged<HSNetServiceWrapper>.fromOpaque(ptr.pointee).takeRetainedValue()
    obj.selfRefCount -= 1
    if obj.selfRefCount == 0 {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.callbackRef)

        obj.callbackRef = LUA_NOREF
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.monitorCallbackRef)

        obj.monitorCallbackRef = LUA_NOREF
        obj.service.delegate = nil
        obj.service.stop()
        obj.service.stopMonitoring()

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.selfRef)


        obj.selfRef = LUA_NOREF
        serviceUDRecords.removeObject(forKey: obj)

        obj.service = nil
    }
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    serviceUDRecords.removeAllObjects()
    return 0
}


@_cdecl("luaopen_hs_libbonjourservice")
public func luaopen_hs_libbonjourservice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG_STR)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(service_addresses);          lua_setfield(L, -2, "addresses")
        L.push(service_domain);             lua_setfield(L, -2, "domain")
        L.push(service_name);               lua_setfield(L, -2, "name")
        L.push(service_hostName);           lua_setfield(L, -2, "hostname")
        L.push(service_type);               lua_setfield(L, -2, "type")
        L.push(service_port);               lua_setfield(L, -2, "port")
        L.push(service_TXTRecordData);      lua_setfield(L, -2, "txtRecord")
        L.push(service_includesPeerToPeer); lua_setfield(L, -2, "includesPeerToPeer")
        L.push(service_resolveWithTimeout); lua_setfield(L, -2, "resolve")
        L.push(service_startMonitoring);    lua_setfield(L, -2, "monitor")
        L.push(service_stop);               lua_setfield(L, -2, "stop")
        L.push(service_stopMonitoring);     lua_setfield(L, -2, "stopMonitoring")
        L.push(service_publish);            lua_setfield(L, -2, "publish")
        L.push(userdata_tostring);          lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq);                lua_setfield(L, -2, "__eq")
        L.push(userdata_gc);                lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 2)
        L.push(service_newForResolve); lua_setfield(L, -2, "remote")
        L.push(service_newForPublish); lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc); lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        serviceUDRecords = NSMapTable.strongToStrongObjects()
    }
}
