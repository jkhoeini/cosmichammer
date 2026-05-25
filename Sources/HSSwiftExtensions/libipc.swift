import Cocoa
import LuaSkin

private let USERDATA_TAG = "hs.ipc"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions and Classes

class HSIPCMessagePort: NSObject {
    var messagePort: CFMessagePort?
    var callbackRef: Int32 = LUA_NOREF
    var selfRef: Int = 0
}

private var callbackInProgress: Int = 0

private let ipc_callback: CFMessagePortCallBack = { (local, msgid, data, info) -> Unmanaged<CFData>? in
    let skin = LuaSkin.skin(with: nil)
    let port = Unmanaged<HSIPCMessagePort>.fromOpaque(info!).takeUnretainedValue()
    var outdata: Unmanaged<CFData>? = nil

    if callbackInProgress >= 5 {
        skin.logError("hs.ipc callback is being called recursively. Check your callback function, it is triggering further IPC messages. This message was triggered after reaching 5 recursive callbacks.")
        return outdata
    }

    callbackInProgress += 1

    _lua_stackguard_entry(skin.l)
    if port.callbackRef != LUA_NOREF {
        let L = skin.l!
        skin.pushLuaRef(refTable, ref: port.callbackRef)
        skin.pushNSObject(port)
        lua_pushinteger(L, lua_Integer(msgid))
        if let data = data {
            skin.pushNSObject(data as NSData)
        } else {
            lua_pushnil(L)
        }
        let status = skin.protectedCallAndTraceback(3, nresults: 1)

        luaL_tolstring(L, -1, nil) // make sure it's a string
        let portName = port.messagePort.flatMap { CFMessagePortGetName($0) as String? } ?? "unknown"
        skin.logDebug("ipc_callback \(portName) debug: \(String(cString: lua_tostring(L, -1)!))")
        let result = NSMutableData()
        if let obj = skin.toNSObject(atIndex: -1, withOptions: .nsLuaStringAsDataOnly) as? Data {
            result.append(obj)
        }
        if !status {
            skin.logError("\(USERDATA_TAG):callback - error during callback for \(portName): \(String(cString: lua_tostring(L, -2)!))")
        }
        lua_pop(L, 2) // remove the result and the luaL_tostring() version

        if result.length > 0 {
            outdata = Unmanaged.passRetained(result as CFData)
        }
    } else {
        let portName = port.messagePort.flatMap { CFMessagePortGetName($0) as String? } ?? "unknown"
        skin.logWarn("\(USERDATA_TAG):callback - no callback function defined for \(portName)")
    }

    callbackInProgress -= 1
    _lua_stackguard_exit(skin.l)
    return outdata
}

// MARK: - Module Functions

/// hs.ipc.localPort(name, fn) -> ipcObject
/// Constructor
/// Create a new local ipcObject for receiving and responding to messages from a remote port
///
/// Parameters:
///  * name - a string acting as the message port name.
///  * fn   - the callback function which will receive messages.
///
/// Returns:
///  * the ipc object
///
/// Notes:
///  * a remote port can send messages at any time to a local port; a local port can only respond to messages from a remote port
private func ipc_localPort(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION, LS_TBREAK)
    let portName = skin.toNSObject(atIndex: 1) as! String

    let port = HSIPCMessagePort()
    lua_pushvalue(L, 2)
    port.callbackRef = skin.luaRef(refTable)

    var ctx = CFMessagePortContext(
        version: 0,
        info: Unmanaged.passUnretained(port).toOpaque(),
        retain: nil, release: nil, copyDescription: nil
    )
    var shouldFreeInfo: DarwinBoolean = false
    port.messagePort = CFMessagePortCreateLocal(nil, portName as CFString, ipc_callback, &ctx, &shouldFreeInfo)

    if shouldFreeInfo.boolValue {
        let errorMsg = port.messagePort != nil ? "local port name already in use" : "failed to create new local port"
        port.messagePort = nil
        return luaL_error(L, errorMsg)
    }

    guard let mp = port.messagePort else {
        return luaL_error(L, "failed to create new local port")
    }

    guard let runLoopSource = CFMessagePortCreateRunLoopSource(nil, mp, 0) else {
        port.messagePort = nil
        return luaL_error(L, "unable to create runloop source for local port")
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

    skin.pushNSObject(port)
    return 1
}

/// hs.ipc.remotePort(name) -> ipcObject
/// Constructor
/// Create a new remote ipcObject for sending messages asynchronously to a local port
///
/// Parameters:
///  * name - a string acting as the message port name.
///
/// Returns:
///  * the ipc object
///
/// Notes:
///  * a remote port can send messages at any time to a local port; a local port can only respond to messages from a remote port
private func ipc_remotePort(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let portName = skin.toNSObject(atIndex: 1) as! String

    let port = HSIPCMessagePort()
    port.messagePort = CFMessagePortCreateRemote(nil, portName as CFString)
    guard port.messagePort != nil else {
        return luaL_error(L, "failed to create new remote port")
    }
    skin.pushNSObject(port)
    return 1
}

// MARK: - Module Methods

/// hs.ipc:name() -> string
/// Method
/// Returns the name the ipcObject uses for its port when active
///
/// Parameters:
///  * None
///
/// Returns:
///  * the port name as a string
private func ipc_name(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK)
    let port = skin.toNSObject(atIndex: 1) as! HSIPCMessagePort

    let name = CFMessagePortGetName(port.messagePort) as String?
    skin.pushNSObject(name as NSString?)
    return 1
}

/// hs.ipc:isRemote() -> boolean
/// Method
/// Returns whether or not the ipcObject represents a remote or local port
///
/// Parameters:
///  * None
///
/// Returns:
///  * true if the object is a remote port, otherwise false
///
/// Notes:
///  * a remote port can send messages at any time to a local port; a local port can only respond to messages from a remote port
private func ipc_isRemote(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK)
    let port = skin.toNSObject(atIndex: 1) as! HSIPCMessagePort

    lua_pushboolean(L, CFMessagePortIsRemote(port.messagePort) ? 1 : 0)
    return 1
}

/// hs.ipc:isValid() -> boolean
/// Method
/// Returns whether or not the ipcObject port is still valid or not
///
/// Parameters:
///  * None
///
/// Returns:
///  * true if the object is a valid port, otherwise false
private func ipc_isValid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK)
    let port = skin.toNSObject(atIndex: 1) as! HSIPCMessagePort

    lua_pushboolean(L, CFMessagePortIsValid(port.messagePort) ? 1 : 0)
    return 1
}

/// hs.ipc:sendMessage(data, msgID, [waitTimeout], [oneWay]) -> status, response
/// Method
/// Sends a message from a remote port to a local port
///
/// Parameters:
///  * data        - any data type which is to be sent to the local port.  The data will be converted into its string representation
///  * msgID       - an integer message ID
///  * waitTimeout - an optional number, default 2.0, representing the number of seconds the method will wait to send the message and then wait for a response.  The method *may* block up to twice this number of seconds, though usually it will be shorter.
///  * oneWay      -  an optional boolean, default false, indicating whether or not to wait for a response.  It this is true, the second returned argument will be nil.
///
/// Returns:
///  * status   - a boolean indicating whether or not the local port responded before the timeout (true) or if an error or timeout occurred waiting for the response (false)
///  * response - the response from the local port, usually a string, but may be nil if there was no response returned.  If status is false, will contain an error message describing the error.
private func ipc_sendMessage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self),
                   LS_TANY,
                   LS_TNUMBER | LS_TINTEGER,
                   LS_TNUMBER | LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)

    let port = skin.toNSObject(atIndex: 1) as! HSIPCMessagePort
    guard CFMessagePortIsValid(port.messagePort) else {
        return luaL_error(L, "ipc port is no longer valid (early)")
    }
    guard CFMessagePortIsRemote(port.messagePort) else {
        return luaL_error(L, "not a remote port")
    }

    luaL_tolstring(L, 2, nil) // make sure it's a string
    let data = skin.toNSObject(atIndex: -1, withOptions: .nsLuaStringAsDataOnly) as? Data
    lua_pop(L, 1)

    let msgID = lua_tointeger(L, 3)

    let waitTimeout: CFTimeInterval = (lua_gettop(L) >= 4 && lua_isnumber(L, 4))
        ? CFTimeInterval(lua_tonumber(L, 4)) : 2.0

    let oneWay = lua_isboolean(L, -1) ? (lua_toboolean(L, -1) != 0) : false

    let portName = CFMessagePortGetName(port.messagePort) as String? ?? "unknown"
    skin.logDebug("ipc_sendMessage on \(portName)")

    var returnedData: Unmanaged<CFData>?
    guard CFMessagePortIsValid(port.messagePort) else {
        return luaL_error(L, "ipc port is no longer valid (late)")
    }
    let code = CFMessagePortSendRequest(
        port.messagePort,
        Int32(msgID),
        data as CFData?,
        waitTimeout,
        oneWay ? 0.0 : waitTimeout,
        oneWay ? nil : CFRunLoopMode.defaultMode.rawValue,
        &returnedData
    )
    let status = (code == kCFMessagePortSuccess)

    var response: Data?
    if status {
        if !oneWay {
            response = returnedData?.takeRetainedValue() as Data?
        }
    } else {
        let errMsg: String
        switch code {
        case kCFMessagePortSendTimeout:        errMsg = "send timeout"
        case kCFMessagePortReceiveTimeout:     errMsg = "receive timeout"
        case kCFMessagePortIsInvalid:          errMsg = "message port invalid"
        case kCFMessagePortTransportError:     errMsg = "error during transport"
        case kCFMessagePortBecameInvalidError: errMsg = "message port was invalidated"
        default:                               errMsg = "unrecognized error: \(code)"
        }
        response = errMsg.data(using: .utf8)
    }

    lua_pushboolean(L, status ? 1 : 0)
    skin.pushNSObject(response as NSData?)
    return 2
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSIPCMessagePort(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let value = obj as! HSIPCMessagePort
    value.selfRef += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    valuePtr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSIPCMessagePortFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.skin(with: L)
    guard luaL_testudata(L, idx, USERDATA_TAG) != nil else {
        skin.logError("expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
    let ptr = lua_touserdata(L, idx)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee!
    return Unmanaged<HSIPCMessagePort>.fromOpaque(ptr).takeUnretainedValue()
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at: 1, toClass: "HSIPCMessagePort") as! HSIPCMessagePort
    let portName = obj.messagePort.flatMap { CFMessagePortGetName($0) as String? } ?? "unknown"
    let locality = obj.messagePort.flatMap { CFMessagePortIsRemote($0) ? "remote" : "local" } ?? "unknown"
    let title = "\(portName), \(locality)"
    skin.pushNSObject("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1))))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "HSIPCMessagePort") as! HSIPCMessagePort
        let obj2 = skin.luaObject(at: 2, toClass: "HSIPCMessagePort") as! HSIPCMessagePort
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.ipc:delete() -> None
/// Method
/// Deletes the ipcObject, stopping it as well if necessary
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let raw = ptr.pointee {
        let obj = Unmanaged<HSIPCMessagePort>.fromOpaque(raw).takeRetainedValue()
        obj.selfRef -= 1
        if obj.selfRef == 0 {
            let skin = LuaSkin.skin(with: L)
            obj.callbackRef = skin.luaUnref(refTable, ref: obj.callbackRef)
            if let mp = obj.messagePort {
                CFMessagePortInvalidate(mp)
                obj.messagePort = nil
            }
        }
    }
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - C-callable wrappers

private let ipc_localPort_wrapper: lua_CFunction = { L in ipc_localPort(L) }
private let ipc_remotePort_wrapper: lua_CFunction = { L in ipc_remotePort(L) }
private let ipc_name_wrapper: lua_CFunction = { L in ipc_name(L) }
private let ipc_isRemote_wrapper: lua_CFunction = { L in ipc_isRemote(L) }
private let ipc_isValid_wrapper: lua_CFunction = { L in ipc_isValid(L) }
private let ipc_sendMessage_wrapper: lua_CFunction = { L in ipc_sendMessage(L) }
private let userdata_tostring_wrapper: lua_CFunction = { L in userdata_tostring(L) }
private let userdata_eq_wrapper: lua_CFunction = { L in userdata_eq(L) }
private let userdata_gc_wrapper: lua_CFunction = { L in userdata_gc(L) }

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("name"), func: ipc_name_wrapper),
    luaL_Reg(name: strdup("delete"), func: userdata_gc_wrapper),
    luaL_Reg(name: strdup("isRemote"), func: ipc_isRemote_wrapper),
    luaL_Reg(name: strdup("isValid"), func: ipc_isValid_wrapper),
    luaL_Reg(name: strdup("sendMessage"), func: ipc_sendMessage_wrapper),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring_wrapper),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq_wrapper),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc_wrapper),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("localPort"), func: ipc_localPort_wrapper),
    luaL_Reg(name: strdup("remotePort"), func: ipc_remotePort_wrapper),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libipc")
public func luaopen_hs_libipc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    callbackInProgress = 0
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                     functions: &moduleLib,
                                     metaFunctions: nil,
                                     objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushHSIPCMessagePort, forClass: "HSIPCMessagePort")
    skin.registerLuaObjectHelper(toHSIPCMessagePortFromLua, forClass: "HSIPCMessagePort",
                                  withUserdataMapping: USERDATA_TAG)

    return 1
}
