import Cocoa
import LuaSkin
import CocoaAsyncSocket

// socket.h shared definitions are duplicated here since Swift can't import the C header directly.
// Each Swift file in the socket extension gets its own copy of the shared state.

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
private let USERDATA_TAG = "hs.socket.udp"

// Helper to extract the HSAsyncUdpSocket from userdata
private func getUserData(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSAsyncUdpSocket {
    let ud = lua_touserdata(L, idx)!.assumingMemoryBound(to: AsyncSocketUserData.self)
    return Unmanaged<HSAsyncUdpSocket>.fromOpaque(ud.pointee.asyncSocket!).takeUnretainedValue()
}

// MARK: - Lua Callbacks

private func udpConnectCallback(_ asyncUdpSocket: HSAsyncUdpSocket) {
    mainThreadDispatch {
        if asyncUdpSocket.connectCallbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: asyncUdpSocket.connectCallbackRef)
            asyncUdpSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.connectCallbackRef)
            skin.protectedCallAndError("hs.socket.udp:connect", nargs: 0, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

private func udpWriteCallback(_ asyncUdpSocket: HSAsyncUdpSocket, tag: Int) {
    mainThreadDispatch {
        if asyncUdpSocket.writeCallbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: asyncUdpSocket.writeCallbackRef)
            skin.pushNSObject(NSNumber(value: tag))
            asyncUdpSocket.writeCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.writeCallbackRef)
            skin.protectedCallAndError("hs.socket.udp:write callback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

private func udpReadCallback(_ asyncUdpSocket: HSAsyncUdpSocket, data: Data, address: Data) {
    mainThreadDispatch {
        if asyncUdpSocket.readCallbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: asyncUdpSocket.readCallbackRef)
            skin.pushNSObject(String(data: data, encoding: .utf8) as NSString?)
            skin.pushNSObject(address as NSData)
            skin.protectedCallAndError("hs.socket.udp:read callback", nargs: 2, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

// MARK: - UDP Socket Class

private class HSAsyncUdpSocket: GCDAsyncUdpSocket, GCDAsyncUdpSocketDelegate {
    var readCallbackRef: Int32 = LUA_NOREF
    var writeCallbackRef: Int32 = LUA_NOREF
    var connectCallbackRef: Int32 = LUA_NOREF
    var socketTimeout: TimeInterval = -1

    init(queue: DispatchQueue) {
        super.init(delegate: nil, delegateQueue: queue, socketQueue: nil)
    }

    func configure() {
        setDelegate(self, delegateQueue: delegateQueue())
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didConnectToAddress address: Data) {
        LuaSkin.skin(with: nil).logDebug("UDP socket connected")
        self.setUserData(DEFAULT)
        if self.connectCallbackRef != LUA_NOREF {
            udpConnectCallback(self)
        }
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotConnect error: Error?) {
        LuaSkin.skin(with: nil).logError("UDP socket did not connect: \(error?.localizedDescription ?? "")")
        mainThreadDispatch {
            self.connectCallbackRef = LuaSkin.skin(with: nil).luaUnref(refTable, ref: self.connectCallbackRef)
        }
    }

    func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        LuaSkin.skin(with: nil).logDebug("UDP socket closed: \(error?.localizedDescription ?? "")")
        sock.setUserData(nil)
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {
        LuaSkin.skin(with: nil).logDebug("Data written to UDP socket")
        if self.writeCallbackRef != LUA_NOREF {
            udpWriteCallback(self, tag: tag)
        }
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        LuaSkin.skin(with: nil).logError("Data not sent on UDP socket: \(error?.localizedDescription ?? "")")
        mainThreadDispatch {
            self.writeCallbackRef = LuaSkin.skin(with: nil).luaUnref(refTable, ref: self.writeCallbackRef)
        }
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        LuaSkin.skin(with: nil).logDebug("Data read from UDP socket")
        if self.readCallbackRef != LUA_NOREF {
            udpReadCallback(self, data: data, address: address)
        }
    }
}

// MARK: - Module Functions

/// hs.socket.udp.new([fn]) -> hs.socket.udp object
/// Constructor
/// Creates an unconnected asynchronous UDP socket object.
///
/// Parameters:
///  * `fn` - An optional [callback function](#setCallback) for reading data from the socket, settable here for convenience.
///
/// Returns:
///  * An [`hs.socket.udp`](#new) object.
///
private func socketudp_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let udpDelegateQueue = DispatchQueue(label: "udpDelegateQueue")
    let asyncUdpSocket = HSAsyncUdpSocket(queue: udpDelegateQueue)
    asyncUdpSocket.configure()

    if lua_type(L, 1) == LUA_TFUNCTION {
        lua_pushvalue(L, 1)
        asyncUdpSocket.readCallbackRef = skin.luaRef(refTable)
    }

    skin.requireModule("hs.socket")
    for field in ["udp", "timeout"] {
        lua_getfield(skin.l, -1, field)
    }
    asyncUdpSocket.socketTimeout = lua_tonumber(skin.l, -1)

    let userData = lua_newuserdata(L, MemoryLayout<AsyncSocketUserData>.size)!
        .assumingMemoryBound(to: AsyncSocketUserData.self)
    userData.pointee = AsyncSocketUserData()
    userData.pointee.asyncSocket = Unmanaged.passRetained(asyncUdpSocket).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.socket.udp:connect(host, port[, fn]) -> self or nil
/// Method
/// Connects an unconnected socket.
///
/// Parameters:
///  * `host` - A string containing the hostname or IP address.
///  * `port` - A port number [1-65535].
///  * `fn` - An optional single-use callback function to execute after establishing the connection. The callback receives no parameters.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
/// * By design, UDP is a connectionless protocol, and connecting is not needed.
/// * Choosing to connect to a specific host/port has the following effect:
///   * You will only be able to send data to the connected host/port;
///   * You will only be able to receive data from the connected host/port;
///   * You will receive ICMP messages that come from the connected host/port, such as "connection refused".
/// * The actual process of connecting a UDP socket does not result in any communication on the socket, it simply changes the internal state of the socket.
/// * You cannot bind a socket for listening after it has been connected.
/// * You can only connect a socket once.
///
private func socketudp_connect(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER | LS_TINTEGER, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    let theHost = skin.toNSObject(atIndex:2) as! String
    let thePort = (skin.toNSObject(atIndex:3) as! NSNumber).uint16Value

    if lua_type(L, 4) == LUA_TFUNCTION {
        lua_pushvalue(L, 4)
        asyncUdpSocket.connectCallbackRef = skin.luaRef(refTable)
    }

    do {
        try asyncUdpSocket.connect(toHost: theHost, onPort: thePort)
    } catch {
        asyncUdpSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.connectCallbackRef)
        LuaSkin.skin(with: nil).logError("Unable to connect: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:listen(port) -> self or nil
/// Method
/// Binds an unconnected socket to a port for listening.
///
/// Parameters:
///  * `port` - A port number [0-65535]. Ports [1-1023] are privileged. Port 0 allows the OS to select any available port.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
private func socketudp_listen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    let thePort = (skin.toNSObject(atIndex:2) as! NSNumber).uint16Value

    do {
        try asyncUdpSocket.bind(toPort: thePort)
    } catch {
        LuaSkin.skin(with: nil).logError("Unable to bind port: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    asyncUdpSocket.setUserData(SERVER)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:close() -> self
/// Method
/// Immediately closes the socket, freeing it for reuse. Any pending send operations are discarded.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
private func socketudp_close(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    asyncUdpSocket.close()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:pause() -> self
/// Method
/// Suspends reading of packets from the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * Call one of the receive methods to resume.
///
private func socketudp_pause(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    asyncUdpSocket.pauseReceiving()

    lua_pushvalue(L, 1)
    return 1
}

private func socketudp_receiveContinuous(_ L: UnsafeMutablePointer<lua_State>!, readContinuous: Bool) -> Bool {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    if lua_type(L, 2) == LUA_TFUNCTION {
        asyncUdpSocket.readCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.readCallbackRef)
        lua_pushvalue(L, 2)
        asyncUdpSocket.readCallbackRef = skin.luaRef(refTable)
    }

    if asyncUdpSocket.readCallbackRef == LUA_NOREF {
        LuaSkin.skin(with: nil).logError("No callback defined!")
        return false
    }

    do {
        if readContinuous {
            try asyncUdpSocket.beginReceiving()
        } else {
            try asyncUdpSocket.receiveOnce()
        }
    } catch {
        LuaSkin.skin(with: nil).logError("Unable to read from UDP socket: \(error.localizedDescription)")
        return false
    }

    return true
}

/// hs.socket.udp:receive([fn]) -> self or nil
/// Method
/// Reads packets from the socket as they arrive.
///
/// Parameters:
///  * `fn` - Optionally supply the [read callback](#setCallback) here.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Results are passed to the [callback function](#setCallback), which must be set to use this method.
///  * There are two modes of operation for receiving packets: one-at-a-time & continuous.
///  * In one-at-a-time mode, you call receiveOne every time you are ready process an incoming UDP packet.
///  * Receiving packets one-at-a-time may be better suited for implementing certain state machine code where your state machine may not always be ready to process incoming packets.
///  * In continuous mode, the callback is invoked immediately every time incoming udp packets are received.
///  * Receiving packets continuously is better suited to real-time streaming applications.
///  * You may switch back and forth between one-at-a-time mode and continuous mode.
///  * If the socket is currently in one-at-a-time mode, calling this method will switch it to continuous mode.
///
private func socketudp_receive(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if socketudp_receiveContinuous(L, readContinuous: true) {
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.socket.udp:receiveOne([fn]) -> self or nil
/// Method
/// Reads a single packet from the socket.
///
/// Parameters:
///  * `fn` - Optionally supply the [read callback](#setCallback) here.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Results are passed to the [callback function](#setCallback), which must be set to use this method.
///  * There are two modes of operation for receiving packets: one-at-a-time & continuous.
///  * In one-at-a-time mode, you call receiveOne every time you are ready process an incoming UDP packet.
///  * Receiving packets one-at-a-time may be better suited for implementing certain state machine code where your state machine may not always be ready to process incoming packets.
///  * In continuous mode, the callback is invoked immediately every time incoming udp packets are received.
///  * Receiving packets continuously is better suited to real-time streaming applications.
///  * You may switch back and forth between one-at-a-time mode and continuous mode.
///  * If the socket is currently in continuous mode, calling this method will switch it to one-at-a-time mode
///
private func socketudp_receiveOne(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if socketudp_receiveContinuous(L, readContinuous: false) {
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.socket.udp:send(message[, host, port][, tag, fn]) -> self
/// Method
/// Sends a packet to the destination address.
///
/// Parameters:
///  * `message` - A string containing data to be sent on the socket.
///  * `host` - A string containing the hostname or IP address.
///  * `port` - A port number [1-65535].
///  * `tag` - An optional integer to assist with labeling writes.
///  * `fn` - An optional single-use callback function to execute after sending the packet. The callback receives the tag parameter provided here.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * For non-connected sockets, the remote destination is specified for each packet.
///  * If the socket has been explicitly connected with [`connect`](#connect), only the message parameter and an optional tag and/or write callback can be supplied.
///  * Recall that connecting is optional for a UDP socket.
///  * For connected sockets, data can only be sent to the connected address.
///
private func socketudp_send(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TANY | LS_TOPTIONAL, LS_TANY | LS_TOPTIONAL, LS_TANY | LS_TOPTIONAL, LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    let sendData = skin.toNSObject(atIndex: 2, withOptions: .nsLuaStringAsDataOnly) as! Data

    if asyncUdpSocket.isConnected() {
        skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TNUMBER | LS_TINTEGER | LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
        let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1
        if lua_type(L, 3) == LUA_TFUNCTION {
            lua_pushvalue(L, 3)
            asyncUdpSocket.writeCallbackRef = skin.luaRef(refTable)
        }
        if lua_type(L, 3) != LUA_TFUNCTION && lua_type(L, 4) == LUA_TFUNCTION {
            lua_pushvalue(L, 4)
            asyncUdpSocket.writeCallbackRef = skin.luaRef(refTable)
        }

        asyncUdpSocket.send(sendData, withTimeout: asyncUdpSocket.socketTimeout, tag: tag)
    } else {
        skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TSTRING, LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER | LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
        let theHost = skin.toNSObject(atIndex:3) as! String
        let thePort = (skin.toNSObject(atIndex:4) as! NSNumber).uint16Value
        let tag: Int = lua_type(L, 5) == LUA_TNUMBER ? Int(lua_tointeger(L, 5)) : -1
        if lua_type(L, 5) == LUA_TFUNCTION {
            lua_pushvalue(L, 5)
            asyncUdpSocket.writeCallbackRef = skin.luaRef(refTable)
        }
        if lua_type(L, 5) != LUA_TFUNCTION && lua_type(L, 6) == LUA_TFUNCTION {
            lua_pushvalue(L, 6)
            asyncUdpSocket.writeCallbackRef = skin.luaRef(refTable)
        }

        asyncUdpSocket.send(sendData, toHost: theHost, port: thePort, withTimeout: asyncUdpSocket.socketTimeout, tag: tag)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:broadcast([flag]) -> self or nil
/// Method
/// Enables broadcasting on the underlying socket.
///
/// Parameters:
///  * `flag` - An optional boolean: `true` to enable broadcasting, `false` to disable it. Defaults to `true`.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * By default, the underlying socket in the OS will not allow you to send broadcast messages.
///  * In order to send broadcast messages, you need to enable this functionality in the socket.
///  * A broadcast is a UDP message to addresses like "192.168.255.255" or "255.255.255.255" that is delivered to every host on the network.
///  * The reason this is generally disabled by default (by the OS) is to prevent accidental broadcast messages from flooding the network.
///
private func socketudp_enableBroadcast(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    let enableFlag: Bool = !(lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 3) == 0)

    do {
        try asyncUdpSocket.enableBroadcast(enableFlag)
    } catch {
        LuaSkin.skin(with: nil).logError("Unable to enable broadcasting: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:reusePort([flag]) -> self or nil
/// Method
/// Enables port reuse on the socket.
///
/// Parameters:
///  * `flag` - An optional boolean: `true` to enable port reuse, `false` to disable it. Defaults to `true`.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * By default, only one socket can be bound to a given IP address & port at a time.
///  * To enable multiple processes to simultaneously bind to the same address & port, you need to enable this functionality in the socket.
///  * All processes that wish to use the address & port simultaneously must all enable reuse port on the socket bound to that port.
///  * Must be called before binding the socket.
///
private func socketudp_enableReusePort(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    let enableFlag: Bool = !(lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 3) == 0)

    do {
        try asyncUdpSocket.enableReusePort(enableFlag)
    } catch {
        LuaSkin.skin(with: nil).logError("Unable to enable port reuse: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:enableIPv(version[, flag]) -> self or nil
/// Method
/// Enables or disables IPv4 or IPv6 on the underlying socket. By default, both are enabled.
///
/// Parameters:
///  * `version` - A number containing the IP version (4 or 6) to enable or disable.
///  * `flag` - A boolean: `true` to enable the chosen IP version, `false` to disable it. Defaults to `true`.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Must be called before binding the socket. If you want to create an IPv6-only server, do something like:
///    * `hs.socket.udp.new(callback):enableIPv(4, false):listen(port):receive()`
///  * The convenience constructor [`hs.socket.server`](#server) will automatically bind the socket and requires closing and relistening to use this method.
///
private func socketudp_enableIPversion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    let ipVersion = UInt8(lua_tointeger(L, 2))
    let enableFlag: Bool = !(lua_type(L, 3) == LUA_TBOOLEAN && lua_toboolean(L, 3) == 0)

    if ipVersion == 4 {
        asyncUdpSocket.setIPv4Enabled(enableFlag)
    } else if ipVersion == 6 {
        asyncUdpSocket.setIPv6Enabled(enableFlag)
    } else {
        LuaSkin.skin(with: nil).logError("Invalid IP version: \(ipVersion)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:preferIPv([version]) -> self
/// Method
/// Sets the preferred IP version: IPv4, IPv6, or neutral (first to resolve).
///
/// Parameters:
///  * `version` - An optional number containing the IP version to prefer. Anything but 4 or 6 else sets the default neutral behavior.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * If a DNS lookup returns only IPv4 results, the socket will automatically use IPv4.
///  * If a DNS lookup returns only IPv6 results, the socket will automatically use IPv6.
///  * If a DNS lookup returns both IPv4 and IPv6 results, then the protocol used depends on the configured preference.
///
private func socketudp_preferIPversion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    if lua_type(L, 2) == LUA_TNUMBER && lua_tointeger(L, 2) == 4 {
        asyncUdpSocket.setPreferIPv4()
    } else if lua_type(L, 2) == LUA_TNUMBER && lua_tointeger(L, 2) == 6 {
        asyncUdpSocket.setPreferIPv6()
    } else {
        asyncUdpSocket.setIPVersionNeutral()
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:setBufferSize(size[, version]) -> self
/// Method
/// Sets the maximum size of the buffer that will be allocated for receive operations.
///
/// Parameters:
///  * `size` - An number containing the receive buffer size in bytes.
///  * `version` - An optional number containing the IP version for which to set the buffer size. Anything but 4 or 6 else sets the same size for both.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * The default maximum size is 9216 bytes.
///  * The theoretical maximum size of any IPv4 UDP packet is `UINT16_MAX = 65535`.
///  * The theoretical maximum size of any IPv6 UDP packet is `UINT32_MAX = 4294967295`.
///  * Since the OS notifies us of the size of each received UDP packet, the actual allocated buffer size for each packet is exact.
///  * In practice the size of UDP packets is generally much smaller than the max. Most protocols will send and receive packets of only a few bytes, or will set a limit on the size of packets to prevent fragmentation in the IP layer.
///  * If you set the buffer size too small, the sockets API in the OS will silently discard any extra data.
///
private func socketudp_setReceiveBufferSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    let bufferSize = UInt(lua_tointeger(L, 2))
    let ipv4BufferSize = bufferSize > UInt(UInt16.max) ? UInt16.max : UInt16(bufferSize)
    let ipv6BufferSize = bufferSize > UInt(UInt32.max) ? UInt32.max : UInt32(bufferSize)

    if lua_type(L, 3) == LUA_TNUMBER {
        if lua_tointeger(L, 3) == 4 {
            asyncUdpSocket.setMaxReceiveIPv4BufferSize(ipv4BufferSize)
        } else if lua_tointeger(L, 3) == 6 {
            asyncUdpSocket.setMaxReceiveIPv6BufferSize(ipv6BufferSize)
        }
    } else {
        asyncUdpSocket.setMaxReceiveIPv4BufferSize(ipv4BufferSize)
        asyncUdpSocket.setMaxReceiveIPv6BufferSize(ipv6BufferSize)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:setCallback([fn]) -> self
/// Method
/// Sets the read callback for the socket.
///
/// Parameters:
///  * `fn` - An optional callback function to process data read from the socket. `nil` or no argument clears the callback. The callback receives 2 parameters:
///    * `data` - The data read from the socket as a string.
///    * `sockaddr` - The sending address as a binary socket address structure. See [`parseAddress`](#parseAddress).
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * A callback must be set in order to read data from the socket.
///
private func socketudp_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    asyncUdpSocket.readCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.readCallbackRef)

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        asyncUdpSocket.readCallbackRef = skin.luaRef(refTable)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:setTimeout(timeout) -> self
/// Method
/// Sets the timeout for the socket operations.
///
/// Parameters:
///  * `timeout` - A number containing the timeout duration, in seconds.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  *  If the timeout value is negative, the operations will not use a timeout, which is the default.
///
private func socketudp_setTimeout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)
    asyncUdpSocket.socketTimeout = lua_tonumber(L, 2)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:connected() -> bool
/// Method
/// Returns the connection status of the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if connected, otherwise `false`.
///
/// Notes:
///  * UDP sockets are typically meant to be connectionless.
///  * This method will only return `true` if the [`hs.socket.udp:connect`](#connect) method has been explicitly called.
///
private func socketudp_connected(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    lua_pushboolean(L, asyncUdpSocket.isConnected() ? 1 : 0)
    return 1
}

/// hs.socket.udp:closed() -> bool
/// Method
/// Returns the closed status of the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if the socket is closed, otherwise `false`.
///
/// Notes:
///  * UDP sockets are typically meant to be connectionless.
///  * Sending a packet anywhere, regardless of whether or not the destination receives it, opens the socket until it is explicitly closed.
///  * An active listening socket will not be closed, but will not be 'connected' unless the [`hs.socket.udp:connect`](#connect) method has been called.
///
private func socketudp_closed(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    lua_pushboolean(L, asyncUdpSocket.isClosed() ? 1 : 0)
    return 1
}

/// hs.socket.udp:info() -> table
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
///    * isClosed - `boolean`
///    * isConnected - `boolean`
///    * isIPv4 - `boolean`
///    * isIPv4Enabled - `boolean`
///    * isIPv4Preferred - `boolean`
///    * isIPv6 - `boolean`
///    * isIPv6Enabled - `boolean`
///    * isIPv6Preferred - `boolean`
///    * isIPVersionNeutral - `boolean`
///    * localAddress - `string` (`sockaddr` struct)
///    * localAddress_IPv4 - `string` (`sockaddr` struct)
///    * localAddress_IPv6 - `string` (`sockaddr` struct)
///    * localHost - `string`
///    * localHost_IPv4 - `string`
///    * localHost_IPv6 - `string`
///    * localPort - `number`
///    * localPort_IPv4 - `number`
///    * localPort_IPv6 - `number`
///    * maxReceiveIPv4BufferSize - `number`
///    * maxReceiveIPv6BufferSize - `number`
///    * timeout - `number`
///    * userData - `string`
///
private func socketudp_info(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let asyncUdpSocket = getUserData(L, 1)

    let info: NSDictionary = [
        "connectedAddress": asyncUdpSocket.connectedAddress() ?? Data(),
        "connectedHost": asyncUdpSocket.connectedHost() ?? "",
        "connectedPort": NSNumber(value: asyncUdpSocket.connectedPort()),
        "isClosed": NSNumber(value: asyncUdpSocket.isClosed()),
        "isConnected": NSNumber(value: asyncUdpSocket.isConnected()),
        "isIPv4": NSNumber(value: asyncUdpSocket.isIPv4()),
        "isIPv4Enabled": NSNumber(value: asyncUdpSocket.isIPv4Enabled()),
        "isIPv4Preferred": NSNumber(value: asyncUdpSocket.isIPv4Preferred()),
        "isIPv6": NSNumber(value: asyncUdpSocket.isIPv6()),
        "isIPv6Enabled": NSNumber(value: asyncUdpSocket.isIPv6Enabled()),
        "isIPv6Preferred": NSNumber(value: asyncUdpSocket.isIPv6Preferred()),
        "isIPVersionNeutral": NSNumber(value: asyncUdpSocket.isIPVersionNeutral()),
        "localAddress": asyncUdpSocket.localAddress() ?? Data(),
        "localAddress_IPv4": asyncUdpSocket.localAddress_IPv4() ?? Data(),
        "localAddress_IPv6": asyncUdpSocket.localAddress_IPv6() ?? Data(),
        "localHost": asyncUdpSocket.localHost() ?? "",
        "localHost_IPv4": asyncUdpSocket.localHost_IPv4() ?? "",
        "localHost_IPv6": asyncUdpSocket.localHost_IPv6() ?? "",
        "localPort": NSNumber(value: asyncUdpSocket.localPort()),
        "localPort_IPv4": NSNumber(value: asyncUdpSocket.localPort_IPv4()),
        "localPort_IPv6": NSNumber(value: asyncUdpSocket.localPort_IPv6()),
        "maxReceiveIPv4BufferSize": NSNumber(value: asyncUdpSocket.maxReceiveIPv4BufferSize()),
        "maxReceiveIPv6BufferSize": NSNumber(value: asyncUdpSocket.maxReceiveIPv6BufferSize()),
        "timeout": NSNumber(value: asyncUdpSocket.socketTimeout),
        "userData": asyncUdpSocket.userData() ?? "",
    ]

    skin.pushNSObject(info)
    return 1
}

// MARK: - Library Registration Functions

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)

    let isServer = asyncUdpSocket.userData() as? NSString == SERVER
    let theHost = isServer ? asyncUdpSocket.localHost() : asyncUdpSocket.connectedHost()
    let thePort = isServer ? asyncUdpSocket.localPort() : asyncUdpSocket.connectedPort()

    lua_pushstring(L, "\(USERDATA_TAG): \(theHost ?? ""):\(thePort) (\(lua_topointer(L, 1)!))")
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: AsyncSocketUserData.self)
    let asyncUdpSocket: HSAsyncUdpSocket = Unmanaged.fromOpaque(userData.pointee.asyncSocket!).takeRetainedValue()
    userData.pointee.asyncSocket = nil

    let skin = LuaSkin.skin(with: L)
    asyncUdpSocket.close()
    asyncUdpSocket.setDelegate(nil, delegateQueue: nil)
    asyncUdpSocket.readCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.readCallbackRef)
    asyncUdpSocket.writeCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.writeCallbackRef)
    asyncUdpSocket.connectCallbackRef = skin.luaUnref(refTable, ref: asyncUdpSocket.connectCallbackRef)

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: socketudp_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for created objects when _new invoked
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("connect"), func: socketudp_connect),
    luaL_Reg(name: strdup("listen"), func: socketudp_listen),
    luaL_Reg(name: strdup("close"), func: socketudp_close),
    luaL_Reg(name: strdup("pause"), func: socketudp_pause),
    luaL_Reg(name: strdup("receive"), func: socketudp_receive),
    luaL_Reg(name: strdup("receiveOne"), func: socketudp_receiveOne),
    luaL_Reg(name: strdup("send"), func: socketudp_send),
    luaL_Reg(name: strdup("broadcast"), func: socketudp_enableBroadcast),
    luaL_Reg(name: strdup("reusePort"), func: socketudp_enableReusePort),
    luaL_Reg(name: strdup("enableIPv"), func: socketudp_enableIPversion),
    luaL_Reg(name: strdup("preferIPv"), func: socketudp_preferIPversion),
    luaL_Reg(name: strdup("setBufferSize"), func: socketudp_setReceiveBufferSize),
    luaL_Reg(name: strdup("setCallback"), func: socketudp_setCallback),
    luaL_Reg(name: strdup("setTimeout"), func: socketudp_setTimeout),
    luaL_Reg(name: strdup("connected"), func: socketudp_connected),
    luaL_Reg(name: strdup("closed"), func: socketudp_closed),
    luaL_Reg(name: strdup("info"), func: socketudp_info),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libsocketudp")
public func luaopen_hs_libsocketudp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &meta_gcLib)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)

    return 1
}
