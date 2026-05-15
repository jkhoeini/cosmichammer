import Cocoa
import LuaSkin
import CocoaAsyncSocket

// socket.h shared definitions are duplicated here since Swift can't import the C header directly.
// The refTable, asyncSocketUserData struct, and constants are defined in socket.h and shared
// between libsocket.m and libsocket_udp.m. In Swift each file gets its own copy.

private func mainThreadDispatch(_ block: @escaping () -> Void) {
    DispatchQueue.main.async { autoreleasepool { block() } }
}

// Userdata struct matching socket.h's asyncSocketUserData
private struct AsyncSocketUserData {
    var selfRef: Int32 = 0
    var asyncSocket: UnsafeMutableRawPointer? = nil
}

private let DEFAULT: NSString = "DEFAULT"
private let SERVER: NSString = "SERVER"
private let CLIENT: NSString = "CLIENT"

private var refTable: LSRefTable = LUA_NOREF
private let USERDATA_TAG = "hs.socket"

// Helper to extract the HSAsyncTcpSocket from userdata
private func getUserData(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSAsyncTcpSocket {
    let ud = lua_touserdata(L, idx)!.assumingMemoryBound(to: AsyncSocketUserData.self)
    return Unmanaged<HSAsyncTcpSocket>.fromOpaque(ud.pointee.asyncSocket!).takeUnretainedValue()
}

// MARK: - Lua Callbacks

private func tcpConnectCallback(_ asyncSocket: HSAsyncTcpSocket) {
    mainThreadDispatch {
        if asyncSocket.readCallbackRef != LUA_NOREF || asyncSocket.connectCallbackRef != LUA_NOREF {
            // Only fire if connectCallback is set
            guard asyncSocket.connectCallbackRef != LUA_NOREF else { return }
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: asyncSocket.connectCallbackRef)
            asyncSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.connectCallbackRef)
            skin.protectedCallAndError("hs.socket:connect callback", nargs: 0, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

private func tcpWriteCallback(_ asyncSocket: HSAsyncTcpSocket, tag: Int) {
    mainThreadDispatch {
        if asyncSocket.writeCallbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: asyncSocket.writeCallbackRef)
            skin.pushNSObject(NSNumber(value: tag))
            asyncSocket.writeCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.writeCallbackRef)
            skin.protectedCallAndError("hs.socket:write callback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

private func tcpReadCallback(_ asyncSocket: HSAsyncTcpSocket, data: Data, tag: Int) {
    mainThreadDispatch {
        if asyncSocket.readCallbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: asyncSocket.readCallbackRef)
            skin.pushNSObject(data as NSData, withOptions: LS_NSConversionOptions.nsLuaStringAsDataOnly.rawValue)
            skin.pushNSObject(NSNumber(value: tag))
            skin.protectedCallAndError("hs.socket:read callback", nargs: 2, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

// MARK: - TCP Socket Class

private class HSAsyncTcpSocket: GCDAsyncSocket, GCDAsyncSocketDelegate {
    var readCallbackRef: Int32 = LUA_NOREF
    var writeCallbackRef: Int32 = LUA_NOREF
    var connectCallbackRef: Int32 = LUA_NOREF
    var socketTimeout: TimeInterval = -1
    var connectedSockets: NSMutableArray = NSMutableArray()
    var unixSocketPath: String?

    init(asDelegateQueue label: String = "tcpDelegateQueue") {
        let tcpDelegateQueue = DispatchQueue(label: label)
        super.init(delegate: nil, delegateQueue: tcpDelegateQueue, socketQueue: nil)
        self.delegate = self
    }

    func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        LuaSkin.skin(with: nil).logDebug("TCP socket connected")
        self.userData = DEFAULT
        if self.connectCallbackRef != LUA_NOREF {
            tcpConnectCallback(self)
        }
    }

    func socket(_ sock: GCDAsyncSocket, didConnectTo url: URL) {
        LuaSkin.skin(with: nil).logDebug("TCP Unix domain socket connected")
        self.userData = DEFAULT
        self.unixSocketPath = url.path
        if self.connectCallbackRef != LUA_NOREF {
            tcpConnectCallback(self)
        }
    }

    func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        LuaSkin.skin(with: nil).logDebug("TCP client connected")
        newSocket.userData = CLIENT

        objc_sync_enter(self.connectedSockets)
        self.connectedSockets.add(newSocket)
        objc_sync_exit(self.connectedSockets)
    }

    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        if sock.userData as? NSString == CLIENT {
            LuaSkin.skin(with: nil).logDebug("TCP client disconnected: \(err?.localizedDescription ?? "")")
            objc_sync_enter(self.connectedSockets)
            self.connectedSockets.remove(sock)
            objc_sync_exit(self.connectedSockets)
        } else if sock.userData as? NSString == SERVER {
            LuaSkin.skin(with: nil).logDebug("TCP server disconnected: \(err?.localizedDescription ?? "")")
            objc_sync_enter(self.connectedSockets)
            for client in self.connectedSockets {
                (client as? HSAsyncTcpSocket)?.disconnect()
            }
            objc_sync_exit(self.connectedSockets)
            if let path = self.unixSocketPath {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    LuaSkin.skin(with: nil).logError("Could not remove created Unix domain socket: \(error.localizedDescription)")
                }
                self.unixSocketPath = nil
            }
        } else {
            LuaSkin.skin(with: nil).logDebug("TCP socket disconnected: \(err?.localizedDescription ?? "")")
        }

        sock.userData = nil
    }

    func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        if self.writeCallbackRef != LUA_NOREF {
            tcpWriteCallback(self, tag: tag)
        }
    }

    func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        if self.readCallbackRef != LUA_NOREF {
            tcpReadCallback(self, data: data, tag: tag)
        }
    }

    func socket(_ sock: GCDAsyncSocket, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        // Allow TLS handshake without trust evaluation for self-signed certificates
        // This is only called if startTLS is invoked with option GCDAsyncSocketManuallyEvaluateTrust == YES
        completionHandler(true)
    }

    func socketDidSecure(_ sock: GCDAsyncSocket) {
        LuaSkin.skin(with: nil).logDebug("TCP socket secured")
    }
}

// MARK: - Module Functions

/// hs.socket.new([fn]) -> hs.socket object
/// Constructor
/// Creates an unconnected asynchronous TCP socket object.
///
/// Parameters:
///  * `fn` - An optional [callback function](#setCallback) for reading data from the socket, settable here for convenience.
///
/// Returns:
///  * An [`hs.socket`](#new) object.
///
private func socket_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let asyncSocket = HSAsyncTcpSocket()

    if lua_type(L, 1) == LUA_TFUNCTION {
        lua_pushvalue(L, 1)
        asyncSocket.readCallbackRef = skin.luaRef(refTable)
    }

    skin.requireModule("hs.socket")
    lua_getfield(skin.l, -1, "timeout")
    asyncSocket.socketTimeout = lua_tonumber(skin.l, -1)

    let userData = lua_newuserdata(L, MemoryLayout<AsyncSocketUserData>.size)!
        .assumingMemoryBound(to: AsyncSocketUserData.self)
    userData.pointee = AsyncSocketUserData()
    userData.pointee.asyncSocket = Unmanaged.passRetained(asyncSocket).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.socket.parseAddress(sockaddr) -> table or nil
/// Function
/// Parses a binary socket address structure into a readable table.
///
/// Parameters:
///  * `sockaddr` - A binary socket address structure, usually obtained from the [`info`](#info) method or in [`hs.socket.udp`](./hs.socket.udp.html)'s [read callback](./hs.socket.udp.html#setCallback).
///
/// Returns:
///  * A table describing the address with the following keys or `nil`:
///   * host - A string containing the host IP.
///   * port - A number containing the port.
///   * addressFamily - A number containing the address family.
///
/// Notes:
///  * Some address family definitions from `<sys/socket.h>`:
///
/// address family | number | description
/// :--- | :--- | :---
/// AF_UNSPEC | 0 | unspecified
/// AF_UNIX | 1 | local to host (pipes)
/// AF_LOCAL | AF_UNIX | backward compatibility
/// AF_INET | 2 | internetwork: UDP, TCP, etc.
/// AF_NS | 6 | XEROX NS protocols
/// AF_CCITT | 10 | CCITT protocols, X.25 etc
/// AF_APPLETALK | 16 | Apple Talk
/// AF_ROUTE | 17 | Internal Routing Protocol
/// AF_LINK | 18 | Link layer interface
/// AF_INET6 | 30 | IPv6
///
private func socket_parseAddress(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let addressData = lua_tostring(L, 1)!
    let addressDataLength: Int = lua_rawlen(L, 1)
    let address = Data(bytes: addressData, count: addressDataLength)

    var host: NSString?
    var port: UInt16 = 0
    var addressFamily: sa_family_t = 0

    if GCDAsyncSocket.getHost(&host, port: &port, family: &addressFamily, fromAddress: address) {
        skin.pushNSObject([
            "host": host!,
            "port": NSNumber(value: port),
            "addressFamily": NSNumber(value: addressFamily),
        ] as NSDictionary)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.socket:connect(host, port | path [, fn]) -> self or nil
/// Method
/// Connects an unconnected socket.
///
/// Parameters:
///  * `host` - A string containing the hostname or IP address.
///  * `port` - A port number [1-65535].
///  * `path` - A string containing the path to the Unix domain socket.
///  * `fn` - An optional single-use callback function to execute after establishing the connection. The callback receives no parameters.
///
/// Returns:
///  * The [`hs.socket`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Either a host/port pair OR a Unix domain socket path must be supplied. If no port is passed, the first parameter is assumed to be a path to the socket file.
///
private func socket_connect(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TANY | LS_TOPTIONAL, LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)

    if lua_type(L, 3) == LUA_TNUMBER {
        skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER | LS_TINTEGER, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
        let theHost = skin.toNSObject(atIndex:2) as! String
        let thePort = (skin.toNSObject(atIndex:3) as! NSNumber).uint16Value
        if lua_type(L, 4) == LUA_TFUNCTION {
            lua_pushvalue(L, 4)
            asyncSocket.connectCallbackRef = skin.luaRef(refTable)
        }

        do {
            try asyncSocket.connect(toHost: theHost, onPort: thePort, withTimeout: asyncSocket.socketTimeout)
        } catch {
            asyncSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.connectCallbackRef)
            skin.logError("Unable to connect to host/port: \(error.localizedDescription)")
            lua_pushnil(L)
            return 1
        }
    } else {
        skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
        let thePath = (skin.toNSObject(atIndex:2) as! NSString).expandingTildeInPath
        if lua_type(L, 3) == LUA_TFUNCTION {
            lua_pushvalue(L, 3)
            asyncSocket.connectCallbackRef = skin.luaRef(refTable)
        }

        if let connectURL = URL(string: thePath) {
            do {
                try asyncSocket.connect(to: connectURL, withTimeout: asyncSocket.socketTimeout)
            } catch {
                asyncSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.connectCallbackRef)
                skin.logError("Unable to connect to Unix domain socket: \(error.localizedDescription)")
                lua_pushnil(L)
                return 1
            }
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:listen(port|path) -> self or nil
/// Method
/// Binds an unconnected socket to either a port or path (Unix domain socket) for listening.
///
/// Parameters:
///  * `port` - A port number [0-65535]. Ports [1-1023] are privileged. Port 0 allows the OS to select any available port.
///  * `path` - A string containing the path to the Unix domain socket.
///
/// Returns:
///  * The [`hs.socket`](#new) object, or `nil` if an error occurred.
///
private func socket_listen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TSTRING, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)

    if lua_type(L, 2) == LUA_TNUMBER {
        let thePort = (skin.toNSObject(atIndex:2) as! NSNumber).uint16Value
        do {
            try asyncSocket.accept(onPort: thePort)
            asyncSocket.userData = SERVER
        } catch {
            skin.logError("Unable to bind port: \(error.localizedDescription)")
            lua_pushnil(L)
            return 1
        }
    } else {
        var thePath = skin.toNSObject(atIndex:2) as! String
        thePath = (thePath as NSString).expandingTildeInPath
        if let acceptURL = URL(string: thePath) {
            do {
                try asyncSocket.accept(on: acceptURL)
                asyncSocket.unixSocketPath = thePath
                asyncSocket.userData = SERVER
            } catch {
                skin.logError("Unable to bind Unix domain path: \(error.localizedDescription)")
                lua_pushnil(L)
                return 1
            }
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:disconnect() -> self
/// Method
/// Disconnects the socket, freeing it for reuse.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket`](#new) object.
///
/// Notes:
///  * If called on a listening socket with multiple connections, each client is disconnected.
///
private func socket_disconnect(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)

    asyncSocket.disconnect()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:read(delimiter[, tag]) -> self or nil
/// Method
/// Read data from the socket.
///
/// Parameters:
///  * `delimiter` - Either a number of bytes to read, or a string delimiter such as "\\n" or "\\r\\n". Data is read up to and including the delimiter.
///  * `tag` - An optional integer to assist with labeling reads. It is passed to the callback to assist with implementing [state machines](https://github.com/robbiehanson/CocoaAsyncSocket/wiki/Intro_GCDAsyncSocket#reading--writing) for processing complex protocols.
///
/// Returns:
///  * The [`hs.socket`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Results are passed to the socket's [callback function](#setCallback), which must be set to use this method.
///  * If called on a listening socket with multiple connections, data is read from each of them.
///
private func socket_read(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TSTRING, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)
    let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1

    if asyncSocket.readCallbackRef == LUA_NOREF {
        skin.logError("No callback defined!")
        lua_pushnil(L)
        return 1
    }

    switch lua_type(L, 2) {
    case LUA_TNUMBER:
        let bytes = (skin.toNSObject(atIndex:2) as! NSNumber).uintValue
        asyncSocket.readData(toLength: bytes, withTimeout: asyncSocket.socketTimeout, tag: tag)
        if asyncSocket.userData as? NSString == SERVER {
            objc_sync_enter(asyncSocket.connectedSockets)
            for client in asyncSocket.connectedSockets {
                (client as? GCDAsyncSocket)?.readData(toLength: bytes, withTimeout: asyncSocket.socketTimeout, tag: tag)
            }
            objc_sync_exit(asyncSocket.connectedSockets)
        }
    case LUA_TSTRING:
        let separatorString = skin.toNSObject(atIndex:2) as! String
        let separator = separatorString.data(using: .utf8)!
        asyncSocket.readData(to: separator, withTimeout: asyncSocket.socketTimeout, tag: tag)
        if asyncSocket.userData as? NSString == SERVER {
            objc_sync_enter(asyncSocket.connectedSockets)
            for client in asyncSocket.connectedSockets {
                (client as? GCDAsyncSocket)?.readData(to: separator, withTimeout: asyncSocket.socketTimeout, tag: tag)
            }
            objc_sync_exit(asyncSocket.connectedSockets)
        }
    default:
        break
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:write(message[, tag, fn]) -> self
/// Method
/// Write data to the socket.
///
/// Parameters:
///  * `message` - A string containing data to be sent on the socket.
///  * `tag` - An optional integer to assist with labeling writes.
///  * `fn` - An optional single-use callback function to execute after writing data to the socket. The callback receives the tag parameter provided here.
///
/// Returns:
///  * The [`hs.socket`](#new) object.
///
/// Notes:
///  * If called on a listening socket with multiple connections, data is broadcast to all connected sockets.
///
private func socket_write(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER | LS_TINTEGER | LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)
    let message = skin.toNSObject(atIndex: 2, withOptions: .nsLuaStringAsDataOnly) as! Data
    let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1

    if lua_type(L, 3) == LUA_TFUNCTION {
        lua_pushvalue(L, 3)
        asyncSocket.writeCallbackRef = skin.luaRef(refTable)
    }
    if lua_type(L, 3) != LUA_TFUNCTION && lua_type(L, 4) == LUA_TFUNCTION {
        lua_pushvalue(L, 4)
        asyncSocket.writeCallbackRef = skin.luaRef(refTable)
    }

    if asyncSocket.userData as? NSString == SERVER {
        objc_sync_enter(asyncSocket.connectedSockets)
        for client in asyncSocket.connectedSockets {
            (client as? GCDAsyncSocket)?.write(message as Data, withTimeout: asyncSocket.socketTimeout, tag: tag)
        }
        objc_sync_exit(asyncSocket.connectedSockets)
    } else {
        asyncSocket.write(message as Data, withTimeout: asyncSocket.socketTimeout, tag: tag)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:setCallback([fn]) -> self
/// Method
/// Sets the read callback for the socket.
///
/// Parameters:
///  * `fn` - An optional callback function to process data read from the socket. `nil` or no argument clears the callback. The callback receives 2 parameters:
///    * `data` - The data read from the socket as a string.
///    * `tag` - The integer tag associated with the read call, which defaults to `-1`.
///
/// Returns:
///  * The [`hs.socket`](#new) object.
///
/// Notes:
///  * A callback must be set in order to read data from the socket.
///
private func socket_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)
    asyncSocket.readCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.readCallbackRef)

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        asyncSocket.readCallbackRef = skin.luaRef(refTable)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:setTimeout(timeout) -> self
/// Method
/// Sets the timeout for the socket operations.
///
/// Parameters:
///  * `timeout` - A number containing the timeout duration, in seconds.
///
/// Returns:
///  * The [`hs.socket`](#new) object.
///
/// Notes:
///  *  If the timeout value is negative, the operations will not use a timeout, which is the default.
///
private func socket_setTimeout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)
    asyncSocket.socketTimeout = lua_tonumber(L, 2)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket:startTLS([verify][, peerName]) -> self
/// Method
/// Secures the socket with TLS.
///
/// Parameters:
///  * `verify` - An optional boolean that, if `false`, allows TLS handshaking with servers with self-signed certificates and does not evaluate the chain of trust. Defaults to `true` and omitted if `peerName` is supplied
///  * `peerName` - An optional string containing the fully qualified domain name of the peer to validate against -- for example, `store.apple.com`. It should match the name in the X.509 certificate given by the remote party. See the important security note below.
///
/// Returns:
///  * The [`hs.socket`](#new) object.
///
/// Notes:
///  * The socket will disconnect immediately if TLS negotiation fails.
///  * **IMPORTANT SECURITY NOTE**: The default settings will check to make sure the remote party's certificate is signed by a trusted 3rd party certificate agency (e.g. verisign) and that the certificate is not expired.  However it will not verify the name on the certificate unless you give it a name to verify against via `peerName`.  The security implications of this are important to understand.  Imagine you are attempting to create a secure connection to MySecureServer.com, but your socket gets directed to MaliciousServer.com because of a hacked DNS server.  If you simply use the default settings, and MaliciousServer.com has a valid certificate, the default settings will not detect any problems since the certificate is valid.  To properly secure your connection in this particular scenario you should set `peerName` to "MySecureServer.com".
///
private func socket_startTLS(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)
    var tlsSettings: [String: NSObject]? = nil

    if lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 2) == 0 {
        tlsSettings = ["GCDAsyncSocketManuallyEvaluateTrust": NSNumber(value: true)]
    } else if lua_type(L, 2) == LUA_TSTRING {
        let peerName = skin.toNSObject(atIndex:2) as! String
        tlsSettings = ["kCFStreamSSLPeerName": peerName as NSString]
    }

    asyncSocket.startTLS(tlsSettings)

    lua_pushvalue(L, 1)
    return 1
}

private func get_socket_connections(_ asyncSocket: HSAsyncTcpSocket) -> Int {
    if asyncSocket.userData as? NSString == SERVER {
        return asyncSocket.connectedSockets.count
    } else {
        return asyncSocket.isConnected ? 1 : 0
    }
}

/// hs.socket:connected() -> bool
/// Method
/// Returns the connection status of the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if the socket is connected, otherwise `false`.
///
/// Notes:
///  * If the socket is bound for listening, this method returns `true` if there is at least one connection.
///
private func socket_connected(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)

    lua_pushboolean(L, get_socket_connections(asyncSocket) != 0 ? 1 : 0)
    return 1
}

/// hs.socket:connections() -> number
/// Method
/// Returns the number of connections to the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The number of connections to the socket.
///
/// Notes:
///  * This method returns at most 1 for default (non-listening) sockets.
///
private func socket_connections(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)

    lua_pushinteger(L, lua_Integer(get_socket_connections(asyncSocket)))
    return 1
}

/// hs.socket:info() -> table
/// Method
/// Returns information about the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the following keys:
///    * connectedAddress - `string` (`sockaddr` struct)
///    * connectedHost - `string`
///    * connectedPort - `number`
///    * connectedURL - `string`
///    * connections - `number`
///    * isConnected - `boolean`
///    * isDisconnected - `boolean`
///    * isIPv4 - `boolean`
///    * isIPv4Enabled - `boolean`
///    * isIPv4PreferredOverIPv6 - `boolean`
///    * isIPv6 - `boolean`
///    * isIPv6Enabled - `boolean`
///    * isSecure - `boolean`
///    * localAddress - `string` (`sockaddr` struct)
///    * localHost - `string`
///    * localPort - `number`
///    * timeout - `number`
///    * unixSocketPath - `string`
///    * userData - `string`
///
private func socket_info(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncSocket = getUserData(L, 1)

    let info: NSDictionary = [
        "connectedAddress": asyncSocket.connectedAddress ?? Data(),
        "connectedHost": asyncSocket.connectedHost ?? "",
        "connectedPort": NSNumber(value: asyncSocket.connectedPort),
        "connectedURL": asyncSocket.connectedUrl ?? "",
        "connections": NSNumber(value: get_socket_connections(asyncSocket)),
        "isConnected": NSNumber(value: asyncSocket.isConnected),
        "isDisconnected": NSNumber(value: asyncSocket.isDisconnected),
        "isIPv4": NSNumber(value: asyncSocket.isIPv4),
        "isIPv4Enabled": NSNumber(value: asyncSocket.isIPv4Enabled),
        "isIPv4PreferredOverIPv6": NSNumber(value: asyncSocket.isIPv4PreferredOverIPv6),
        "isIPv6": NSNumber(value: asyncSocket.isIPv6),
        "isIPv6Enabled": NSNumber(value: asyncSocket.isIPv6Enabled),
        "isSecure": NSNumber(value: asyncSocket.isSecure),
        "localAddress": asyncSocket.localAddress ?? Data(),
        "localHost": asyncSocket.localHost ?? "",
        "localPort": NSNumber(value: asyncSocket.localPort),
        "timeout": NSNumber(value: asyncSocket.socketTimeout),
        "unixSocketPath": asyncSocket.unixSocketPath ?? "",
        "userData": asyncSocket.userData ?? "",
    ]

    skin.pushNSObject(info)
    return 1
}

// MARK: - Library Registration Functions

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncSocket = getUserData(L, 1)

    let isServer = asyncSocket.userData as? NSString == SERVER
    let theHost = isServer ? asyncSocket.localHost : asyncSocket.connectedHost
    let thePort = isServer ? asyncSocket.localPort : asyncSocket.connectedPort
    let theAddress = asyncSocket.unixSocketPath ?? "\(theHost ?? ""):\(thePort)"
    let udTag = isServer ? "\(USERDATA_TAG)(server)" : USERDATA_TAG

    lua_pushstring(L, "\(udTag): \(theAddress) (\(lua_topointer(L, 1)!))")
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: AsyncSocketUserData.self)
    let asyncSocket: HSAsyncTcpSocket = Unmanaged.fromOpaque(userData.pointee.asyncSocket!).takeRetainedValue()
    userData.pointee.asyncSocket = nil

    let skin = LuaSkin.skin(with: L)
    asyncSocket.disconnect()
    asyncSocket.setDelegate(nil, delegateQueue: nil)
    asyncSocket.readCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.readCallbackRef)
    asyncSocket.writeCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.writeCallbackRef)
    asyncSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncSocket.connectCallbackRef)

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: socket_new),
    luaL_Reg(name: strdup("parseAddress"), func: socket_parseAddress),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for created objects when _new invoked
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("connect"), func: socket_connect),
    luaL_Reg(name: strdup("listen"), func: socket_listen),
    luaL_Reg(name: strdup("disconnect"), func: socket_disconnect),
    luaL_Reg(name: strdup("read"), func: socket_read),
    luaL_Reg(name: strdup("write"), func: socket_write),
    luaL_Reg(name: strdup("setCallback"), func: socket_setCallback),
    luaL_Reg(name: strdup("setTimeout"), func: socket_setTimeout),
    luaL_Reg(name: strdup("startTLS"), func: socket_startTLS),
    luaL_Reg(name: strdup("connected"), func: socket_connected),
    luaL_Reg(name: strdup("connections"), func: socket_connections),
    luaL_Reg(name: strdup("info"), func: socket_info),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libsocket")
public func luaopen_hs_libsocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &meta_gcLib)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)

    return 1
}
