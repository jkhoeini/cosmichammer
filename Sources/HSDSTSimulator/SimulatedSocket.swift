import Foundation
import HSDSTCore

/// Dispatch a block via CFRunLoopPerformBlock so it fires during
/// `RunLoop.main.run(until:)` -- `DispatchQueue.main.async` does NOT
/// drain during RunLoop-based test harness loops in Swift Testing.
private func simRunLoopDispatch(_ block: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// State-machine based socket simulator for DST.
///
/// Tracks TCP/UDP sockets, TCP servers with connected clients, and UDP
/// bound/connected sockets. All operations are synchronous and deterministic.
/// Callbacks are dispatched via CFRunLoopPerformBlock so they fire on
/// the next RunLoop drain (compatible with Swift Testing's RunLoop-based harness).
public final class SimulatedSocket: SocketProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var isSimulated: Bool { true }

    // MARK: - Socket state

    private enum SocketState {
        case tcp(TCPSocketState)
        case udp(UDPSocketState)
    }

    private class TCPSocketState {
        var localHost: String = ""
        var localPort: UInt16 = 0
        var remoteHost: String?
        var remotePort: UInt16?
        var isConnected: Bool = false
        var isListening: Bool = false
        var unixPath: String?
        var role: String = "DEFAULT"

        // Server state
        var connectedClientIDs: [UInt64] = []

        // Data buffers
        var receiveBuffer: Data = Data()

        // Callback
        var callback: ((SocketEvent) -> Void)?

        // IPv4/IPv6 flags
        var isIPv4: Bool = false
        var isIPv6: Bool = false
    }

    private class UDPSocketState {
        var localHost: String = ""
        var localPort: UInt16 = 0
        var connectedHost: String?
        var connectedPort: UInt16 = 0
        var isBound: Bool = false
        var isConnected: Bool = false
        var isClosed: Bool = true
        var role: String = "DEFAULT"

        // Config
        var ipv4Enabled: Bool = true
        var ipv6Enabled: Bool = true
        var preferredIPVersion: Int = 0
        var broadcastEnabled: Bool = false
        var reusePortEnabled: Bool = false
        var maxRecvIPv4Buffer: UInt16 = 65535
        var maxRecvIPv6Buffer: UInt32 = 65535
        var continuousReceive: Bool = false
        var receiveActive: Bool = false

        // Data buffers
        var receiveBuffer: [(data: Data, address: Data)] = []

        // Callback
        var callback: ((SocketEvent) -> Void)?
    }

    private var sockets: [UInt64: SocketState] = [:]
    private var nextSocketID: UInt64 = 1

    // TCP server tracking: serverID -> port
    private var serverPorts: [UInt64: UInt16] = [:]
    // Reverse: port -> serverID (for routing connections)
    private var portToServer: [UInt16: UInt64] = [:]
    // Unix path -> serverID
    private var unixPathToServer: [String: UInt64] = [:]

    // Map from clientOnServer socketID -> original client socketID (for disconnect propagation)
    private var clientOnServerToOriginal: [UInt64: UInt64] = [:]

    // UDP port tracking: port -> [socketIDs] (for reusePort + broadcast)
    private var udpPortListeners: [UInt16: [UInt64]] = [:]
    // Connected UDP sockets by their synthetic local port (for data delivery)
    private var udpConnectedByLocalPort: [UInt16: UInt64] = [:]

    // HTTP servers
    private var httpServers: [UInt64: UInt16] = [:]
    public var httpServerRequestCount: [UInt64: Int] = [:]

    // Track sent data for test inspection
    public var sentData: [(socketID: UInt64, data: Data, host: String?, port: UInt16?)] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Socket Creation

    public func createTCPSocket() -> UInt64 {
        let id = nextSocketID
        nextSocketID += 1
        sockets[id] = .tcp(TCPSocketState())
        return id
    }

    public func createUDPSocket() -> UInt64 {
        let id = nextSocketID
        nextSocketID += 1
        sockets[id] = .udp(UDPSocketState())
        return id
    }

    // MARK: - TCP Connection

    public func connect(socketID: UInt64, host: String, port: UInt16) -> Bool {
        // Handle UDP connect
        if case .udp(_) = sockets[socketID] {
            return udpConnect(socketID: socketID, host: host, port: port)
        }

        guard case .tcp(let state) = sockets[socketID] else { return false }
        guard !state.isConnected else { return false }

        if rng.boolean(probability: faults.connectionFailProbability) {
            state.callback?(.error("Connection failed (simulated)"))
            return false
        }

        state.remoteHost = host
        state.remotePort = port
        state.isConnected = true
        state.localHost = "127.0.0.1"
        state.localPort = UInt16(10000 + (nextSocketID % 50000))
        state.isIPv4 = true

        // If there's a server listening on this port, register as client
        if let serverID = portToServer[port], case .tcp(let serverState) = sockets[serverID] {
            // Create a client-side socket on the server
            let clientOnServerID = nextSocketID
            nextSocketID += 1
            let clientOnServer = TCPSocketState()
            clientOnServer.remoteHost = "127.0.0.1"
            clientOnServer.remotePort = state.localPort
            clientOnServer.localHost = "0.0.0.0"
            clientOnServer.localPort = port
            clientOnServer.isConnected = true
            clientOnServer.role = "CLIENT"
            clientOnServer.isIPv4 = true
            sockets[clientOnServerID] = .tcp(clientOnServer)
            serverState.connectedClientIDs.append(clientOnServerID)
            // Track mapping for disconnect propagation
            clientOnServerToOriginal[clientOnServerID] = socketID
        }
        return true
    }

    public func connectUnix(socketID: UInt64, path: String) -> Bool {
        guard case .tcp(let state) = sockets[socketID] else { return false }
        guard !state.isConnected else { return false }

        state.unixPath = path
        state.isConnected = true

        // If there's a server listening on this unix path, register as client
        if let serverID = unixPathToServer[path], case .tcp(let serverState) = sockets[serverID] {
            let clientOnServerID = nextSocketID
            nextSocketID += 1
            let clientOnServer = TCPSocketState()
            clientOnServer.unixPath = path
            clientOnServer.isConnected = true
            clientOnServer.role = "CLIENT"
            sockets[clientOnServerID] = .tcp(clientOnServer)
            serverState.connectedClientIDs.append(clientOnServerID)
            clientOnServerToOriginal[clientOnServerID] = socketID
        }

        simRunLoopDispatch {
            state.callback?(.connected)
        }
        return true
    }

    // MARK: - TCP Listen

    public func listen(socketID: UInt64, port: UInt16) -> Bool {
        guard case .tcp(let state) = sockets[socketID] else { return false }

        // Check if port is already in use by another server
        if portToServer[port] != nil {
            state.callback?(.error("Port already in use (simulated)"))
            return false
        }

        if rng.boolean(probability: faults.connectionFailProbability) {
            state.callback?(.error("Listen failed (simulated)"))
            return false
        }

        state.localHost = "0.0.0.0"
        state.localPort = port
        state.isListening = true
        state.role = "SERVER"
        serverPorts[socketID] = port
        portToServer[port] = socketID
        return true
    }

    public func listenUnix(socketID: UInt64, path: String) -> Bool {
        guard case .tcp(let state) = sockets[socketID] else { return false }

        // Check if path is already in use
        if unixPathToServer[path] != nil {
            state.callback?(.error("Unix path already in use (simulated)"))
            return false
        }

        state.unixPath = path
        state.isListening = true
        state.role = "SERVER"
        unixPathToServer[path] = socketID
        return true
    }

    // MARK: - TCP Send/Receive

    public func send(socketID: UInt64, data: Data) -> Bool {
        // Handle UDP send (connected mode)
        if case .udp(let udpState) = sockets[socketID] {
            guard udpState.isConnected else { return false }
            if rng.boolean(probability: faults.packetDropProbability) { return false }
            udpState.isClosed = false
            sentData.append((socketID: socketID, data: data, host: udpState.connectedHost, port: udpState.connectedPort))
            // Route to listeners on the connected port
            if udpState.connectedPort > 0 {
                routeUDPData(fromSocket: socketID, data: data, toPort: udpState.connectedPort, fromHost: udpState.connectedHost ?? "127.0.0.1")
            }
            return true
        }

        guard case .tcp(let state) = sockets[socketID] else { return false }
        guard state.isConnected else { return false }

        if rng.boolean(probability: faults.packetDropProbability) {
            return false
        }

        sentData.append((socketID: socketID, data: data, host: state.remoteHost, port: state.remotePort))

        // Route data to the peer socket's receive buffer
        routeTCPData(fromSocket: socketID, data: data)
        return true
    }

    public func sendToClient(serverID: UInt64, clientID: UInt64, data: Data) -> Bool {
        guard case .tcp(let serverState) = sockets[serverID],
              serverState.connectedClientIDs.contains(clientID),
              case .tcp(let clientState) = sockets[clientID] else { return false }

        // Data from server to client goes to the ORIGINAL connecting socket's receive buffer.
        // Use the clientOnServerToOriginal mapping for a direct lookup first.
        if let origClientID = clientOnServerToOriginal[clientID],
           case .tcp(let origState) = sockets[origClientID] {
            origState.receiveBuffer.append(data)
            simRunLoopDispatch {
                origState.callback?(.data(data))
            }
            return true
        }

        // Fallback: find connecting socket by port match
        if let port = serverPorts[serverID] {
            for (sid, socketState) in sockets {
                if case .tcp(let s) = socketState, s.remotePort == port, s.isConnected, sid != serverID, sid != clientID {
                    s.receiveBuffer.append(data)
                    simRunLoopDispatch {
                        s.callback?(.data(data))
                    }
                    return true
                }
            }
        }

        // Fallback: deliver to the client directly
        clientState.receiveBuffer.append(data)
        return true
    }

    public func receive(socketID: UInt64, length: Int) -> Data? {
        guard case .tcp(let state) = sockets[socketID] else { return nil }
        guard !state.receiveBuffer.isEmpty else { return nil }

        let count = length > 0 ? min(length, state.receiveBuffer.count) : state.receiveBuffer.count
        let data = Data(state.receiveBuffer.prefix(count))
        state.receiveBuffer.removeFirst(count)
        return data
    }

    public func receiveFromClient(serverID: UInt64, clientID: UInt64, length: Int) -> Data? {
        guard case .tcp(let clientState) = sockets[clientID] else { return nil }
        guard !clientState.receiveBuffer.isEmpty else { return nil }

        let count = length > 0 ? min(length, clientState.receiveBuffer.count) : clientState.receiveBuffer.count
        let data = Data(clientState.receiveBuffer.prefix(count))
        clientState.receiveBuffer.removeFirst(count)
        return data
    }

    public func receiveUntilDelimiter(socketID: UInt64, delimiter: Data) -> Data? {
        guard case .tcp(let state) = sockets[socketID] else { return nil }
        guard let range = state.receiveBuffer.range(of: delimiter) else { return nil }

        let endIndex = range.upperBound
        let chunk = Data(state.receiveBuffer.prefix(upTo: endIndex))
        state.receiveBuffer.removeSubrange(state.receiveBuffer.startIndex..<endIndex)
        return chunk
    }

    public func receiveFromClientUntilDelimiter(serverID: UInt64, clientID: UInt64, delimiter: Data) -> Data? {
        guard case .tcp(let clientState) = sockets[clientID] else { return nil }
        guard let range = clientState.receiveBuffer.range(of: delimiter) else { return nil }

        let endIndex = range.upperBound
        let chunk = Data(clientState.receiveBuffer.prefix(upTo: endIndex))
        clientState.receiveBuffer.removeSubrange(clientState.receiveBuffer.startIndex..<endIndex)
        return chunk
    }

    // MARK: - TCP Server Clients

    public func connectedClients(serverID: UInt64) -> [UInt64] {
        guard case .tcp(let state) = sockets[serverID] else { return [] }
        return state.connectedClientIDs
    }

    // MARK: - Close / Disconnect

    public func close(socketID: UInt64) -> Bool {
        guard let socketState = sockets[socketID] else { return false }

        switch socketState {
        case .tcp(let state):
            // If server, clean up all clients and propagate disconnect to originals
            if state.isListening {
                for clientID in state.connectedClientIDs {
                    // Propagate disconnect to the original connecting client
                    if let origClientID = clientOnServerToOriginal[clientID],
                       case .tcp(let origState) = sockets[origClientID] {
                        origState.isConnected = false
                        origState.remoteHost = nil
                        origState.remotePort = nil
                        origState.localPort = 0
                        origState.localHost = ""
                    }
                    clientOnServerToOriginal.removeValue(forKey: clientID)
                    if case .tcp(let clientState) = sockets[clientID] {
                        clientState.isConnected = false
                    }
                    sockets.removeValue(forKey: clientID)
                }
                state.connectedClientIDs.removeAll()

                if let port = serverPorts[socketID] {
                    portToServer.removeValue(forKey: port)
                }
                serverPorts.removeValue(forKey: socketID)

                if let path = state.unixPath {
                    unixPathToServer.removeValue(forKey: path)
                }
            }

            state.isConnected = false
            state.isListening = false
            state.localPort = 0
            state.localHost = ""
            state.remoteHost = nil
            state.remotePort = nil
            state.unixPath = nil
            state.role = "DEFAULT"
            state.connectedClientIDs.removeAll()
            state.receiveBuffer.removeAll()
            state.isIPv4 = false
            state.isIPv6 = false

        case .udp(let state):
            // Remove from port listeners
            if state.isBound {
                udpPortListeners[state.localPort]?.removeAll(where: { $0 == socketID })
                if udpPortListeners[state.localPort]?.isEmpty == true {
                    udpPortListeners.removeValue(forKey: state.localPort)
                }
            }
            // Remove from connected socket map
            if state.isConnected {
                udpConnectedByLocalPort.removeValue(forKey: state.localPort)
            }
            state.isBound = false
            state.isConnected = false
            state.isClosed = true
            state.localPort = 0
            state.localHost = ""
            state.connectedHost = nil
            state.connectedPort = 0
            state.role = "DEFAULT"
            state.receiveBuffer.removeAll()
            state.receiveActive = false
            state.continuousReceive = false
        }

        return true
    }

    // MARK: - Callback

    public func setCallback(socketID: UInt64, callback: @escaping (SocketEvent) -> Void) -> Bool {
        guard let socketState = sockets[socketID] else { return false }
        switch socketState {
        case .tcp(let state): state.callback = callback
        case .udp(let state): state.callback = callback
        }
        return true
    }

    // MARK: - Info

    public func socketInfo(socketID: UInt64) -> SocketHandle? {
        guard let socketState = sockets[socketID] else { return nil }

        switch socketState {
        case .tcp(let state):
            return SocketHandle(
                id: socketID, type: .tcp,
                localHost: state.localHost, localPort: state.localPort,
                remoteHost: state.remoteHost, remotePort: state.remotePort,
                isConnected: state.isConnected, isListening: state.isListening
            )
        case .udp(let state):
            return SocketHandle(
                id: socketID, type: .udp,
                localHost: state.localHost, localPort: state.localPort,
                remoteHost: state.connectedHost, remotePort: state.connectedPort > 0 ? state.connectedPort : nil,
                isConnected: state.isConnected, isListening: state.isBound
            )
        }
    }

    // MARK: - UDP Operations

    public func sendTo(socketID: UInt64, data: Data, host: String, port: UInt16) -> Bool {
        guard case .udp(let state) = sockets[socketID] else { return false }

        if rng.boolean(probability: faults.packetDropProbability) {
            return false
        }

        // Ensure socket is "open" after sending
        state.isClosed = false

        sentData.append((socketID: socketID, data: data, host: host, port: port))

        // Route to all listening UDP sockets on this port
        routeUDPData(fromSocket: socketID, data: data, toPort: port, fromHost: host)
        return true
    }

    public func udpBind(socketID: UInt64, port: UInt16) -> Bool {
        guard case .udp(let state) = sockets[socketID] else { return false }

        // Check port conflict (unless reusePort)
        if !state.reusePortEnabled {
            if let listeners = udpPortListeners[port], !listeners.isEmpty {
                // Check if any existing listener also doesn't have reusePort
                for lid in listeners {
                    if case .udp(let ls) = sockets[lid], !ls.reusePortEnabled {
                        return false
                    }
                }
            }
        }

        state.isBound = true
        state.isClosed = false
        state.localHost = "0.0.0.0"
        state.localPort = port

        udpPortListeners[port, default: []].append(socketID)
        return true
    }

    public func udpSetBroadcast(socketID: UInt64, enabled: Bool) {
        guard case .udp(let state) = sockets[socketID] else { return }
        state.broadcastEnabled = enabled
    }

    public func udpSetReusePort(socketID: UInt64, enabled: Bool) {
        guard case .udp(let state) = sockets[socketID] else { return }
        state.reusePortEnabled = enabled
    }

    public func udpSetIPv4Enabled(socketID: UInt64, enabled: Bool) {
        guard case .udp(let state) = sockets[socketID] else { return }
        state.ipv4Enabled = enabled
    }

    public func udpSetIPv6Enabled(socketID: UInt64, enabled: Bool) {
        guard case .udp(let state) = sockets[socketID] else { return }
        state.ipv6Enabled = enabled
    }

    public func udpSetPreferredIPVersion(socketID: UInt64, version: Int) {
        guard case .udp(let state) = sockets[socketID] else { return }
        state.preferredIPVersion = version
    }

    public func udpSetBufferSize(socketID: UInt64, size: UInt64, ipVersion: Int?) {
        guard case .udp(let state) = sockets[socketID] else { return }
        let ipv4Size = size > UInt64(UInt16.max) ? UInt16.max : UInt16(size)
        let ipv6Size = size > UInt64(UInt32.max) ? UInt32.max : UInt32(size)

        if let v = ipVersion {
            if v == 4 { state.maxRecvIPv4Buffer = ipv4Size }
            else if v == 6 { state.maxRecvIPv6Buffer = ipv6Size }
        } else {
            state.maxRecvIPv4Buffer = ipv4Size
            state.maxRecvIPv6Buffer = ipv6Size
        }
    }

    public func udpBeginReceiving(socketID: UInt64, continuous: Bool) -> Bool {
        guard case .udp(let state) = sockets[socketID] else { return false }
        // Allow receiving on sockets that have sent data (localPort > 0) even
        // if not explicitly bound or connected -- matches real POSIX sendto behavior.
        guard state.isBound || state.isConnected || state.localPort > 0 else { return false }

        state.continuousReceive = continuous
        state.receiveActive = true

        // Deliver any buffered data
        deliverBufferedUDPData(socketID: socketID)
        return true
    }

    // MARK: - HTTP Server

    public func startHTTPServer(port: UInt16) -> UInt64? {
        if rng.boolean(probability: faults.connectionFailProbability) { return nil }
        let id = nextSocketID
        nextSocketID += 1
        httpServers[id] = port
        httpServerRequestCount[id] = 0
        let state = TCPSocketState()
        state.localPort = port
        state.localHost = "0.0.0.0"
        state.isListening = true
        state.role = "SERVER"
        sockets[id] = .tcp(state)
        portToServer[port] = id
        return id
    }

    public func stopHTTPServer(serverID: UInt64) -> Bool {
        guard httpServers.removeValue(forKey: serverID) != nil else { return false }
        httpServerRequestCount.removeValue(forKey: serverID)
        if let port = serverPorts[serverID] ?? httpServers[serverID] {
            portToServer.removeValue(forKey: port)
        }
        sockets.removeValue(forKey: serverID)
        return true
    }

    // MARK: - Extended info for TCP sockets

    /// Get the TCP state's role string.
    public func tcpRole(socketID: UInt64) -> String {
        guard case .tcp(let state) = sockets[socketID] else { return "DEFAULT" }
        return state.role
    }

    /// Get the TCP state's unix path.
    public func tcpUnixPath(socketID: UInt64) -> String? {
        guard case .tcp(let state) = sockets[socketID] else { return nil }
        return state.unixPath
    }

    /// Check if TCP socket is a server with connected clients.
    public func tcpIsServer(socketID: UInt64) -> Bool {
        guard case .tcp(let state) = sockets[socketID] else { return false }
        return state.isListening || state.role == "SERVER"
    }

    /// Get TCP connection count (for server: number of clients, for client: 0 or 1).
    public func tcpConnectionCount(socketID: UInt64) -> Int {
        guard case .tcp(let state) = sockets[socketID] else { return 0 }
        if state.isListening || state.role == "SERVER" {
            return state.connectedClientIDs.count
        }
        return state.isConnected ? 1 : 0
    }

    /// Whether the TCP socket is "disconnected" (no listener and not connected).
    public func tcpIsDisconnected(socketID: UInt64) -> Bool {
        guard case .tcp(let state) = sockets[socketID] else { return true }
        if state.isListening { return false }
        if state.unixPath != nil && state.role == "SERVER" { return false }
        return !state.isConnected
    }

    /// TCP IPv4/IPv6 flags.
    public func tcpIPFlags(socketID: UInt64) -> (isIPv4: Bool, isIPv6: Bool) {
        guard case .tcp(let state) = sockets[socketID] else { return (false, false) }
        return (state.isIPv4, state.isIPv6)
    }

    // MARK: - Extended info for UDP sockets

    /// Get UDP state details for the info table.
    public func udpInfo(socketID: UInt64) -> (
        connectedHost: String?, connectedPort: UInt16,
        isClosed: Bool, isConnected: Bool,
        isIPv4: Bool, isIPv6: Bool,
        ipv4Enabled: Bool, ipv6Enabled: Bool,
        ipv4Preferred: Bool, ipv6Preferred: Bool, ipVersionNeutral: Bool,
        localHost: String?, localPort: UInt16,
        maxRecvIPv4: UInt16, maxRecvIPv6: UInt32,
        role: String
    )? {
        guard case .udp(let state) = sockets[socketID] else { return nil }

        let isIPv4 = state.isConnected ? (state.preferredIPVersion != 6) : (state.ipv4Enabled && !state.ipv6Enabled)
        let isIPv6 = state.isConnected ? (state.preferredIPVersion == 6) : (!state.ipv4Enabled && state.ipv6Enabled)

        return (
            connectedHost: state.connectedHost,
            connectedPort: state.connectedPort,
            isClosed: state.isClosed,
            isConnected: state.isConnected,
            isIPv4: isIPv4,
            isIPv6: isIPv6,
            ipv4Enabled: state.ipv4Enabled,
            ipv6Enabled: state.ipv6Enabled,
            ipv4Preferred: state.preferredIPVersion == 4,
            ipv6Preferred: state.preferredIPVersion == 6,
            ipVersionNeutral: state.preferredIPVersion == 0,
            localHost: state.localHost.isEmpty ? nil : state.localHost,
            localPort: state.localPort,
            maxRecvIPv4: state.maxRecvIPv4Buffer,
            maxRecvIPv6: state.maxRecvIPv6Buffer,
            role: state.role
        )
    }

    // MARK: - UDP Connect

    public func udpConnect(socketID: UInt64, host: String, port: UInt16) -> Bool {
        guard case .udp(let state) = sockets[socketID] else { return false }
        guard !state.isConnected else { return false }
        guard port > 0 else { return false }

        state.connectedHost = host
        state.connectedPort = port
        state.isConnected = true
        state.isClosed = false
        state.localHost = "127.0.0.1"
        state.localPort = UInt16(20000 + (socketID % 40000))
        // Register so routeUDPData can deliver to this connected socket
        udpConnectedByLocalPort[state.localPort] = socketID

        simRunLoopDispatch {
            state.callback?(.connected)
        }
        return true
    }

    // MARK: - Test Helpers

    /// Enqueue data to be received by a TCP socket on the next read.
    public func enqueueReceiveData(_ data: Data, forSocketID socketID: UInt64) {
        if case .tcp(let state) = sockets[socketID] {
            state.receiveBuffer.append(data)
        }
    }

    /// Enqueue UDP receive data.
    public func enqueueUDPReceiveData(_ data: Data, address: Data, forSocketID socketID: UInt64) {
        if case .udp(let state) = sockets[socketID] {
            state.receiveBuffer.append((data: data, address: address))
        }
    }

    /// Simulate an HTTP request arriving at a server.
    public func simulateHTTPRequest(serverID: UInt64) {
        httpServerRequestCount[serverID, default: 0] += 1
    }

    /// Get total HTTP request count across all servers.
    public func totalHTTPRequestCount() -> Int {
        httpServerRequestCount.values.reduce(0, +)
    }

    // MARK: - Private helpers

    /// Route TCP data from one connected socket to its peer.
    private func routeTCPData(fromSocket socketID: UInt64, data: Data) {
        guard case .tcp(let senderState) = sockets[socketID] else { return }

        // If sender is a connected client, route to the server's client-side socket
        // Try port-based lookup first, then Unix path lookup
        var serverID: UInt64?
        if let remotePort = senderState.remotePort {
            serverID = portToServer[remotePort]
        }
        if serverID == nil, let path = senderState.unixPath {
            serverID = unixPathToServer[path]
        }

        guard let serverID = serverID,
              case .tcp(let serverState) = sockets[serverID] else { return }
        // Find the client-on-server socket for this connection
        for clientID in serverState.connectedClientIDs {
            if case .tcp(let clientState) = sockets[clientID] {
                clientState.receiveBuffer.append(data)
                // Fire the SERVER socket's data callback (the server owns the callback)
                simRunLoopDispatch {
                    serverState.callback?(.data(data))
                }
                return
            }
        }
    }

    /// Route UDP data to all listening sockets on the target port.
    private func routeUDPData(fromSocket socketID: UInt64, data: Data, toPort port: UInt16, fromHost host: String) {
        guard case .udp(let senderState) = sockets[socketID] else { return }

        // Build a sender address for the callback
        let senderPort = senderState.localPort > 0 ? senderState.localPort : UInt16(30000 + (socketID % 30000))
        if senderState.localPort == 0 {
            senderState.localPort = senderPort
            senderState.localHost = "127.0.0.1"
            senderState.isClosed = false
            // Register in connected-by-local-port so data can be routed back
            udpConnectedByLocalPort[senderPort] = socketID
        }

        let senderPreferIPv6 = senderState.preferredIPVersion == 6

        // Determine if this is a broadcast
        let isBroadcast = host == "255.255.255.255" || host == "0.0.0.0"

        // Deliver to bound listeners on this port
        let listeners = udpPortListeners[port] ?? []
        for listenerID in listeners {
            guard listenerID != socketID else { continue }
            guard case .udp(let listenerState) = sockets[listenerID] else { continue }

            // Determine which IP version this listener will see the data as.
            // On a real POSIX stack with reusePort, a broadcast to 255.255.255.255
            // arrives on the fd4 socket (IPv4). An IPv6-only listener sees it on fd6
            // if the OS maps it, but the address family is determined by which fd
            // actually received the packet. For simulation: if the listener only
            // has IPv6 enabled, report the sender as IPv6; otherwise IPv4.
            let listenerSeesIPv6: Bool
            if isBroadcast {
                // Broadcast: deliver to all listeners regardless of IP version.
                // Listener address family is based on what the listener has enabled.
                listenerSeesIPv6 = !listenerState.ipv4Enabled && listenerState.ipv6Enabled
            } else {
                // Non-broadcast: respect IP version filtering
                if senderPreferIPv6 && !listenerState.ipv6Enabled { continue }
                if !senderPreferIPv6 && !listenerState.ipv4Enabled { continue }
                listenerSeesIPv6 = senderPreferIPv6
            }

            let senderAddress = buildSockaddr(host: listenerSeesIPv6 ? "::1" : "127.0.0.1", port: senderPort, ipv6: listenerSeesIPv6)

            // Check buffer size: truncate data based on receiver's buffer setting
            let maxBuf = listenerSeesIPv6 ? Int(listenerState.maxRecvIPv6Buffer) : Int(listenerState.maxRecvIPv4Buffer)
            if maxBuf == 0 { continue }
            let deliverData = data.count > maxBuf ? Data(data.prefix(maxBuf)) : data

            if listenerState.receiveActive {
                simRunLoopDispatch {
                    listenerState.callback?(.dataWithAddress(deliverData, senderAddress))
                }
                if !listenerState.continuousReceive {
                    listenerState.receiveActive = false
                }
            } else {
                listenerState.receiveBuffer.append((data: deliverData, address: senderAddress))
            }
        }

        // Also deliver to connected UDP sockets listening on this port
        if let connectedID = udpConnectedByLocalPort[port], connectedID != socketID,
           case .udp(let connState) = sockets[connectedID] {
            let senderAddress = buildSockaddr(host: senderPreferIPv6 ? "::1" : "127.0.0.1", port: senderPort, ipv6: senderPreferIPv6)
            let maxBuf = senderPreferIPv6 ? Int(connState.maxRecvIPv6Buffer) : Int(connState.maxRecvIPv4Buffer)
            let deliverData = (maxBuf > 0 && data.count > maxBuf) ? Data(data.prefix(maxBuf)) : data
            if connState.receiveActive {
                simRunLoopDispatch {
                    connState.callback?(.dataWithAddress(deliverData, senderAddress))
                }
                if !connState.continuousReceive {
                    connState.receiveActive = false
                }
            } else {
                connState.receiveBuffer.append((data: deliverData, address: senderAddress))
            }
        }
    }

    private func deliverBufferedUDPData(socketID: UInt64) {
        guard case .udp(let state) = sockets[socketID] else { return }
        guard state.receiveActive else { return }

        while !state.receiveBuffer.isEmpty && state.receiveActive {
            let entry = state.receiveBuffer.removeFirst()
            simRunLoopDispatch {
                state.callback?(.dataWithAddress(entry.data, entry.address))
            }
            if !state.continuousReceive {
                state.receiveActive = false
            }
        }
    }

    /// Build a binary sockaddr structure for callback delivery.
    private func buildSockaddr(host: String, port: UInt16, ipv6: Bool) -> Data {
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            inet_pton(AF_INET6, host, &addr.sin6_addr)
            return withUnsafePointer(to: &addr) { ptr in
                Data(bytes: ptr, count: MemoryLayout<sockaddr_in6>.size)
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            return withUnsafePointer(to: &addr) { ptr in
                Data(bytes: ptr, count: MemoryLayout<sockaddr_in>.size)
            }
        }
    }
}
