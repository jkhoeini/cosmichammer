import Foundation

public enum SocketType: Sendable {
    case tcp
    case udp
}

public enum SocketEvent: Sendable {
    case connected
    case disconnected
    case data(Data)
    /// UDP data with sender address (used by simulated sockets to propagate sockaddr).
    case dataWithAddress(Data, Data)
    case error(String)
}

public struct SocketHandle: Sendable {
    public var id: UInt64
    public var type: SocketType
    public var localHost: String
    public var localPort: UInt16
    public var remoteHost: String?
    public var remotePort: UInt16?
    public var isConnected: Bool
    public var isListening: Bool

    public init(id: UInt64, type: SocketType, localHost: String = "0.0.0.0",
                localPort: UInt16 = 0, remoteHost: String? = nil,
                remotePort: UInt16? = nil, isConnected: Bool = false,
                isListening: Bool = false) {
        self.id = id
        self.type = type
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.isConnected = isConnected
        self.isListening = isListening
    }
}

public protocol SocketProtocol: AnyObject {
    func createTCPSocket() -> UInt64
    func createUDPSocket() -> UInt64
    func connect(socketID: UInt64, host: String, port: UInt16) -> Bool
    func listen(socketID: UInt64, port: UInt16) -> Bool
    func send(socketID: UInt64, data: Data) -> Bool
    func sendTo(socketID: UInt64, data: Data, host: String, port: UInt16) -> Bool
    func receive(socketID: UInt64, length: Int) -> Data?
    func close(socketID: UInt64) -> Bool
    func setCallback(socketID: UInt64, callback: @escaping (SocketEvent) -> Void) -> Bool
    func socketInfo(socketID: UInt64) -> SocketHandle?
    func startHTTPServer(port: UInt16) -> UInt64?
    func stopHTTPServer(serverID: UInt64) -> Bool

    // MARK: - TCP server accept (returns list of connected client IDs)
    func connectedClients(serverID: UInt64) -> [UInt64]

    // MARK: - TCP write to specific client
    func sendToClient(serverID: UInt64, clientID: UInt64, data: Data) -> Bool

    // MARK: - TCP receive from specific client
    func receiveFromClient(serverID: UInt64, clientID: UInt64, length: Int) -> Data?

    // MARK: - TCP delimiter-based receive
    func receiveUntilDelimiter(socketID: UInt64, delimiter: Data) -> Data?
    func receiveFromClientUntilDelimiter(serverID: UInt64, clientID: UInt64, delimiter: Data) -> Data?

    // MARK: - TCP Unix domain socket
    func connectUnix(socketID: UInt64, path: String) -> Bool
    func listenUnix(socketID: UInt64, path: String) -> Bool

    // MARK: - UDP configuration
    func udpBind(socketID: UInt64, port: UInt16) -> Bool
    func udpSetBroadcast(socketID: UInt64, enabled: Bool)
    func udpSetReusePort(socketID: UInt64, enabled: Bool)
    func udpSetIPv4Enabled(socketID: UInt64, enabled: Bool)
    func udpSetIPv6Enabled(socketID: UInt64, enabled: Bool)
    func udpSetPreferredIPVersion(socketID: UInt64, version: Int)
    func udpSetBufferSize(socketID: UInt64, size: UInt64, ipVersion: Int?)
    func udpBeginReceiving(socketID: UInt64, continuous: Bool) -> Bool

    /// Returns a managed TCP socket ID if this provider manages socket transport
    /// (e.g. simulated sockets). Returns nil if transport is managed externally
    /// (e.g. via NWConnection in production).
    func createManagedTCPSocket() -> UInt64?

    /// Returns a managed UDP socket ID if this provider manages socket transport.
    /// Returns nil if transport is managed externally.
    func createManagedUDPSocket() -> UInt64?
}

// Default implementations so existing conformances don't break
public extension SocketProtocol {
    func createManagedTCPSocket() -> UInt64? { nil }
    func createManagedUDPSocket() -> UInt64? { nil }

    func connectedClients(serverID: UInt64) -> [UInt64] { [] }
    func sendToClient(serverID: UInt64, clientID: UInt64, data: Data) -> Bool { false }
    func receiveFromClient(serverID: UInt64, clientID: UInt64, length: Int) -> Data? { nil }
    func receiveUntilDelimiter(socketID: UInt64, delimiter: Data) -> Data? { nil }
    func receiveFromClientUntilDelimiter(serverID: UInt64, clientID: UInt64, delimiter: Data) -> Data? { nil }
    func connectUnix(socketID: UInt64, path: String) -> Bool { false }
    func listenUnix(socketID: UInt64, path: String) -> Bool { false }
    func udpBind(socketID: UInt64, port: UInt16) -> Bool { false }
    func udpSetBroadcast(socketID: UInt64, enabled: Bool) {}
    func udpSetReusePort(socketID: UInt64, enabled: Bool) {}
    func udpSetIPv4Enabled(socketID: UInt64, enabled: Bool) {}
    func udpSetIPv6Enabled(socketID: UInt64, enabled: Bool) {}
    func udpSetPreferredIPVersion(socketID: UInt64, version: Int) {}
    func udpSetBufferSize(socketID: UInt64, size: UInt64, ipVersion: Int?) {}
    func udpBeginReceiving(socketID: UInt64, continuous: Bool) -> Bool { false }
}
