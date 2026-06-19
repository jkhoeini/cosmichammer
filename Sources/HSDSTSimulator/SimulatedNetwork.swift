import Foundation
import HSDSTCore

public final class SimulatedNetwork: NetworkProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig
    private let clock: SimulatedClock

    public var httpResponses: [String: HTTPResponse] = [:]
    public var defaultHTTPResponse = HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: "OK".data(using: .utf8))

    // MARK: - Reachability state

    /// Per-host reachability flags. Key is hostname or IP string.
    /// Value is SCNetworkReachabilityFlags raw value (UInt32).
    /// Default: all hosts are reachable (flags = 2, i.e. kSCNetworkReachabilityFlagsReachable).
    public var reachabilityFlags: [String: UInt32] = [:]

    /// Default reachability flags for hosts not in `reachabilityFlags`.
    /// 2 = kSCNetworkReachabilityFlagsReachable.
    public var defaultReachabilityFlags: UInt32 = 2

    private var nextListenerID: UInt64 = 1
    private var reachabilityCallbacks: [UInt64: (host: String, callback: (UInt32) -> Void)] = [:]

    // MARK: - Active listeners tracking

    private var activeListeners: [UInt16: SimulatedListener] = [:]

    // MARK: - Connection tracking

    /// All TCP connections created through this simulator, for test inspection.
    public private(set) var createdConnections: [SimulatedTCPConnection] = []

    public init(rng: RPRNG, faults: FaultConfig, clock: SimulatedClock) {
        self.rng = rng
        self.faults = faults
        self.clock = clock
    }

    // MARK: - NetworkProtocol

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
        var response = httpResponses[url] ?? defaultHTTPResponse
        // Follow redirects when enabled: if the response is a 3xx with a Location
        // header, look up the redirect target in httpResponses.
        if redirect, (300...399).contains(response.statusCode),
           let location = response.headers["Location"] {
            response = httpResponses[location] ?? defaultHTTPResponse
        }
        completion(response, nil)
    }

    public func createTCPConnection(host: String, port: UInt16,
                                    connected: @escaping (Error?) -> Void) -> any TCPConnectionHandle {
        let conn = SimulatedTCPConnection(rng: rng.fork(), faults: faults, host: host, port: port)
        createdConnections.append(conn)
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
        let listener = SimulatedListener(port: port, onNewConnection: onNewConnection, network: self)
        activeListeners[port] = listener
        return listener
    }

    // MARK: - Reachability (test API)

    /// Register a callback that fires whenever reachability changes for the given host.
    /// Returns an ID for later removal.
    public func addReachabilityListener(host: String, callback: @escaping (UInt32) -> Void) -> UInt64 {
        let id = nextListenerID
        nextListenerID += 1
        reachabilityCallbacks[id] = (host: host, callback: callback)
        return id
    }

    /// Remove a previously registered reachability listener.
    @discardableResult
    public func removeReachabilityListener(id: UInt64) -> Bool {
        reachabilityCallbacks.removeValue(forKey: id) != nil
    }

    /// Get the current reachability flags for a host.
    public func getReachabilityFlags(host: String) -> UInt32 {
        reachabilityFlags[host] ?? defaultReachabilityFlags
    }

    /// Set reachability flags for a host, firing all matching callbacks.
    public func setReachabilityFlags(host: String, flags: UInt32) {
        let oldFlags = reachabilityFlags[host] ?? defaultReachabilityFlags
        reachabilityFlags[host] = flags
        if flags != oldFlags {
            notifyReachabilityCallbacks(host: host, flags: flags)
        }
    }

    /// Convenience: mark a host as unreachable (flags = 0), firing callbacks.
    public func setUnreachable(host: String) {
        setReachabilityFlags(host: host, flags: 0)
    }

    /// Convenience: mark a host as reachable (flags = 2), firing callbacks.
    public func setReachable(host: String) {
        setReachabilityFlags(host: host, flags: 2)
    }

    /// Change the default reachability flags and fire callbacks for all hosts
    /// that don't have explicit overrides.
    public func setDefaultReachabilityFlags(_ flags: UInt32) {
        let oldDefault = defaultReachabilityFlags
        defaultReachabilityFlags = flags
        if flags != oldDefault {
            // Fire callbacks for hosts that use the default (i.e. not in reachabilityFlags)
            var notifiedHosts = Set<String>()
            for (_, entry) in reachabilityCallbacks {
                if reachabilityFlags[entry.host] == nil && !notifiedHosts.contains(entry.host) {
                    notifiedHosts.insert(entry.host)
                    entry.callback(flags)
                }
            }
        }
    }

    // MARK: - Listener simulation (test API)

    /// Simulate an incoming TCP connection on a listener at the given port.
    /// Returns the simulated connection, or nil if no listener is active on that port.
    @discardableResult
    public func simulateIncomingConnection(port: UInt16) -> SimulatedTCPConnection? {
        guard let listener = activeListeners[port] else { return nil }
        let conn = SimulatedTCPConnection(rng: rng.fork(), faults: faults, host: "127.0.0.1", port: port)
        conn._isConnected = true
        createdConnections.append(conn)
        listener.onNewConnection(conn)
        return conn
    }

    /// Remove a listener from the active set (called by SimulatedListener.cancel()).
    func removeListener(port: UInt16) {
        activeListeners.removeValue(forKey: port)
    }

    // MARK: - Private

    private func notifyReachabilityCallbacks(host: String, flags: UInt32) {
        for (_, entry) in reachabilityCallbacks {
            if entry.host == host {
                entry.callback(flags)
            }
        }
    }
}

// MARK: - SimulatedTCPConnection

public final class SimulatedTCPConnection: TCPConnectionHandle {
    private var rng: RPRNG
    private let faults: FaultConfig
    var _isConnected = false
    var receiveBuffer: [Data] = []

    /// The host this connection is targeting, for test inspection.
    public let host: String
    /// The port this connection is targeting, for test inspection.
    public let port: UInt16
    /// Data that was sent through this connection, for test inspection.
    public private(set) var sentData: [Data] = []

    init(rng: RPRNG, faults: FaultConfig, host: String = "localhost", port: UInt16 = 0) {
        self.rng = rng
        self.faults = faults
        self.host = host
        self.port = port
    }

    public var isConnected: Bool { _isConnected }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard _isConnected else {
            completion(SimulatedError.connectionFailed("Not connected (simulated)"))
            return
        }
        if rng.boolean(probability: faults.packetDropProbability) {
            completion(SimulatedError.connectionFailed("Packet dropped (simulated)"))
            return
        }
        sentData.append(data)
        completion(nil)
    }

    public func receive(minimumLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Error?) -> Void) {
        if let data = receiveBuffer.first {
            receiveBuffer.removeFirst()
            completion(data, nil)
        } else {
            completion(nil, nil)
        }
    }

    public func cancel() { _isConnected = false }

    /// Enqueue data to be received by the next `receive` call.
    public func enqueue(_ data: Data) {
        receiveBuffer.append(data)
    }
}

// MARK: - SimulatedUDPSocket

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

// MARK: - SimulatedListener

final class SimulatedListener: ListenerHandle {
    let port: UInt16
    let onNewConnection: (any TCPConnectionHandle) -> Void
    private weak var network: SimulatedNetwork?

    init(port: UInt16, onNewConnection: @escaping (any TCPConnectionHandle) -> Void, network: SimulatedNetwork) {
        self.port = port
        self.onNewConnection = onNewConnection
        self.network = network
    }

    func cancel() {
        network?.removeListener(port: port)
    }
}
