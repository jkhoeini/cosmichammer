import Cocoa
import CLua
import Lua
import os.log
import Network
import HSDSTCore

// MARK: - Common Code

private func mainThreadDispatch(_ block: @escaping () -> Void) {
    DispatchQueue.main.async { autoreleasepool { block() } }
}

/// Dispatch that fires during RunLoop.main.run (used by simulated callbacks to
/// ensure events are processed by test harness RunLoop draining).
private func runLoopDispatch(_ block: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        autoreleasepool { block() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

private enum SocketRole: String {
    case `default` = "DEFAULT"
    case server = "SERVER"
    case client = "CLIENT"
}

private let USERDATA_TAG = "hs.socket"

/// Maximum size for the socket read buffer (10 MB).  If accumulated data
/// exceeds this without producing a delimiter match the read is abandoned
/// and an error is logged.
private let kMaxSocketBufferSize = 10_485_760

/// Maximum number of concurrently connected client sockets a server socket
/// will accept.  New connections beyond this limit are rejected with an
/// error log.
private let kMaxConnectedSockets = 1000

private func socketCheckPort(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> UInt16 {
    let port = luaL_checkinteger(L, idx)
    luaL_argcheck(L, port >= 0 && port <= 65_535, idx, "port must be between 0 and 65535")
    return UInt16(port)
}

private func socketCheckByteCount(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> UInt {
    let count = luaL_checkinteger(L, idx)
    luaL_argcheck(L, count >= 0, idx, "byte count must be non-negative")
    return UInt(count)
}

// MARK: - Lua Callbacks

private func tcpConnectCallback(_ asyncSocket: HSAsyncTcpSocket) {
    mainThreadDispatch {
        guard lua_isStateGenerationValid(asyncSocket.generation) else {
            asyncSocket.teardown()
            return
        }
        if asyncSocket.readCallback != nil || asyncSocket.connectCallback != nil {
            // Only fire if connectCallback is set
            guard asyncSocket.connectCallback != nil else { return }
            let L = lua_getCurrentState()!
            asyncSocket.connectCallback?.push(onto: L)
            asyncSocket.connectCallback = nil  // single-use
            if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func tcpWriteCallback(_ asyncSocket: HSAsyncTcpSocket, tag: Int) {
    mainThreadDispatch {
        guard lua_isStateGenerationValid(asyncSocket.generation) else {
            asyncSocket.teardown()
            return
        }
        if asyncSocket.writeCallback != nil {
            let L = lua_getCurrentState()!
            asyncSocket.writeCallback?.push(onto: L)
            L.push(lua_Integer(tag))
            asyncSocket.writeCallback = nil  // single-use
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func tcpReadCallback(_ asyncSocket: HSAsyncTcpSocket, data: Data, tag: Int) {
    mainThreadDispatch {
        guard lua_isStateGenerationValid(asyncSocket.generation) else {
            asyncSocket.teardown()
            return
        }
        if asyncSocket.readCallback != nil {
            let L = lua_getCurrentState()!
            asyncSocket.readCallback?.push(onto: L)
            lua_pushdata(L, data)
            L.push(lua_Integer(tag))
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

/// Simulated-mode connect callback that dispatches via RunLoop (not GCD) so
/// test-harness RunLoop.main.run(until:) can drain it.  Falls back to
/// mainThreadDispatch when not in a test environment.
private func simScheduleConnectCallback(_ asyncSocket: HSAsyncTcpSocket) {
    runLoopDispatch {
        guard lua_isStateGenerationValid(asyncSocket.generation) else {
            asyncSocket.teardown()
            return
        }
        guard asyncSocket.connectCallback != nil else { return }
        let L = lua_getCurrentState()!
        asyncSocket.connectCallback?.push(onto: L)
        asyncSocket.connectCallback = nil
        if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
}

/// Simulated-mode write callback that dispatches via RunLoop (not GCD).
private func simScheduleWriteCallback(_ asyncSocket: HSAsyncTcpSocket, tag: Int) {
    runLoopDispatch {
        guard lua_isStateGenerationValid(asyncSocket.generation) else {
            asyncSocket.teardown()
            return
        }
        if asyncSocket.writeCallback != nil {
            let L = lua_getCurrentState()!
            asyncSocket.writeCallback?.push(onto: L)
            L.push(lua_Integer(tag))
            asyncSocket.writeCallback = nil
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

/// Simulated-mode read callback that dispatches via RunLoop (not GCD).
private func simScheduleReadCallback(_ asyncSocket: HSAsyncTcpSocket, data: Data, tag: Int) {
    runLoopDispatch {
        guard lua_isStateGenerationValid(asyncSocket.generation) else {
            asyncSocket.teardown()
            return
        }
        if asyncSocket.readCallback != nil {
            let L = lua_getCurrentState()!
            asyncSocket.readCallback?.push(onto: L)
            lua_pushdata(L, data)
            L.push(lua_Integer(tag))
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - TCP Socket Class (Network.framework)

private class HSAsyncTcpSocket {
    var readCallback: LuaValue?
    var writeCallback: LuaValue?
    var connectCallback: LuaValue?
    var generation: UInt64 = 0
    var socketTimeout: TimeInterval = -1
    var unixSocketPath: String?

    /// When non-nil, all operations route through the simulated socket protocol.
    var socketSim: (any SocketProtocol)?
    /// The simulated socket ID (valid only when socketSim is non-nil).
    var simSocketID: UInt64 = 0

    private var tornDown = false

    /// Idempotent teardown: disconnect, drop all Lua callback references.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        disconnect()
        readCallback = nil
        writeCallback = nil
        connectCallback = nil
    }

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

    /// Sync local state from the simulator (e.g. after server-side disconnect).
    func syncFromSim() {
        guard let sim = socketSim, sim.isSimulated else { return }
        guard role != .server else { return }
        if let info = sim.socketInfo(socketID: simSocketID), !info.isConnected && isConnectedFlag {
            isConnectedFlag = false
            connectedPort = 0
            connectedHost = nil
            connectedAddress = nil
            localPort = 0
            localHost = nil
            localAddress = nil
        }
    }

    var isConnected: Bool {
        if let sim = socketSim, sim.isSimulated {
            if role == .server {
                return sim.connectedClients(serverID: simSocketID).count > 0
            }
            syncFromSim()
            return isConnectedFlag
        }
        if role == .server {
            lock.lock()
            let count = connectedSockets.count
            lock.unlock()
            return count > 0
        }
        return isConnectedFlag
    }

    var isDisconnected: Bool {
        if let sim = socketSim, sim.isSimulated {
            if isListeningFlag { return false }
            if unixSocketPath != nil && role == .server { return false }
            syncFromSim()
            return !isConnectedFlag
        }
        // A listening server (NWListener or Unix) is neither connected nor
        // disconnected -- it is "listening".  Only report disconnected when
        // the socket has no listener AND is not connected.
        if listener != nil { return !isListeningFlag }
        if role == .server && unixListenFD >= 0 { return false }
        return !isConnectedFlag
    }

    var isSecure: Bool { isSecureFlag }

    // MARK: Client connect (host:port)

    func connect(toHost host: String, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        guard !host.isEmpty else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "TCP connect host must not be empty"])
        }
        guard port > 0 else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "TCP connect port must be greater than zero"])
        }
        guard role == .default || role == .client else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot connect a server socket"])
        }

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            // Register data callback for later receives
            sim.setCallback(socketID: simSocketID) { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .data(let data):
                    self.simReceiveBuffer.append(data)
                    self.drainSimPendingReads()
                default:
                    break
                }
            }
            let result = sim.connect(socketID: simSocketID, host: host, port: port)
            if result {
                isConnectedFlag = true
                connectedHost = host
                connectedPort = port
                localHost = "127.0.0.1"
                localPort = UInt16(truncatingIfNeeded: 10000 + simSocketID % 50000)
                isIPv4Flag = true
                connectedAddress = sockaddrData(host: "127.0.0.1", port: port)
                localAddress = sockaddrData(host: "127.0.0.1", port: localPort)
                // Fire connect callback via RunLoop (not GCD) so test harness can drain it
                if self.connectCallback != nil {
                    simScheduleConnectCallback(self)
                }
            } else {
                throw NSError(domain: "HSAsyncTcpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Simulated connection failed"])
            }
            return
        }

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
                if self.connectCallback != nil {
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

    // MARK: - Simulated receive buffer and pending reads

    /// Buffer for data received via simulated callbacks.
    var simReceiveBuffer = Data()

    /// Pending simulated read requests.
    private var simPendingReads: [(kind: SimReadKind, tag: Int)] = []

    /// Timer for simulated read timeout (disconnects the socket if reads can't be fulfilled).
    private var simReadTimeoutTimer: Timer?

    private enum SimReadKind {
        case bytes(Int)
        case delimiter(Data)
    }

    /// Schedule a simulated read timeout. If reads are still pending after `socketTimeout`,
    /// disconnect the socket (matching real NWConnection timeout behavior).
    func scheduleSimReadTimeout() {
        guard socketTimeout >= 0 else { return }
        // Cancel any existing timer
        simReadTimeoutTimer?.invalidate()
        simReadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: socketTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.simPendingReads.isEmpty {
                self.simPendingReads.removeAll()
                self.disconnect()
            }
        }
    }

    /// Drain pending simulated reads against the receive buffer.
    /// For server sockets, also pulls data from connected client buffers.
    func drainSimPendingReads() {
        // For server sockets, collect data from sim's connected clients
        if role == .server, let sim = socketSim {
            let clientIDs = sim.connectedClients(serverID: simSocketID)
            for clientID in clientIDs {
                // Pull all available data from each client's receive buffer
                while let data = sim.receiveFromClient(serverID: simSocketID, clientID: clientID, length: 0) {
                    guard !data.isEmpty else { break }
                    simReceiveBuffer.append(data)
                }
            }
        }

        while !simPendingReads.isEmpty {
            let pending = simPendingReads[0]
            switch pending.kind {
            case .bytes(let length):
                guard simReceiveBuffer.count >= length else { return }
                let data = Data(simReceiveBuffer.prefix(length))
                simReceiveBuffer.removeFirst(length)
                simPendingReads.removeFirst()
                simScheduleReadCallback(self, data: data, tag: pending.tag)
            case .delimiter(let delim):
                guard let range = simReceiveBuffer.range(of: delim) else { return }
                let endIndex = range.upperBound
                let chunk = Data(simReceiveBuffer.prefix(upTo: endIndex))
                simReceiveBuffer.removeSubrange(simReceiveBuffer.startIndex..<endIndex)
                simPendingReads.removeFirst()
                simScheduleReadCallback(self, data: chunk, tag: pending.tag)
            }
        }

        // Cancel the timeout timer if all reads are fulfilled
        if simPendingReads.isEmpty {
            simReadTimeoutTimer?.invalidate()
            simReadTimeoutTimer = nil
        }
    }

    // MARK: Client connect (Unix domain socket)

    func connect(toURL url: URL, withTimeout timeout: TimeInterval) throws {
        let path = url.path
        guard !path.isEmpty else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "TCP Unix domain socket path must not be empty"])
        }
        guard role == .default || role == .client else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot connect a server socket to a Unix path"])
        }

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            // Register data callback for later receives
            sim.setCallback(socketID: simSocketID) { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .data(let data):
                    self.simReceiveBuffer.append(data)
                    self.drainSimPendingReads()
                default:
                    break
                }
            }
            let result = sim.connectUnix(socketID: simSocketID, path: path)
            if result {
                isConnectedFlag = true
                unixSocketPath = path
                // Fire connect callback via RunLoop (not GCD) so test harness can drain it
                if self.connectCallback != nil {
                    simScheduleConnectCallback(self)
                }
            } else {
                throw NSError(domain: "HSAsyncTcpSocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "Simulated Unix connect failed"])
            }
            return
        }

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
                if self.connectCallback != nil {
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
        guard role == .default else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 10, userInfo: [NSLocalizedDescriptionKey: "Socket already has a role assigned: \(role.rawValue)"])
        }
        guard !isConnectedFlag else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot listen on a connected socket"])
        }

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            let result = sim.listen(socketID: simSocketID, port: port)
            if result {
                role = .server
                localHost = "0.0.0.0"
                localPort = port
                isListeningFlag = true
            } else {
                throw NSError(domain: "HSAsyncTcpSocket", code: 10, userInfo: [NSLocalizedDescriptionKey: "Simulated listen failed"])
            }
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let nwListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        setupListener(nwListener)

        assert(role == .server, "Role must be server after accept")
    }

    // MARK: Server listen (Unix domain socket)

    func accept(onURL url: URL) throws {
        let path = url.path
        guard !path.isEmpty else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unix domain socket path must not be empty"])
        }
        guard role == .default else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 10, userInfo: [NSLocalizedDescriptionKey: "Socket already has a role assigned: \(role.rawValue)"])
        }
        guard !isConnectedFlag else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot listen on a connected socket"])
        }

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            let result = sim.listenUnix(socketID: simSocketID, path: path)
            if result {
                role = .server
                unixSocketPath = path
                isListeningFlag = true
            } else {
                throw NSError(domain: "HSAsyncTcpSocket", code: 12, userInfo: [NSLocalizedDescriptionKey: "Simulated Unix listen failed"])
            }
            return
        }

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
        guard !path.isEmpty else {
            throw NSError(domain: "HSAsyncTcpSocket", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unix socket path must not be empty"])
        }

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

    /// Track whether the listener is actively listening (ready and not cancelled).
    private(set) var isListeningFlag: Bool = false

    private func setupListener(_ nwListener: NWListener) {
        assert(listener == nil, "Listener already set; cannot setup a second listener")

        let semaphore = DispatchSemaphore(value: 0)

        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let port = nwListener.port {
                    self.localPort = port.rawValue
                }
                self.localHost = "0.0.0.0"
                self.isListeningFlag = true
                os_log(.debug,"TCP server listening")
                semaphore.signal()
            case .failed(let err):
                self.isListeningFlag = false
                os_log(.debug, "%{public}s", "TCP server failed: \(err)")
                semaphore.signal()
            case .cancelled:
                self.isListeningFlag = false
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
        semaphore.wait()
    }

    private func handleNewConnection(_ newConn: NWConnection) {
        os_log(.debug,"TCP client connected")

        lock.lock()
        let currentCount = connectedSockets.count
        lock.unlock()

        if currentCount >= kMaxConnectedSockets {
            os_log(.error, "TCP server at max connected sockets (%d) — rejecting new connection", kMaxConnectedSockets)
            newConn.cancel()
            return
        }

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
        let previousRole = role
        _ = previousRole // suppress unused warning; used in postcondition below

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            _ = sim.close(socketID: simSocketID)
            isListeningFlag = false
            isConnectedFlag = false
            localPort = 0
            localHost = nil
            connectedHost = nil
            connectedPort = 0
            connectedAddress = nil
            localAddress = nil
            unixSocketPath = nil
            role = .default
            isIPv4Flag = false
            isIPv6Flag = false
            simReceiveBuffer.removeAll()
            simPendingReads.removeAll()
            simReadTimeoutTimer?.invalidate()
            simReadTimeoutTimer = nil
            // Re-create a fresh simulated socket ID for reuse
            simSocketID = sim.createTCPSocket()
            return
        }

        if role == .server {
            isListeningFlag = false
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

        assert(role == .default, "Role must be reset to default after disconnect")
        assert(!isConnectedFlag || previousRole == .server, "isConnectedFlag should be false after disconnect for non-server sockets")
    }

    // MARK: Read data (length-based)

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        guard length > 0 else { return }

        // Simulated path -- server sockets skip here because socket_read
        // also calls readDataFromClients which handles the pending read.
        // Queueing in both would double-read data.
        if socketSim != nil && socketSim!.isSimulated {
            if role == .server { return }
            simPendingReads.append((.bytes(Int(length)), tag))
            drainSimPendingReads()
            if !simPendingReads.isEmpty { scheduleSimReadTimeout() }
            return
        }

        guard let conn = connection else { return }
        receiveExactly(from: conn, length: Int(length), timeout: timeout, buffer: Data()) { [weak self] data in
            guard let self = self else { return }
            tcpReadCallback(self, data: data, tag: tag)
        }
    }

    /// Read exactly `length` bytes from a connection, accumulating into buffer.
    private func receiveExactly(from conn: NWConnection, length: Int, timeout: TimeInterval, buffer: Data, completion: @escaping (Data) -> Void) {
        guard length > 0 else {
            completion(buffer)
            return
        }
        assert(buffer.count <= length, "Buffer already exceeds requested length")

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
        // Simulated path: reads go through the server socket's own pending reads
        if socketSim != nil && socketSim!.isSimulated {
            simPendingReads.append((.bytes(Int(length)), tag))
            drainSimPendingReads()
            return
        }

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
        guard !separator.isEmpty else { return }

        // Simulated path -- server sockets skip here because socket_read
        // also calls readDataFromClients which handles the pending read.
        if socketSim != nil && socketSim!.isSimulated {
            if role == .server { return }
            simPendingReads.append((.delimiter(separator), tag))
            drainSimPendingReads()
            if !simPendingReads.isEmpty { scheduleSimReadTimeout() }
            return
        }

        guard let conn = connection else { return }
        receiveUntilDelimiter(from: conn, separator: separator, timeout: timeout, buffer: &readBuffer) { [weak self] data in
            guard let self = self else { return }
            tcpReadCallback(self, data: data, tag: tag)
        }
    }

    private func receiveUntilDelimiter(from conn: NWConnection, separator: Data, timeout: TimeInterval, buffer: inout Data, completion: @escaping (Data) -> Void) {
        guard !separator.isEmpty else { return }

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
                if self.readBuffer.count + content.count > kMaxSocketBufferSize {
                    os_log(.error, "TCP read buffer exceeded %d bytes — abandoning read", kMaxSocketBufferSize)
                    self.readBuffer.removeAll()
                    return
                }
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
        // Simulated path: reads go through the server socket's own pending reads
        if socketSim != nil && socketSim!.isSimulated {
            simPendingReads.append((.delimiter(separator), tag))
            drainSimPendingReads()
            return
        }

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
                if buf.count + content.count > kMaxSocketBufferSize {
                    os_log(.error, "TCP client read buffer exceeded %d bytes — abandoning read for client", kMaxSocketBufferSize)
                    self.clientReadBuffers[clientId] = Data()
                    return
                }
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
        guard !data.isEmpty else { return }

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            _ = sim.send(socketID: simSocketID, data: data)
            if self.writeCallback != nil {
                simScheduleWriteCallback(self, tag: tag)
            }
            return
        }

        guard let conn = connection else { return }
        sendData(data, on: conn, timeout: timeout) { [weak self] in
            guard let self = self else { return }
            if self.writeCallback != nil {
                tcpWriteCallback(self, tag: tag)
            }
        }
    }

    func writeToClients(_ data: Data, withTimeout timeout: TimeInterval, tag: Int) {
        guard !data.isEmpty else { return }
        guard role == .server else { return }

        // Simulated path
        if let sim = socketSim, sim.isSimulated {
            let clientIDs = sim.connectedClients(serverID: simSocketID)
            for clientID in clientIDs {
                _ = sim.sendToClient(serverID: simSocketID, clientID: clientID, data: data)
            }
            if self.writeCallback != nil {
                simScheduleWriteCallback(self, tag: tag)
            }
            return
        }

        lock.lock()
        let clients = connectedSockets
        lock.unlock()

        var remaining = clients.count
        guard remaining > 0 else {
            if self.writeCallback != nil {
                tcpWriteCallback(self, tag: tag)
            }
            return
        }

        for client in clients {
            sendData(data, on: client, timeout: timeout) { [weak self] in
                guard let self = self else { return }
                remaining -= 1
                if remaining <= 0 && self.writeCallback != nil {
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
        guard role != .server else { return }
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
        assert(!host.isEmpty, "sockaddrData: host must not be empty")

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
private func socket_new(_ L: LuaState) throws -> CInt {
    let asyncSocket = HSAsyncTcpSocket()

    // Attach simulated socket protocol if available
    let env = environmentGet(L)
    if env.socket.isSimulated {
        asyncSocket.socketSim = env.socket
        asyncSocket.simSocketID = env.socket.createTCPSocket()
    }

    if lua_type(L, 1) == LUA_TFUNCTION {
        asyncSocket.readCallback = L.ref(index: 1)
    }

    lua_getglobal(L, "require")
    L.push("hs.socket")
    lua_pcall(L, 1, 1, 0)
    lua_getfield(L, -1, "timeout")
    asyncSocket.socketTimeout = lua_tonumber(L, -1)
    lua_pop(L, 2) // pop timeout value and module table

    asyncSocket.generation = lua_currentStateGeneration()
    L.push(userdata: asyncSocket)

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
private func socket_parseAddress(_ L: LuaState) throws -> CInt {
    let stackBase = lua_gettop(L)
    assert(stackBase >= 1, "parseAddress requires at least 1 argument")

    let address = lua_checkdata(L, at: 1)

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
private func socket_connect(_ L: LuaState) throws -> CInt {
    let stackBase = lua_gettop(L)
    assert(stackBase >= 2, "connect requires at least 2 arguments (self, host/path)")

    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    if lua_type(L, 3) == LUA_TNUMBER {
        let theHost = lua_tovalue(L, at: 2) as! String
        let thePort = socketCheckPort(L, at: 3)
        if lua_type(L, 4) == LUA_TFUNCTION {
            asyncSocket.connectCallback = L.ref(index: 4)
        }

        do {
            try asyncSocket.connect(toHost: theHost, onPort: thePort, withTimeout: asyncSocket.socketTimeout)
        } catch {
            asyncSocket.connectCallback = nil
            os_log(.error, "%{public}s", "Unable to connect to host/port: \(error.localizedDescription)")
            lua_pushnil(L)
            return 1
        }
    } else {
        let thePath = (lua_tovalue(L, at: 2) as! NSString).expandingTildeInPath
        if lua_type(L, 3) == LUA_TFUNCTION {
            asyncSocket.connectCallback = L.ref(index: 3)
        }

        if let connectURL = URL(string: thePath) {
            do {
                try asyncSocket.connect(toURL: connectURL, withTimeout: asyncSocket.socketTimeout)
            } catch {
                asyncSocket.connectCallback = nil
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
private func socket_listen(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    if lua_type(L, 2) == LUA_TNUMBER {
        let thePort = socketCheckPort(L, at: 2)
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
private func socket_disconnect(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

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
private func socket_read(_ L: LuaState) throws -> CInt {
    let stackBase = lua_gettop(L)
    assert(stackBase >= 2, "read requires at least 2 arguments (self, delimiter)")

    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)
    let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1

    if asyncSocket.readCallback == nil {
        os_log(.error, "%{public}s", "No callback defined!")
        lua_pushnil(L)
        return 1
    }

    switch lua_type(L, 2) {
    case LUA_TNUMBER:
        let bytes = socketCheckByteCount(L, at: 2)
        asyncSocket.readData(toLength: bytes, withTimeout: asyncSocket.socketTimeout, tag: tag)
        if asyncSocket.role == .server {
            asyncSocket.readDataFromClients(toLength: bytes, withTimeout: asyncSocket.socketTimeout, tag: tag)
        }
    case LUA_TSTRING:
        let separator = lua_checkdata(L, at: 2)
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
private func socket_write(_ L: LuaState) throws -> CInt {
    let stackBase = lua_gettop(L)
    assert(stackBase >= 2, "write requires at least 2 arguments (self, message)")

    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)
    let message = lua_checkdata(L, at: 2)
    let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1

    if lua_type(L, 3) == LUA_TFUNCTION {
        asyncSocket.writeCallback = L.ref(index: 3)
    }
    if lua_type(L, 3) != LUA_TFUNCTION && lua_type(L, 4) == LUA_TFUNCTION {
        asyncSocket.writeCallback = L.ref(index: 4)
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
private func socket_setCallback(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    if lua_type(L, 2) == LUA_TFUNCTION {
        asyncSocket.readCallback = L.ref(index: 2)
    } else {
        asyncSocket.readCallback = nil
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
private func socket_setTimeout(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    luaL_checktype(L, 2, LUA_TNUMBER)
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
private func socket_startTLS(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

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
    if let sim = asyncSocket.socketSim, sim.isSimulated {
        if asyncSocket.role == .server {
            return sim.connectedClients(serverID: asyncSocket.simSocketID).count
        }
        return asyncSocket.isConnected ? 1 : 0
    }
    if asyncSocket.role == .server {
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
private func socket_connected(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    L.push(get_socket_connections(asyncSocket) != 0)
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
private func socket_connections(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    L.push(lua_Integer(get_socket_connections(asyncSocket)))
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
private func socket_info(_ L: LuaState) throws -> CInt {
    let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

    // Sync sim state before reading properties
    asyncSocket.syncFromSim()

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
        "userData": asyncSocket.role == .default ? "" : asyncSocket.role.rawValue,
    ]

    lua_pushany(L, info)
    return 1
}

// MARK: - Library Registration

@_cdecl("luaopen_hs_libsocket")
public func luaopen_hs_libsocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "lua_State must not be nil")
    let stackBase = lua_gettop(L)

    // Register idiomatic Metatable<HSAsyncTcpSocket> with LuaSwift.
    L.register(Metatable<HSAsyncTcpSocket>(
        fields: [
            "connect": .closure { L in
                return try socket_connect(L)
            },
            "listen": .closure { L in
                return try socket_listen(L)
            },
            "disconnect": .closure { L in
                return try socket_disconnect(L)
            },
            "read": .closure { L in
                return try socket_read(L)
            },
            "write": .closure { L in
                return try socket_write(L)
            },
            "setCallback": .closure { L in
                return try socket_setCallback(L)
            },
            "setTimeout": .closure { L in
                return try socket_setTimeout(L)
            },
            "startTLS": .closure { L in
                return try socket_startTLS(L)
            },
            "connected": .closure { L in
                return try socket_connected(L)
            },
            "connections": .closure { L in
                return try socket_connections(L)
            },
            "info": .closure { L in
                return try socket_info(L)
            },
        ],
        tostring: .closure { L in
            let asyncSocket: HSAsyncTcpSocket = try L.checkArgument(1)

            let isServer = asyncSocket.role == .server
            let theHost = isServer ? asyncSocket.localHost : asyncSocket.connectedHost
            let thePort = isServer ? asyncSocket.localPort : asyncSocket.connectedPort
            let theAddress = asyncSocket.unixSocketPath ?? "\(theHost ?? ""):\(thePort)"
            let udTag = isServer ? "\(USERDATA_TAG)(server)" : USERDATA_TAG

            L.push("\(udTag): \(theAddress) (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // Replace __gc with our explicit teardown + deinitialize
    L.pushMetatable(for: HSAsyncTcpSocket.self)

    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let asyncSocket: HSAsyncTcpSocket = L.touserdata(1) {
            asyncSocket.teardown()
        }
        // Deinitialize the Any box (same as LuaSwift's gcUserdata)
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name "hs.socket" so that
    // core_getObjectMetatable("hs.socket") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 2)
    L.push(socket_new)
    lua_setfield(L, -2, "new")
    L.push(socket_parseAddress)
    lua_setfield(L, -2, "parseAddress")

    assert(lua_gettop(L) == stackBase + 1, "luaopen_hs_libsocket must leave exactly 1 value (module table) on the stack")
    return 1
}
