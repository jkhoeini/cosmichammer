import Foundation
import HSDSTCore
import Network

final class ProductionSocket: SocketProtocol {
    private var nextID: UInt64 = 1
    private var sockets: [UInt64: SocketState] = [:]
    private var servers: [UInt64: NWListener] = [:]

    private class SocketState {
        let type: SocketType
        var connection: NWConnection?
        var listener: NWListener?
        var callback: ((SocketEvent) -> Void)?
        var localHost: String = "0.0.0.0"
        var localPort: UInt16 = 0
        var remoteHost: String?
        var remotePort: UInt16?
        var isConnected: Bool = false
        var isListening: Bool = false
        var receivedData: Data = Data()

        init(type: SocketType) {
            self.type = type
        }
    }

    func createTCPSocket() -> UInt64 {
        let id = nextID
        nextID += 1
        sockets[id] = SocketState(type: .tcp)
        return id
    }

    func createUDPSocket() -> UInt64 {
        let id = nextID
        nextID += 1
        sockets[id] = SocketState(type: .udp)
        return id
    }

    func connect(socketID: UInt64, host: String, port: UInt16) -> Bool {
        guard let state = sockets[socketID] else { return false }

        let params: NWParameters
        switch state.type {
        case .tcp:
            params = NWParameters.tcp
        case .udp:
            params = NWParameters.udp
        }

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)

        state.connection = connection
        state.remoteHost = host
        state.remotePort = port

        connection.stateUpdateHandler = { [weak state] newState in
            guard let state = state else { return }
            switch newState {
            case .ready:
                state.isConnected = true
                state.callback?(.connected)
            case .failed(let error):
                state.isConnected = false
                state.callback?(.error(error.localizedDescription))
            case .cancelled:
                state.isConnected = false
                state.callback?(.disconnected)
            default:
                break
            }
        }

        connection.start(queue: .main)
        return true
    }

    func listen(socketID: UInt64, port: UInt16) -> Bool {
        guard let state = sockets[socketID] else { return false }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        let params: NWParameters
        switch state.type {
        case .tcp: params = NWParameters.tcp
        case .udp: params = NWParameters.udp
        }

        do {
            let listener = try NWListener(using: params, on: nwPort)
            state.listener = listener
            state.localPort = port
            state.isListening = true

            listener.newConnectionHandler = { [weak state] newConnection in
                guard let state = state else { return }
                state.connection = newConnection
                state.isConnected = true
                state.callback?(.connected)
                self.setupReceive(state: state)
                newConnection.start(queue: .main)
            }

            listener.stateUpdateHandler = { [weak state] newState in
                guard let state = state else { return }
                if case .failed(let error) = newState {
                    state.isListening = false
                    state.callback?(.error(error.localizedDescription))
                }
            }

            listener.start(queue: .main)
            return true
        } catch {
            return false
        }
    }

    func send(socketID: UInt64, data: Data) -> Bool {
        guard let state = sockets[socketID],
              let connection = state.connection
        else { return false }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                state.callback?(.error(error.localizedDescription))
            }
        })
        return true
    }

    func sendTo(socketID: UInt64, data: Data, host: String, port: UInt16) -> Bool {
        guard let state = sockets[socketID] else { return false }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        // For UDP, create a connection to the target
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .udp)

        connection.stateUpdateHandler = { [weak state] newState in
            if case .ready = newState {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        state?.callback?(.error(error.localizedDescription))
                    }
                    connection.cancel()
                })
            }
        }
        connection.start(queue: .main)
        return true
    }

    func receive(socketID: UInt64, length: Int) -> Data? {
        guard let state = sockets[socketID] else { return nil }
        if !state.receivedData.isEmpty {
            let count = min(length, state.receivedData.count)
            let data = state.receivedData.prefix(count)
            state.receivedData.removeFirst(count)
            return Data(data)
        }
        // Set up async receive if not already
        setupReceive(state: state)
        return nil
    }

    func close(socketID: UInt64) -> Bool {
        guard let state = sockets.removeValue(forKey: socketID) else { return false }
        state.connection?.cancel()
        state.listener?.cancel()
        state.isConnected = false
        state.isListening = false
        return true
    }

    func setCallback(socketID: UInt64,
                     callback: @escaping (SocketEvent) -> Void) -> Bool
    {
        guard let state = sockets[socketID] else { return false }
        state.callback = callback
        return true
    }

    func socketInfo(socketID: UInt64) -> SocketHandle? {
        guard let state = sockets[socketID] else { return nil }
        return SocketHandle(
            id: socketID, type: state.type,
            localHost: state.localHost, localPort: state.localPort,
            remoteHost: state.remoteHost, remotePort: state.remotePort,
            isConnected: state.isConnected, isListening: state.isListening
        )
    }

    func startHTTPServer(port: UInt16) -> UInt64? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            let id = nextID
            nextID += 1

            listener.newConnectionHandler = { newConnection in
                newConnection.start(queue: .main)
            }
            listener.start(queue: .main)
            servers[id] = listener
            return id
        } catch {
            return nil
        }
    }

    func stopHTTPServer(serverID: UInt64) -> Bool {
        guard let listener = servers.removeValue(forKey: serverID) else { return false }
        listener.cancel()
        return true
    }

    // MARK: - Private

    private func setupReceive(state: SocketState) {
        guard let connection = state.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak state] content, _, isComplete, error in
            guard let state = state else { return }
            if let data = content, !data.isEmpty {
                state.receivedData.append(data)
                state.callback?(.data(data))
            }
            if isComplete {
                state.isConnected = false
                state.callback?(.disconnected)
            } else if let error = error {
                state.callback?(.error(error.localizedDescription))
            } else {
                // Continue receiving
                self.setupReceive(state: state)
            }
        }
    }
}
