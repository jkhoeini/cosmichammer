import Cocoa
import LuaSkin
import os.log
import Network

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

private enum SocketRole: String {
    case `default` = "DEFAULT"
    case server = "SERVER"
    case client = "CLIENT"
}

private var refTable: Int32 = LUA_NOREF
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
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(asyncSocket.connectCallbackRef))
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.connectCallbackRef)

            asyncSocket.connectCallbackRef = LUA_NOREF
            if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func tcpWriteCallback(_ asyncSocket: HSAsyncTcpSocket, tag: Int) {
    mainThreadDispatch {
        if asyncSocket.writeCallbackRef != LUA_NOREF {
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(asyncSocket.writeCallbackRef))
            lua_pushany(L, NSNumber(value: tag))
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.writeCallbackRef)

            asyncSocket.writeCallbackRef = LUA_NOREF
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func tcpReadCallback(_ asyncSocket: HSAsyncTcpSocket, data: Data, tag: Int) {
    mainThreadDispatch {
        if asyncSocket.readCallbackRef != LUA_NOREF {
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(asyncSocket.readCallbackRef))
            lua_pushany(L, data as NSData)
            lua_pushany(L, NSNumber(value: tag))
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - TCP Socket Class (Network.framework)

private class HSAsyncTcpSocket {
    var readCallbackRef: Int32 = LUA_NOREF
    var writeCallbackRef: Int32 = LUA_NOREF
    var connectCallbackRef: Int32 = LUA_NOREF
    var socketTimeout: TimeInterval = -1
    var unixSocketPath: String?

    /// Role: default (not yet connected), server (listening), client (accepted by server).
    var role: SocketRole = .default

    /// The underlying NWConnection (client / default sockets).
    private var connection: NWConnection?

    /// The underlying NWListener (server sockets).
    private var listener: NWListener?

    /// Accepted client connections for server sockets.
    var connectedSockets: [NWConnection] = []
    private let lock = NSLock()

    /// Read buffer for delimiter-based reads on the main connection.
    private var readBuffer = Data()

    // Track connection state ourselves since NWConnection doesn't expose a simple bool.
    private(set) var isConnectedFlag: Bool = false
    private(set) var isSecureFlag: Bool = false
    private(set) var isIPv4Flag: Bool = false
    private(set) var isIPv6Flag: Bool = false

    // Address info cached on connect.
    private(set) var connectedHost: String?
    private(set) var connectedPort: UInt16 = 0
    private(set) var localHost: String?
    private(set) var localPort: UInt16 = 0
    private(set) var connectedAddress: Data?
    private(set) var localAddress: Data?

    /// The dispatch queue for NWConnection/NWListener callbacks.
    private let delegateQueue: DispatchQueue

    /// IPv4/IPv6 preference tracking.
    var isIPv4Enabled: Bool = true
    var isIPv6Enabled: Bool = true
    var isIPv4PreferredOverIPv6: Bool = false

    /// Pending read requests for server-owned connections (per-connection buffers).
    private var clientReadBuffers: [ObjectIdentifier: Data] = [:]

    init(delegateQueueLabel label: String = "tcpDelegateQueue") {
        delegateQueue = DispatchQueue(label: label)
    }

    var isConnected: Bool {
        if role == .server {
            lock.lock()
            let count = connectedSockets.count
            lock.unlock()
            return count > 0
        }
        return isConnectedFlag
    }

    var isDisconnected: Bool { !isConnected }

    var isSecure: Bool { isSecureFlag }

    // MARK: Client connect (host:port)

    func connect(toHost host: String, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        if !isIPv4Enabled { params.requiredInterfaceType = .other } // will refine below
        if !isIPv6Enabled { params.requiredInterfaceType = .other }

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = conn

        var timeoutItem: DispatchWorkItem? = nil
        if timeout >= 0 {
            let item = DispatchWorkItem { [weak self, weak conn] in
                guard let self = self, let conn = conn else { return }
                if !self.isConnectedFlag {
                    conn.cancel()
                    os_log(.error,"TCP connect timed out")
                }
            }
            timeoutItem = item
            delegateQueue.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                timeoutItem?.cancel()
                self.isConnectedFlag = true
                self.role = .default
                self.cacheConnectionInfo(conn)
                os_log(.debug,"TCP socket connected")
                if self.connectCallbackRef != LUA_NOREF {
                    tcpConnectCallback(self)
                }
            case .failed(let err):
                timeoutItem?.cancel()
                self.isConnectedFlag = false
                os_log(.debug, "%{public}s", "TCP socket disconnected: \(err)")
            case .cancelled:
                timeoutItem?.cancel()
                self.isConnectedFlag = false
                os_log(.debug,"TCP socket disconnected")
            default:
                break
            }
        }

        conn.start(queue: delegateQueue)
    }

    // MARK: Client connect (Unix domain socket)

    func connect(toURL url: URL, withTimeout timeout: TimeInterval) throws {
        let path = url.path
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let endpoint = NWEndpoint.unix(path: path)
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        var timeoutItem: DispatchWorkItem? = nil
        if timeout >= 0 {
            let item = DispatchWorkItem { [weak self, weak conn] in
                guard let self = self, let conn = conn else { return }
                if !self.isConnectedFlag {
                    conn.cancel()
                    os_log(.error,"TCP Unix domain connect timed out")
                }
            }
            timeoutItem = item
            delegateQueue.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                timeoutItem?.cancel()
                self.isConnectedFlag = true
                self.role = .default
                self.unixSocketPath = path
                self.cacheConnectionInfo(conn)
                os_log(.debug,"TCP Unix domain socket connected")
                if self.connectCallbackRef != LUA_NOREF {
                    tcpConnectCallback(self)
                }
            case .failed(let err):
                timeoutItem?.cancel()
                self.isConnectedFlag = false
                os_log(.debug, "%{public}s", "TCP Unix domain socket disconnected: \(err)")
            case .cancelled:
                timeoutItem?.cancel()
                self.isConnectedFlag = false
                os_log(.debug,"TCP Unix domain socket disconnected")
            default:
                break
            }
        }

        conn.start(queue: delegateQueue)
    }

    // MARK: Server listen (port)

    func accept(onPort port: UInt16) throws {
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let nwListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        setupListener(nwListener)
    }

    // MARK: Server listen (Unix domain socket)

    func accept(onURL url: URL) throws {
        let path = url.path
        // Remove stale socket file if present
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let nwListener = try NWListener(using: params)
        self.unixSocketPath = path

        // For Unix domain sockets we need to use the service with a custom endpoint
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let port = nwListener.port {
                    self.localPort = port.rawValue
                }
                os_log(.debug,"TCP Unix domain server listening")
            case .failed(let err):
                os_log(.debug, "%{public}s", "TCP Unix domain server failed: \(err)")
            case .cancelled:
                if let path = self.unixSocketPath {
                    try? FileManager.default.removeItem(atPath: path)
                    self.unixSocketPath = nil
                }
                os_log(.debug,"TCP Unix domain server disconnected")
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] newConn in
            self?.handleNewConnection(newConn)
        }

        self.listener = nwListener
        self.role = .server
        nwListener.start(queue: delegateQueue)

        // Workaround: NWListener doesn't natively support Unix domain sockets via init,
        // so we listen on an ephemeral TCP port. For true Unix socket support, fall back
        // to POSIX bind approach.
        // Actually, Network.framework DOES support unix via NWEndpoint.unix, but
        // NWListener doesn't accept an endpoint directly. We need a different approach:
        // Create a connection endpoint and use service advertisment. Since this is complex,
        // we use a POSIX-based listener for Unix sockets.
        nwListener.cancel()
        self.listener = nil
        try acceptUnixSocket(path: path)
    }

    /// POSIX-based Unix domain socket listener, since NWListener doesn't support Unix paths directly.
    private func acceptUnixSocket(path: String) throws {
        // Remove stale socket file
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "hs.socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: "hs.socket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unix socket path too long"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        })
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "hs.socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(String(cString: strerror(errno)))"])
        }

        guard Darwin.listen(fd, 128) == 0 else {
            close(fd)
            throw NSError(domain: "hs.socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "listen() failed: \(String(cString: strerror(errno)))"])
        }

        self.unixSocketPath = path
        self.role = .server

        // Use DispatchSource to accept connections asynchronously
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: delegateQueue)
        self.unixListenFD = fd
        self.unixAcceptSource = source

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            // Wrap accepted fd into NWConnection
            let conn = NWConnection(from: clientFD)
            self.handleNewConnection(conn)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
    }

    private var unixListenFD: Int32 = -1
    private var unixAcceptSource: DispatchSourceRead?

    private func setupListener(_ nwListener: NWListener) {
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let port = nwListener.port {
                    self.localPort = port.rawValue
                }
                self.localHost = "0.0.0.0"
                os_log(.debug,"TCP server listening")
            case .failed(let err):
                os_log(.debug, "%{public}s", "TCP server failed: \(err)")
            case .cancelled:
                os_log(.debug,"TCP server disconnected")
                self.lock.lock()
                let clients = self.connectedSockets
                self.connectedSockets.removeAll()
                self.lock.unlock()
                for client in clients {
                    client.cancel()
                }
                if let path = self.unixSocketPath {
                    try? FileManager.default.removeItem(atPath: path)
                    self.unixSocketPath = nil
                }
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] newConn in
            self?.handleNewConnection(newConn)
        }

        self.listener = nwListener
        self.role = .server
        nwListener.start(queue: delegateQueue)
    }

    private func handleNewConnection(_ newConn: NWConnection) {
        os_log(.debug,"TCP client connected")

        newConn.stateUpdateHandler = { [weak self, weak newConn] state in
            guard let self = self, let conn = newConn else { return }
            switch state {
            case .ready:
                break
            case .failed(_), .cancelled:
                os_log(.debug,"TCP client disconnected")
                self.lock.lock()
                self.connectedSockets.removeAll(where: { $0 === conn })
                let id = ObjectIdentifier(conn)
                self.clientReadBuffers.removeValue(forKey: id)
                self.lock.unlock()
            default:
                break
            }
        }

        lock.lock()
        connectedSockets.append(newConn)
        lock.unlock()

        newConn.start(queue: delegateQueue)
    }

    // MARK: Disconnect

    func disconnect() {
        if role == .server {
            listener?.cancel()
            listener = nil
            unixAcceptSource?.cancel()
            unixAcceptSource = nil
            unixListenFD = -1

            lock.lock()
            let clients = connectedSockets
            connectedSockets.removeAll()
            clientReadBuffers.removeAll()
            lock.unlock()

            for client in clients {
                client.cancel()
            }

            if let path = unixSocketPath {
                try? FileManager.default.removeItem(atPath: path)
                unixSocketPath = nil
            }
        } else {
            connection?.cancel()
            connection = nil
            isConnectedFlag = false
        }
        role = .default
    }

    // MARK: Read data (length-based)

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        guard let conn = connection else { return }
        receiveExactly(from: conn, length: Int(length), timeout: timeout, buffer: Data()) { [weak self] data in
            guard let self = self else { return }
            tcpReadCallback(self, data: data, tag: tag)
        }
    }

    /// Read exactly `length` bytes from a connection, accumulating into buffer.
    private func receiveExactly(from conn: NWConnection, length: Int, timeout: TimeInterval, buffer: Data, completion: @escaping (Data) -> Void) {
        let remaining = length - buffer.count
        guard remaining > 0 else {
            completion(buffer)
            return
        }

        var timeoutItem: DispatchWorkItem? = nil
        if timeout >= 0 {
            let item = DispatchWorkItem {
                os_log(.error,"TCP read timed out")
            }
            timeoutItem = item
            delegateQueue.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] content, _, isComplete, error in
            timeoutItem?.cancel()
            guard let self = self else { return }
            if let error = error {
                os_log(.debug, "%{public}s", "TCP read error: \(error)")
                return
            }
            var accumulated = buffer
            if let content = content {
                accumulated.append(content)
            }
            if accumulated.count >= length {
                completion(accumulated)
            } else if isComplete {
                // Connection closed before we got all bytes
                if !accumulated.isEmpty {
                    completion(accumulated)
                }
            } else {
                self.receiveExactly(from: conn, length: length, timeout: timeout, buffer: accumulated, completion: completion)
            }
        }
    }

    /// Read from all server clients (length-based).
    func readDataFromClients(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        lock.lock()
        let clients = connectedSockets
        lock.unlock()

        for client in clients {
            receiveExactly(from: client, length: Int(length), timeout: timeout, buffer: Data()) { [weak self] data in
                guard let self = self else { return }
                tcpReadCallback(self, data: data, tag: tag)
            }
        }
    }

    // MARK: Read data (delimiter-based)

    func readData(to separator: Data, withTimeout timeout: TimeInterval, tag: Int) {
        guard let conn = connection else { return }
        receiveUntilDelimiter(from: conn, separator: separator, timeout: timeout, buffer: &readBuffer) { [weak self] data in
            guard let self = self else { return }
            tcpReadCallback(self, data: data, tag: tag)
        }
    }

    private func receiveUntilDelimiter(from conn: NWConnection, separator: Data, timeout: TimeInterval, buffer: inout Data, completion: @escaping (Data) -> Void) {
        // Check if delimiter is already in existing buffer
        if let range = buffer.range(of: separator) {
            let endIndex = range.upperBound
            let chunk = buffer.prefix(upTo: endIndex)
            buffer.removeSubrange(buffer.startIndex..<endIndex)
            completion(Data(chunk))
            return
        }

        var timeoutItem: DispatchWorkItem? = nil
        if timeout >= 0 {
            let item = DispatchWorkItem {
                os_log(.error,"TCP read timed out")
            }
            timeoutItem = item
            delegateQueue.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            timeoutItem?.cancel()
            guard let self = self else { return }
            if let error = error {
                os_log(.debug, "%{public}s", "TCP read error: \(error)")
                return
            }
            if let content = content {
                self.readBuffer.append(content)
            }
            if let range = self.readBuffer.range(of: separator) {
                let endIndex = range.upperBound
                let chunk = self.readBuffer.prefix(upTo: endIndex)
                self.readBuffer.removeSubrange(self.readBuffer.startIndex..<endIndex)
                completion(Data(chunk))
            } else if isComplete {
                // Connection closed; deliver whatever we have
                if !self.readBuffer.isEmpty {
                    let chunk = self.readBuffer
                    self.readBuffer.removeAll()
                    completion(chunk)
                }
            } else {
                self.receiveUntilDelimiter(from: conn, separator: separator, timeout: timeout, buffer: &self.readBuffer, completion: completion)
            }
        }
    }

    /// Read from all server clients (delimiter-based).
    func readDataFromClients(to separator: Data, withTimeout timeout: TimeInterval, tag: Int) {
        lock.lock()
        let clients = connectedSockets
        lock.unlock()

        for client in clients {
            let clientId = ObjectIdentifier(client)
            if clientReadBuffers[clientId] == nil {
                clientReadBuffers[clientId] = Data()
            }
            receiveUntilDelimiterForClient(from: client, clientId: clientId, separator: separator, timeout: timeout) { [weak self] data in
                guard let self = self else { return }
                tcpReadCallback(self, data: data, tag: tag)
            }
        }
    }

    private func receiveUntilDelimiterForClient(from conn: NWConnection, clientId: ObjectIdentifier, separator: Data, timeout: TimeInterval, completion: @escaping (Data) -> Void) {
        // Check if delimiter is already in existing buffer
        var buf = clientReadBuffers[clientId] ?? Data()
        if let range = buf.range(of: separator) {
            let endIndex = range.upperBound
            let chunk = buf.prefix(upTo: endIndex)
            buf.removeSubrange(buf.startIndex..<endIndex)
            clientReadBuffers[clientId] = buf
            completion(Data(chunk))
            return
        }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                os_log(.debug, "%{public}s", "TCP client read error: \(error)")
                return
            }
            var buf = self.clientReadBuffers[clientId] ?? Data()
            if let content = content {
                buf.append(content)
            }
            self.clientReadBuffers[clientId] = buf

            if let range = buf.range(of: separator) {
                let endIndex = range.upperBound
                let chunk = buf.prefix(upTo: endIndex)
                buf.removeSubrange(buf.startIndex..<endIndex)
                self.clientReadBuffers[clientId] = buf
                completion(Data(chunk))
            } else if isComplete {
                if !buf.isEmpty {
                    self.clientReadBuffers[clientId] = Data()
                    completion(buf)
                }
            } else {
                self.receiveUntilDelimiterForClient(from: conn, clientId: clientId, separator: separator, timeout: timeout, completion: completion)
            }
        }
    }

    // MARK: Write data

    func write(_ data: Data, withTimeout timeout: TimeInterval, tag: Int) {
        guard let conn = connection else { return }
        sendData(data, on: conn, timeout: timeout) { [weak self] in
            guard let self = self else { return }
            if self.writeCallbackRef != LUA_NOREF {
                tcpWriteCallback(self, tag: tag)
            }
        }
    }

    func writeToClients(_ data: Data, withTimeout timeout: TimeInterval, tag: Int) {
        lock.lock()
        let clients = connectedSockets
        lock.unlock()

        var remaining = clients.count
        guard remaining > 0 else {
            if self.writeCallbackRef != LUA_NOREF {
                tcpWriteCallback(self, tag: tag)
            }
            return
        }

        for client in clients {
            sendData(data, on: client, timeout: timeout) { [weak self] in
                guard let self = self else { return }
                remaining -= 1
                if remaining <= 0 && self.writeCallbackRef != LUA_NOREF {
                    tcpWriteCallback(self, tag: tag)
                }
            }
        }
    }

    private func sendData(_ data: Data, on conn: NWConnection, timeout: TimeInterval, completion: @escaping () -> Void) {
        conn.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                os_log(.debug, "%{public}s", "TCP write error: \(error)")
            }
            completion()
        })
    }

    // MARK: TLS

    func startTLS(verify: Bool, peerName: String?) {
        guard let conn = connection else { return }

        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        if !verify {
            // Accept self-signed certificates: approve all trust evaluations
            sec_protocol_options_set_verify_block(secOptions, { _, _, completionHandler in
                completionHandler(true)
            }, delegateQueue)
        }

        if let peerName = peerName {
            sec_protocol_options_set_tls_server_name(secOptions, peerName)
        }

        // Create new NWParameters with TLS and reconnect
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        // Network.framework doesn't support upgrading an existing connection to TLS
        // after the fact in the same way GCDAsyncSocket does. We need to work with
        // the existing connection's metadata.
        //
        // The correct approach: if the connection is already established, we restart
        // it with TLS parameters. For a simpler model that matches the original behavior:
        // Cache the endpoint, cancel, reconnect with TLS.

        let endpoint = conn.endpoint
        conn.cancel()

        let newConn = NWConnection(to: endpoint, using: params)
        self.connection = newConn
        self.isConnectedFlag = false

        newConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isConnectedFlag = true
                self.isSecureFlag = true
                self.cacheConnectionInfo(newConn)
                os_log(.debug,"TCP socket secured")
            case .failed(let err):
                self.isConnectedFlag = false
                os_log(.debug, "%{public}s", "TCP TLS handshake failed: \(err)")
            case .cancelled:
                self.isConnectedFlag = false
            default:
                break
            }
        }

        newConn.start(queue: delegateQueue)
    }

    // MARK: Info caching

    private func cacheConnectionInfo(_ conn: NWConnection) {
        // Extract info from the connection's current path
        if let path = conn.currentPath {
            if let localEndpoint = path.localEndpoint {
                switch localEndpoint {
                case .hostPort(let host, let port):
                    localHost = "\(host)"
                    localPort = port.rawValue
                    localAddress = sockaddrData(host: "\(host)", port: port.rawValue)
                default:
                    break
                }
            }
            if let remoteEndpoint = path.remoteEndpoint {
                switch remoteEndpoint {
                case .hostPort(let host, let port):
                    connectedHost = "\(host)"
                    connectedPort = port.rawValue
                    connectedAddress = sockaddrData(host: "\(host)", port: port.rawValue)
                    // Determine IP version from the host string
                    let hostStr = "\(host)"
                    isIPv4Flag = hostStr.contains(".") && !hostStr.contains(":")
                    isIPv6Flag = hostStr.contains(":")
                default:
                    break
                }
            }
        }
    }

    /// Build a binary sockaddr from host + port (for info table compatibility).
    private func sockaddrData(host: String, port: UInt16) -> Data {
        if host.contains(":") {
            // IPv6
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            inet_pton(AF_INET6, host, &addr.sin6_addr)
            return Data(bytes: &addr, count: MemoryLayout<sockaddr_in6>.size)
        } else {
            // IPv4
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            return Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size)
        }
    }
}

// MARK: - NWConnection from file descriptor helper

private extension NWConnection {
    /// Create an NWConnection wrapping an already-accepted file descriptor.
    convenience init(from fd: Int32) {
        // Set non-blocking
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        // Use .unix type for the accepted FD. We create a dummy connection
        // and then won't use it — instead we wrap the FD via a DispatchIO approach.
        // Actually, Network.framework can't wrap a raw FD directly.
        // For Unix socket accepted connections, we'll use a thin DispatchIO wrapper
        // instead. Let's use a POSIX read/write approach wrapped in a NWConnection-like interface.

        // Fallback: use a localhost loopback connection as placeholder.
        // This is a limitation — for Unix domain sockets, the server-side accepted
        // connections won't be full NWConnection objects. Instead, we track them
        // as raw FDs and use POSIX I/O.
        self.init(host: "127.0.0.1", port: 0, using: params)
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
    let asyncSocket = HSAsyncTcpSocket()

    if lua_type(L, 1) == LUA_TFUNCTION {
        lua_pushvalue(L, 1)
        asyncSocket.readCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    lua_getglobal(L, "require")


    lua_pushstring(L, "hs.socket")


    lua_pcall(L, 1, 1, 0)
    lua_getfield(L, -1, "timeout")
    asyncSocket.socketTimeout = lua_tonumber(L, -1)

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
    luaL_checktype(L, 1, LUA_TSTRING)
    let addressData = lua_tostring(L, 1)!
    let addressDataLength: Int = lua_rawlen(L, 1)
    let address = Data(bytes: addressData, count: addressDataLength)

    // Parse the sockaddr structure directly
    guard address.count >= MemoryLayout<sockaddr>.size else {
        lua_pushnil(L)
        return 1
    }

    let family: sa_family_t = address.withUnsafeBytes { ptr in
        ptr.load(fromByteOffset: 1, as: sa_family_t.self)
    }

    var host: String?
    var port: UInt16 = 0

    switch Int32(family) {
    case AF_INET:
        guard address.count >= MemoryLayout<sockaddr_in>.size else {
            lua_pushnil(L)
            return 1
        }
        address.withUnsafeBytes { ptr in
            let addr = ptr.load(as: sockaddr_in.self)
            port = UInt16(bigEndian: addr.sin_port)
            var addrCopy = addr.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addrCopy, &buf, socklen_t(INET_ADDRSTRLEN))
            host = String(cString: buf)
        }
    case AF_INET6:
        guard address.count >= MemoryLayout<sockaddr_in6>.size else {
            lua_pushnil(L)
            return 1
        }
        address.withUnsafeBytes { ptr in
            let addr = ptr.load(as: sockaddr_in6.self)
            port = UInt16(bigEndian: addr.sin6_port)
            var addrCopy = addr.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addrCopy, &buf, socklen_t(INET6_ADDRSTRLEN))
            host = String(cString: buf)
        }
    default:
        lua_pushnil(L)
        return 1
    }

    if let host = host {
        lua_pushany(L, [
            "host": host as NSString,
            "port": NSNumber(value: port),
            "addressFamily": NSNumber(value: family),
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
    let asyncSocket = getUserData(L, 1)

    if lua_type(L, 3) == LUA_TNUMBER {
        let theHost = lua_tovalue(L, at: 2) as! String
        let thePort = (lua_tovalue(L, at: 3) as! NSNumber).uint16Value
        if lua_type(L, 4) == LUA_TFUNCTION {
            lua_pushvalue(L, 4)
            asyncSocket.connectCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }

        do {
            try asyncSocket.connect(toHost: theHost, onPort: thePort, withTimeout: asyncSocket.socketTimeout)
        } catch {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.connectCallbackRef)

            asyncSocket.connectCallbackRef = LUA_NOREF
            os_log(.error, "%{public}s", "Unable to connect to host/port: \(error.localizedDescription)")
            lua_pushnil(L)
            return 1
        }
    } else {
        let thePath = (lua_tovalue(L, at: 2) as! NSString).expandingTildeInPath
        if lua_type(L, 3) == LUA_TFUNCTION {
            lua_pushvalue(L, 3)
            asyncSocket.connectCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }

        if let connectURL = URL(string: thePath) {
            do {
                try asyncSocket.connect(toURL: connectURL, withTimeout: asyncSocket.socketTimeout)
            } catch {
                luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.connectCallbackRef)

                asyncSocket.connectCallbackRef = LUA_NOREF
                os_log(.error, "%{public}s", "Unable to connect to Unix domain socket: \(error.localizedDescription)")
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
    let asyncSocket = getUserData(L, 1)

    if lua_type(L, 2) == LUA_TNUMBER {
        let thePort = (lua_tovalue(L, at: 2) as! NSNumber).uint16Value
        do {
            try asyncSocket.accept(onPort: thePort)
        } catch {
            os_log(.error, "%{public}s", "Unable to bind port: \(error.localizedDescription)")
            lua_pushnil(L)
            return 1
        }
    } else {
        var thePath = lua_tovalue(L, at: 2) as! String
        thePath = (thePath as NSString).expandingTildeInPath
        if let acceptURL = URL(string: thePath) {
            do {
                try asyncSocket.accept(onURL: acceptURL)
            } catch {
                os_log(.error, "%{public}s", "Unable to bind Unix domain path: \(error.localizedDescription)")
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
    luaL_checkudata(L, 1, USERDATA_TAG)
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
///  * `tag` - An optional integer to assist with labeling reads. It is passed to the callback to assist with implementing state machines for processing complex protocols.
///
/// Returns:
///  * The [`hs.socket`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Results are passed to the socket's [callback function](#setCallback), which must be set to use this method.
///  * If called on a listening socket with multiple connections, data is read from each of them.
///
private func socket_read(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncSocket = getUserData(L, 1)
    let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1

    if asyncSocket.readCallbackRef == LUA_NOREF {
        os_log(.error, "%{public}s", "No callback defined!")
        lua_pushnil(L)
        return 1
    }

    switch lua_type(L, 2) {
    case LUA_TNUMBER:
        let bytes = (lua_tovalue(L, at: 2) as! NSNumber).uintValue
        asyncSocket.readData(toLength: bytes, withTimeout: asyncSocket.socketTimeout, tag: tag)
        if asyncSocket.role == .server {
            asyncSocket.readDataFromClients(toLength: bytes, withTimeout: asyncSocket.socketTimeout, tag: tag)
        }
    case LUA_TSTRING:
        let separatorString = lua_tovalue(L, at: 2) as! String
        let separator = separatorString.data(using: .utf8)!
        asyncSocket.readData(to: separator, withTimeout: asyncSocket.socketTimeout, tag: tag)
        if asyncSocket.role == .server {
            asyncSocket.readDataFromClients(to: separator, withTimeout: asyncSocket.socketTimeout, tag: tag)
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
    let asyncSocket = getUserData(L, 1)
    let message = lua_tovalue(L, at: 2) as! Data
    let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1

    if lua_type(L, 3) == LUA_TFUNCTION {
        lua_pushvalue(L, 3)
        asyncSocket.writeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }
    if lua_type(L, 3) != LUA_TFUNCTION && lua_type(L, 4) == LUA_TFUNCTION {
        lua_pushvalue(L, 4)
        asyncSocket.writeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    if asyncSocket.role == .server {
        asyncSocket.writeToClients(message, withTimeout: asyncSocket.socketTimeout, tag: tag)
    } else {
        asyncSocket.write(message, withTimeout: asyncSocket.socketTimeout, tag: tag)
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
    let asyncSocket = getUserData(L, 1)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.readCallbackRef)

    asyncSocket.readCallbackRef = LUA_NOREF

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        asyncSocket.readCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
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
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)
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
    let asyncSocket = getUserData(L, 1)

    var verify = true
    var peerName: String? = nil

    if lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 2) == 0 {
        verify = false
    } else if lua_type(L, 2) == LUA_TSTRING {
        peerName = lua_tovalue(L, at: 2) as? String
    }

    asyncSocket.startTLS(verify: verify, peerName: peerName)

    lua_pushvalue(L, 1)
    return 1
}

private func get_socket_connections(_ asyncSocket: HSAsyncTcpSocket) -> Int {
    if asyncSocket.role == .server {
        asyncSocket.connectedSockets.count
    } else {
        asyncSocket.isConnected ? 1 : 0
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
    lsCheckArgs(L,LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
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
    lsCheckArgs(L,LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
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
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncSocket = getUserData(L, 1)

    let info: NSDictionary = [
        "connectedAddress": asyncSocket.connectedAddress ?? Data(),
        "connectedHost": asyncSocket.connectedHost ?? "",
        "connectedPort": NSNumber(value: asyncSocket.connectedPort),
        "connectedURL": asyncSocket.unixSocketPath ?? "",
        "connections": NSNumber(value: get_socket_connections(asyncSocket)),
        "isConnected": NSNumber(value: asyncSocket.isConnected),
        "isDisconnected": NSNumber(value: asyncSocket.isDisconnected),
        "isIPv4": NSNumber(value: asyncSocket.isIPv4Flag),
        "isIPv4Enabled": NSNumber(value: asyncSocket.isIPv4Enabled),
        "isIPv4PreferredOverIPv6": NSNumber(value: asyncSocket.isIPv4PreferredOverIPv6),
        "isIPv6": NSNumber(value: asyncSocket.isIPv6Flag),
        "isIPv6Enabled": NSNumber(value: asyncSocket.isIPv6Enabled),
        "isSecure": NSNumber(value: asyncSocket.isSecure),
        "localAddress": asyncSocket.localAddress ?? Data(),
        "localHost": asyncSocket.localHost ?? "",
        "localPort": NSNumber(value: asyncSocket.localPort),
        "timeout": NSNumber(value: asyncSocket.socketTimeout),
        "unixSocketPath": asyncSocket.unixSocketPath ?? "",
        "userData": asyncSocket.role.rawValue,
    ]

    lua_pushany(L, info)
    return 1
}

// MARK: - Library Registration Functions

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncSocket = getUserData(L, 1)

    let isServer = asyncSocket.role == .server
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

    asyncSocket.disconnect()
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.readCallbackRef)

    asyncSocket.readCallbackRef = LUA_NOREF
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.writeCallbackRef)

    asyncSocket.writeCallbackRef = LUA_NOREF
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncSocket.connectCallbackRef)

    asyncSocket.connectCallbackRef = LUA_NOREF

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
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(meta_gcLib.count - 1))
    luaL_setfuncs(L, &meta_gcLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
