import Foundation

public enum SocketType: Sendable {
    case tcp
    case udp
}

public enum SocketEvent: Sendable {
    case connected
    case disconnected
    case data(Data)
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
}
