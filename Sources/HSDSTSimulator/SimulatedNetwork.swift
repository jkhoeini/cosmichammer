import Foundation
import HSDSTCore

public final class SimulatedNetwork: NetworkProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig
    private let clock: SimulatedClock

    public var httpResponses: [String: HTTPResponse] = [:]
    public var defaultHTTPResponse = HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: "OK".data(using: .utf8))

    public init(rng: RPRNG, faults: FaultConfig, clock: SimulatedClock) {
        self.rng = rng
        self.faults = faults
        self.clock = clock
    }

    public func httpRequest(url: String, method: String, headers: [String: String],
                            body: Data?, redirect: Bool,
                            completion: @escaping (HTTPResponse?, Error?) -> Void) {
        if rng.boolean(probability: faults.httpTimeoutProbability) {
            completion(nil, SimulatedError.timeout("HTTP request timed out (simulated)"))
            return
        }
        if rng.boolean(probability: faults.connectionFailProbability) {
            completion(nil, SimulatedError.connectionFailed("Connection failed (simulated)"))
            return
        }
        let response = httpResponses[url] ?? defaultHTTPResponse
        completion(response, nil)
    }

    public func createTCPConnection(host: String, port: UInt16,
                                    connected: @escaping (Error?) -> Void) -> any TCPConnectionHandle {
        let conn = SimulatedTCPConnection(rng: rng.fork(), faults: faults)
        if rng.boolean(probability: faults.connectionFailProbability) {
            connected(SimulatedError.connectionFailed("TCP connection failed (simulated)"))
        } else {
            conn._isConnected = true
            connected(nil)
        }
        return conn
    }

    public func createUDPSocket() -> any UDPSocketHandle {
        SimulatedUDPSocket(rng: rng.fork(), faults: faults)
    }

    public func createTCPListener(port: UInt16,
                                  onNewConnection: @escaping (any TCPConnectionHandle) -> Void) throws -> any ListenerHandle {
        SimulatedListener(port: port, onNewConnection: onNewConnection)
    }
}

final class SimulatedTCPConnection: TCPConnectionHandle {
    private var rng: RPRNG
    private let faults: FaultConfig
    var _isConnected = false
    var receiveBuffer: [Data] = []

    init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    var isConnected: Bool { _isConnected }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        if rng.boolean(probability: faults.packetDropProbability) {
            completion(SimulatedError.connectionFailed("Packet dropped (simulated)"))
            return
        }
        completion(nil)
    }

    func receive(minimumLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Error?) -> Void) {
        if let data = receiveBuffer.first {
            receiveBuffer.removeFirst()
            completion(data, nil)
        } else {
            completion(nil, nil)
        }
    }

    func cancel() { _isConnected = false }

    public func enqueue(_ data: Data) {
        receiveBuffer.append(data)
    }
}

final class SimulatedUDPSocket: UDPSocketHandle {
    private var rng: RPRNG
    private let faults: FaultConfig
    private var boundPort: UInt16 = 0
    var receiveBuffer: [(data: Data, host: String, port: UInt16)] = []

    init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    func send(_ data: Data, toHost host: String, port: UInt16, completion: @escaping (Error?) -> Void) {
        if rng.boolean(probability: faults.packetDropProbability) {
            completion(SimulatedError.connectionFailed("UDP packet dropped (simulated)"))
            return
        }
        completion(nil)
    }

    func receive(completion: @escaping (Data?, String?, UInt16, Error?) -> Void) {
        if let entry = receiveBuffer.first {
            receiveBuffer.removeFirst()
            completion(entry.data, entry.host, entry.port, nil)
        } else {
            completion(nil, nil, 0, nil)
        }
    }

    func bind(port: UInt16) throws { boundPort = port }
    func close() { boundPort = 0 }
}

final class SimulatedListener: ListenerHandle {
    let port: UInt16
    let onNewConnection: (any TCPConnectionHandle) -> Void

    init(port: UInt16, onNewConnection: @escaping (any TCPConnectionHandle) -> Void) {
        self.port = port
        self.onNewConnection = onNewConnection
    }

    func cancel() {}
}
