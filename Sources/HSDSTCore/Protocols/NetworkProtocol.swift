import Foundation

public struct HTTPResponse {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol TCPConnectionHandle: AnyObject {
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive(minimumLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Error?) -> Void)
    func cancel()
    var isConnected: Bool { get }
}

public protocol UDPSocketHandle: AnyObject {
    func send(_ data: Data, toHost host: String, port: UInt16, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Data?, String?, UInt16, Error?) -> Void)
    func bind(port: UInt16) throws
    func close()
}

public protocol ListenerHandle: AnyObject {
    func cancel()
    var port: UInt16 { get }
}

public protocol NetworkProtocol: AnyObject {
    func httpRequest(url: String, method: String, headers: [String: String],
                     body: Data?, redirect: Bool,
                     completion: @escaping (HTTPResponse?, Error?) -> Void)
    func createTCPConnection(host: String, port: UInt16,
                             connected: @escaping (Error?) -> Void) -> any TCPConnectionHandle
    func createUDPSocket() -> any UDPSocketHandle
    func createTCPListener(port: UInt16,
                           onNewConnection: @escaping (any TCPConnectionHandle) -> Void) throws -> any ListenerHandle
}
