import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.ipc"

// MARK: - Support Functions and Classes

class HSIPCMessagePort: NSObject {
    var messagePort: CFMessagePort?
    var callbackValue: LuaValue?
    private var tornDown = false

    /// Idempotent teardown: invalidate the CFMessagePort, drop the Lua callback
    /// reference, mark as torn down.  Called from __gc while the lua_State is
    /// still alive.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let mp = messagePort {
            CFMessagePortInvalidate(mp)
            messagePort = nil
        }
        callbackValue = nil
    }
}

private var callbackInProgress: Int = 0

private let ipc_callback: CFMessagePortCallBack = { (local, msgid, data, info) -> Unmanaged<CFData>? in
    let L = lua_getCurrentState()!
    let port = Unmanaged<HSIPCMessagePort>.fromOpaque(info!).takeUnretainedValue()
    var outdata: Unmanaged<CFData>? = nil

    if callbackInProgress >= 5 {
        os_log(.error, "%{public}s", "hs.ipc callback is being called recursively. Check your callback function, it is triggering further IPC messages. This message was triggered after reaching 5 recursive callbacks.")
        return outdata
    }

    callbackInProgress += 1
    if let cb = port.callbackValue {
        let L = lua_getCurrentState()!
        cb.push(onto: L)
        L.push(userdata: port)
        lua_pushinteger(L, lua_Integer(msgid))
        if let data = data {
            lua_pushany(L, data as NSData)
        } else {
            lua_pushnil(L)
        }
        let status = lua_pcall(L, 3, 1, 0) == LUA_OK

        luaL_tolstring(L, -1, nil) // make sure it's a string
        let portName = port.messagePort.flatMap { CFMessagePortGetName($0) as String? } ?? "unknown"
        os_log(.debug, "%{public}s", "ipc_callback \(portName) debug: \(String(cString: lua_tostring(L, -1)!))")
        let result = NSMutableData()
        var len: Int = 0
        if let ptr = lua_tolstring(L, -1, &len), len > 0 {
            result.append(ptr, length: len)
        }
        if !status {
            os_log(.error, "%{public}s", "\(USERDATA_TAG):callback - error during callback for \(portName): \(String(cString: lua_tostring(L, -2)!))")
        }
        lua_pop(L, 2) // remove the result and the luaL_tostring() version

        if result.length > 0 {
            outdata = Unmanaged.passRetained(result as CFData)
        }
    } else {
        let portName = port.messagePort.flatMap { CFMessagePortGetName($0) as String? } ?? "unknown"
        os_log(.info, "%{public}s", "\(USERDATA_TAG):callback - no callback function defined for \(portName)")
    }

    callbackInProgress -= 1
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
private func ipc_localPort(_ L: LuaState) throws -> CInt {
    let portName = lua_tovalue(L, at: 1) as! String

    let port = HSIPCMessagePort()
    lua_pushvalue(L, 2)
    port.callbackValue = L.ref(index: -1)
    lua_pop(L, 1)

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
        throw LuaCallError(errorMsg)
    }

    guard let mp = port.messagePort else {
        throw LuaCallError("failed to create new local port")
    }

    guard let runLoopSource = CFMessagePortCreateRunLoopSource(nil, mp, 0) else {
        port.messagePort = nil
        throw LuaCallError("unable to create runloop source for local port")
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

    L.push(userdata: port)
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
private func ipc_remotePort(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let portName = lua_tovalue(L, at: 1) as! String

    let port = HSIPCMessagePort()
    port.messagePort = CFMessagePortCreateRemote(nil, portName as CFString)
    guard port.messagePort != nil else {
        throw LuaCallError("failed to create new remote port")
    }
    L.push(userdata: port)
    return 1
}

// MARK: - Module Methods

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
private func ipc_sendMessage(_ L: LuaState) throws -> CInt {
    let port: HSIPCMessagePort = try L.checkArgument(1)
    guard CFMessagePortIsValid(port.messagePort) else {
        throw LuaCallError("ipc port is no longer valid (early)")
    }
    guard CFMessagePortIsRemote(port.messagePort) else {
        throw LuaCallError("not a remote port")
    }

    luaL_tolstring(L, 2, nil) // make sure it's a string
    var dataLen: Int = 0
    let data: Data?
    if let ptr = lua_tolstring(L, -1, &dataLen), dataLen > 0 {
        data = Data(bytes: ptr, count: dataLen)
    } else {
        data = nil
    }
    lua_pop(L, 1)

    let msgID = lua_tointeger(L, 3)

    let waitTimeout: CFTimeInterval = (lua_gettop(L) >= 4 && lua_isnumber(L, 4))
        ? CFTimeInterval(lua_tonumber(L, 4)) : 2.0

    let oneWay = lua_isboolean(L, -1) ? (lua_toboolean(L, -1) != 0) : false

    let portName = CFMessagePortGetName(port.messagePort) as String? ?? "unknown"
    os_log(.debug, "%{public}s", "ipc_sendMessage on \(portName)")

    var returnedData: Unmanaged<CFData>?
    guard CFMessagePortIsValid(port.messagePort) else {
        throw LuaCallError("ipc port is no longer valid (late)")
    }
    var code: Int32 = -1
    if let error = catchingObjCException({
        code = CFMessagePortSendRequest(
            port.messagePort,
            Int32(msgID),
            data as CFData?,
            waitTimeout,
            oneWay ? 0.0 : waitTimeout,
            oneWay ? nil : CFRunLoopMode.defaultMode.rawValue,
            &returnedData
        )
    }) {
        throw LuaCallError("ObjC exception in CFMessagePortSendRequest: \(error)")
    }
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
    lua_pushany(L, response as NSData?)
    return 2
}

// MARK: - Cosmic Hammer/Lua Infrastructure

@_cdecl("luaopen_hs_libipc")
public func luaopen_hs_libipc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        callbackInProgress = 0

        L.register(Metatable<HSIPCMessagePort>(
            fields: [
                "name": .closure { L in
                    let port: HSIPCMessagePort = try L.checkArgument(1)
                    let name = CFMessagePortGetName(port.messagePort) as String?
                    lua_pushany(L, name as NSString?)
                    return 1
                },
                "delete": .closure { L in
                    let port: HSIPCMessagePort = try L.checkArgument(1)
                    port.teardown()
                    return 0
                },
                "isRemote": .closure { L in
                    let port: HSIPCMessagePort = try L.checkArgument(1)
                    lua_pushboolean(L, CFMessagePortIsRemote(port.messagePort) ? 1 : 0)
                    return 1
                },
                "isValid": .closure { L in
                    let port: HSIPCMessagePort = try L.checkArgument(1)
                    lua_pushboolean(L, CFMessagePortIsValid(port.messagePort) ? 1 : 0)
                    return 1
                },
                "sendMessage": .closure(ipc_sendMessage),
            ],
            tostring: .closure { L in
                let port: HSIPCMessagePort = try L.checkArgument(1)
                let portName = port.messagePort.flatMap { CFMessagePortGetName($0) as String? } ?? "unknown"
                let locality = port.messagePort.flatMap { CFMessagePortIsRemote($0) ? "remote" : "local" } ?? "unknown"
                let title = "\(portName), \(locality)"
                lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
                return 1
            }
        ))

        // Post-registration metatable patching: replace __gc with teardown + deinit,
        // set __type/__name, and alias to the registry.
        L.pushMetatable(for: HSIPCMessagePort.self)

        // __eq: compare the underlying HSIPCMessagePort identity
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            if let obj1: HSIPCMessagePort = L.touserdata(1),
               let obj2: HSIPCMessagePort = L.touserdata(2) {
                lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
            } else {
                lua_pushboolean(L, 0)
            }
            return 1
        }, 0)
        lua_setfield(L, -2, "__eq")

        // Replace __gc with our explicit teardown + deinitialize
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            if let port: HSIPCMessagePort = L.touserdata(1) {
                port.teardown()
            }
            let rawptr = lua_touserdata(L, 1)!
            let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
            anyPtr.deinitialize(count: 1)
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
        lua_pushstring(L, USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        lua_pushstring(L, USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the legacy registry name so that
        // core_getObjectMetatable("hs.ipc") still resolves.
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        lua_createtable(L, 0, 2)
        L.push(ipc_localPort)
        lua_setfield(L, -2, "localPort")
        L.push(ipc_remotePort)
        lua_setfield(L, -2, "remotePort")
    }
}
