import Foundation
import HSDSTCore

public final class SimulatedSocket: SocketProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var sockets: [UInt64: SocketHandle] = [:]
    public var pendingData: [UInt64: [Data]] = [:]
    public var sentData: [(socketID: UInt64, data: Data, host: String?, port: UInt16?)] = []

    private var nextSocketID: UInt64 = 1
    private var callbacks: [UInt64: (SocketEvent) -> Void] = [:]
    private var httpServers: [UInt64: UInt16] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Socket Creation

    public func createTCPSocket() -> UInt64 {
        let id = nextSocketID
        nextSocketID += 1
        sockets[id] = SocketHandle(id: id, type: .tcp)
        return id
    }

    public func createUDPSocket() -> UInt64 {
        let id = nextSocketID
        nextSocketID += 1
        sockets[id] = SocketHandle(id: id, type: .udp)
        return id
    }

    // MARK: - Connection

    public func connect(socketID: UInt64, host: String, port: UInt16) -> Bool {
        guard var handle = sockets[socketID] else { return false }
        if rng.boolean(probability: faults.connectionFailProbability) {
            callbacks[socketID]?(.error("Connection failed (simulated)"))
            return false
        }
        handle.remoteHost = host
        handle.remotePort = port
        handle.isConnected = true
        sockets[socketID] = handle
        callbacks[socketID]?(.connected)
        return true
    }

    public func listen(socketID: UInt64, port: UInt16) -> Bool {
        guard var handle = sockets[socketID] else { return false }
        if rng.boolean(probability: faults.connectionFailProbability) {
            callbacks[socketID]?(.error("Listen failed (simulated)"))
            return false
        }
        handle.localPort = port
        handle.isListening = true
        sockets[socketID] = handle
        return true
    }

    // MARK: - Data Transfer

    public func send(socketID: UInt64, data: Data) -> Bool {
        guard let handle = sockets[socketID], handle.isConnected else { return false }
        if rng.boolean(probability: faults.packetDropProbability) {
            callbacks[socketID]?(.error("Packet dropped (simulated)"))
            return false
        }
        sentData.append((socketID: socketID, data: data, host: handle.remoteHost, port: handle.remotePort))
        return true
    }

    public func sendTo(socketID: UInt64, data: Data, host: String, port: UInt16) -> Bool {
        guard sockets[socketID] != nil else { return false }
        if rng.boolean(probability: faults.packetDropProbability) {
            callbacks[socketID]?(.error("Packet dropped (simulated)"))
            return false
        }
        sentData.append((socketID: socketID, data: data, host: host, port: port))
        return true
    }

    public func receive(socketID: UInt64, length: Int) -> Data? {
        guard sockets[socketID] != nil else { return nil }
        guard var queue = pendingData[socketID], !queue.isEmpty else { return nil }
        let data = queue.removeFirst()
        pendingData[socketID] = queue.isEmpty ? nil : queue
        let result = length > 0 && data.count > length ? data.prefix(length) : data
        return Data(result)
    }

    // MARK: - Lifecycle

    public func close(socketID: UInt64) -> Bool {
        guard var handle = sockets[socketID] else { return false }
        handle.isConnected = false
        handle.isListening = false
        sockets[socketID] = handle
        callbacks[socketID]?(.disconnected)
        callbacks.removeValue(forKey: socketID)
        sockets.removeValue(forKey: socketID)
        pendingData.removeValue(forKey: socketID)
        return true
    }

    // MARK: - Callback

    public func setCallback(socketID: UInt64, callback: @escaping (SocketEvent) -> Void) -> Bool {
        guard sockets[socketID] != nil else { return false }
        callbacks[socketID] = callback
        return true
    }

    // MARK: - Info

    public func socketInfo(socketID: UInt64) -> SocketHandle? {
        sockets[socketID]
    }

    // MARK: - HTTP Server

    public func startHTTPServer(port: UInt16) -> UInt64? {
        if rng.boolean(probability: faults.connectionFailProbability) { return nil }
        let id = nextSocketID
        nextSocketID += 1
        httpServers[id] = port
        var handle = SocketHandle(id: id, type: .tcp, localPort: port, isListening: true)
        handle.localHost = "0.0.0.0"
        sockets[id] = handle
        return id
    }

    public func stopHTTPServer(serverID: UInt64) -> Bool {
        guard httpServers.removeValue(forKey: serverID) != nil else { return false }
        sockets.removeValue(forKey: serverID)
        callbacks.removeValue(forKey: serverID)
        return true
    }

    // MARK: - Test Helpers

    /// Enqueue data that a subsequent `receive` call will return for the given socket.
    public func enqueueReceiveData(_ data: Data, forSocketID socketID: UInt64) {
        pendingData[socketID, default: []].append(data)
    }

    /// Simulate an incoming event delivered to the socket's callback.
    public func deliverEvent(_ event: SocketEvent, toSocketID socketID: UInt64) {
        callbacks[socketID]?(event)
    }
}
