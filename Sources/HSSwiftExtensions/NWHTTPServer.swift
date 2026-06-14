import Foundation
import Network
import Security
import os.log

// MARK: - Constants

/// Maximum number of concurrent HTTP server connections.  New connections
/// beyond this limit are immediately cancelled with an error log.
private let kMaxHTTPServerConnections = 1000

// MARK: - NWHTTPServer

/// A lightweight HTTP/1.1 server built on Network.framework's `NWListener`.
///
/// Replaces CocoaHTTPServer with a pure-Swift implementation that supports:
/// - Configurable request handling via a callback closure
/// - WebSocket upgrade (delegated to ``NWWebSocketServer``)
/// - HTTP Digest authentication (password-only, RFC 2617)
/// - Self-signed TLS via ``MYGetOrCreateAnonymousIdentity``
/// - Bonjour advertisement
/// - Interface binding
///
/// All work is dispatched on `DispatchQueue.main` to match the threading
/// model of the rest of Cosmic Hammer.
class NWHTTPServer {

    // MARK: - Public Types

    /// Request handler signature.
    ///
    /// Parameters: `(method, path, headers, body)`
    /// Returns:    `(responseBody, statusCode, responseHeaders)`
    typealias RequestHandler = (
        _ method: String,
        _ path: String,
        _ headers: [String: String],
        _ body: Data
    ) -> (Data, Int, [String: String])

    // MARK: - Public Properties

    /// TCP port to listen on.  `0` means the OS picks an available port.
    var port: UInt16 = 0

    /// Network interface name or IP to bind to.  `nil` listens on all interfaces.
    var interface: String?

    /// Bonjour service name.  `nil` disables Bonjour advertisement.
    var name: String?

    /// Digest-auth password.  `nil` disables authentication.
    var password: String?

    /// Maximum allowed request body size in bytes.  Requests exceeding this
    /// limit receive a 413 response.
    var maxBodySize: Int = 10_485_760 // 10 MB

    /// Whether the server is currently accepting connections.
    var isRunning: Bool { listener != nil }

    /// The closure invoked for each HTTP request that passes auth checks.
    var requestHandler: RequestHandler?

    /// Optional WebSocket endpoint.  If set, requests whose path matches
    /// and that carry an `Upgrade: websocket` header are handed off here.
    var webSocketHandler: NWWebSocketServer?

    /// When `true`, the listener uses TLS with a self-signed certificate
    /// obtained from ``MYGetOrCreateAnonymousIdentity``.
    var useSSL: Bool = false

    // MARK: - Private State

    private var listener: NWListener?
    private var connections: Set<NWConnectionWrapper> = []
    private let digestAuthRealm = "Cosmic Hammer"

    private static let logger = Logger(
        subsystem: "org.cosmichammer.CosmicHammer",
        category: "NWHTTPServer"
    )

    // MARK: - Lifecycle

    /// Start accepting connections.
    ///
    /// - Throws: If the `NWListener` cannot be created (e.g. invalid port).
    func start() throws {
        precondition(!isRunning, "Server is already running; call stop() first")
        assert(requestHandler != nil || webSocketHandler != nil,
               "At least one handler (request or websocket) should be configured before starting")

        let params = try makeParameters()

        // Require the port to fit NWEndpoint.Port
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let newListener = try NWListener(using: params, on: nwPort)

        // Bonjour
        if let name = name {
            newListener.service = NWListener.Service(name: name, type: "_http._tcp")
        }

        // Interface binding
        if let interfaceName = interface {
            newListener.parameters.requiredInterfaceType = interfaceType(for: interfaceName)
            if let specificInterface = findInterface(named: interfaceName) {
                newListener.parameters.requiredInterface = specificInterface
            }
        }

        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }

        newListener.start(queue: .main)
        listener = newListener
    }

    /// Stop the server and cancel all open connections.
    func stop() {
        listener?.cancel()
        listener = nil
        for wrapper in connections {
            wrapper.connection.cancel()
        }
        connections.removeAll()

        assert(!isRunning, "Server must not be running after stop")
        assert(connections.isEmpty, "All connections must be cleared after stop")
    }

    /// Returns the actual TCP port the listener is bound to.
    /// Useful when `port` was set to `0` (OS-assigned).
    func listeningPort() -> UInt16? {
        guard let listener = listener else { return nil }
        switch listener.port {
        case let .some(p):
            return p.rawValue
        case .none:
            return nil
        }
    }

    // MARK: - NWParameters / TLS

    private func makeParameters() throws -> NWParameters {
        assert(!isRunning, "Parameters should not be constructed while server is already running")

        guard useSSL else { return .tcp }

        let tlsOptions = NWProtocolTLS.Options()

        // Obtain (or create) a self-signed identity via the existing helper.
        guard let identity = MYGetOrCreateAnonymousIdentity(
            "Cosmic Hammer HTTP Server",
            20 * kMYAnonymousIdentityDefaultExpirationInterval
        ) else {
            Self.logger.error("Failed to obtain self-signed TLS identity")
            throw NWHTTPServerError.tlsIdentityUnavailable
        }

        // Convert SecIdentity to sec_identity_t, then attach to TLS options.
        guard let secIdentity = sec_identity_create(identity) else {
            Self.logger.error("sec_identity_create failed")
            throw NWHTTPServerError.tlsIdentityUnavailable
        }

        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentity
        )

        // Set minimum TLS version to 1.2
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        let tcpOptions = NWProtocolTCP.Options()
        return NWParameters(tls: tlsOptions, tcp: tcpOptions)
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                Self.logger.info("Server listening on port \(port.rawValue)")
            }
        case .failed(let error):
            Self.logger.error("Listener failed: \(error.localizedDescription)")
            stop()
        case .cancelled:
            Self.logger.info("Listener cancelled")
        default:
            break
        }
    }

    // MARK: - Connection Acceptance

    private func acceptConnection(_ connection: NWConnection) {
        assert(isRunning, "Cannot accept connections when server is not running")

        if connections.count >= kMaxHTTPServerConnections {
            Self.logger.error("HTTP server at max connections (\(kMaxHTTPServerConnections)) — rejecting new connection")
            connection.cancel()
            return
        }

        let wrapper = NWConnectionWrapper(connection: connection)
        connections.insert(wrapper)

        assert(connections.contains(wrapper), "Wrapper must be in connections set after insert")

        connection.stateUpdateHandler = { [weak self, weak wrapper] state in
            guard let self = self, let wrapper = wrapper else { return }
            switch state {
            case .failed, .cancelled:
                self.removeConnection(wrapper)
            default:
                break
            }
        }

        connection.start(queue: .main)
        receiveRequestData(wrapper: wrapper, buffer: Data())
    }

    private func removeConnection(_ wrapper: NWConnectionWrapper) {
        wrapper.connection.cancel()
        connections.remove(wrapper)

        assert(!connections.contains(wrapper), "Wrapper must not be in connections set after removal")
    }

    // MARK: - Receive Loop

    /// Incrementally receive data until we can parse a complete HTTP request.
    private func receiveRequestData(wrapper: NWConnectionWrapper, buffer: Data) {
        wrapper.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                Self.logger.debug("Receive error: \(error.localizedDescription)")
                self.removeConnection(wrapper)
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    self.removeConnection(wrapper)
                }
                return
            }

            var accumulated = buffer
            accumulated.append(data)

            // Try to parse a complete HTTP request
            if let (request, consumed) = parseHTTPRequest(from: accumulated) {
                accumulated.removeFirst(consumed)
                self.routeRequest(request, on: wrapper, remainingBuffer: accumulated)
            } else if accumulated.count > self.maxBodySize {
                // Request too large — reject immediately
                self.sendErrorResponse(
                    status: 413,
                    message: "Request Entity Too Large",
                    on: wrapper
                )
            } else if isComplete {
                // Connection closed before we got a complete request
                self.removeConnection(wrapper)
            } else {
                // Need more data
                self.receiveRequestData(wrapper: wrapper, buffer: accumulated)
            }
        }
    }

    // MARK: - Request Routing

    private func routeRequest(
        _ request: HTTPRequestHead,
        on wrapper: NWConnectionWrapper,
        remainingBuffer: Data
    ) {
        precondition(!request.method.isEmpty, "HTTP request method must not be empty")
        precondition(!request.path.isEmpty, "HTTP request path must not be empty")

        if tryHandleWebSocketUpgrade(request, on: wrapper) { return }
        if tryRejectUnauthorized(request, on: wrapper) { return }

        guard let handler = requestHandler else {
            sendErrorResponse(status: 503, message: "No handler configured", on: wrapper)
            return
        }

        let enrichedHeaders = buildEnrichedHeaders(from: request, on: wrapper)

        let (body, statusCode, responseHeaders) = handler(
            request.method,
            request.path,
            enrichedHeaders,
            request.body
        )

        sendResponse(
            status: statusCode,
            headers: responseHeaders,
            body: body,
            on: wrapper,
            keepAlive: shouldKeepAlive(request),
            remainingBuffer: remainingBuffer
        )
    }

    private func tryHandleWebSocketUpgrade(
        _ request: HTTPRequestHead,
        on wrapper: NWConnectionWrapper
    ) -> Bool {
        guard let wsHandler = webSocketHandler,
              isWebSocketUpgrade(request),
              request.path == wsHandler.path else {
            return false
        }
        let headerDict = headersToDict(request.headers)
        wsHandler.acceptConnection(wrapper.connection, request: headerDict)
        connections.remove(wrapper)
        return true
    }

    private func tryRejectUnauthorized(
        _ request: HTTPRequestHead,
        on wrapper: NWConnectionWrapper
    ) -> Bool {
        guard let password = password else { return false }
        let auth = HTTPDigestAuth(realm: digestAuthRealm, password: password)

        if let authHeader = headerValueFromRequest(named: "Authorization", in: request.headers) {
            if !auth.isAuthorized(method: request.method, authHeader: authHeader) {
                sendAuthChallenge(auth: auth, on: wrapper)
                return true
            }
        } else {
            sendAuthChallenge(auth: auth, on: wrapper)
            return true
        }
        return false
    }

    private func buildEnrichedHeaders(
        from request: HTTPRequestHead,
        on wrapper: NWConnectionWrapper
    ) -> [String: String] {
        var headers = headersToDict(request.headers)
        if let remoteEndpoint = wrapper.connection.currentPath?.remoteEndpoint {
            switch remoteEndpoint {
            case .hostPort(let host, let port):
                headers["X-Remote-Addr"] = "\(host)"
                headers["X-Remote-Port"] = "\(port)"
            default:
                break
            }
        }
        if let localEndpoint = wrapper.connection.currentPath?.localEndpoint {
            switch localEndpoint {
            case .hostPort(let host, let port):
                headers["X-Server-Addr"] = "\(host)"
                headers["X-Server-Port"] = "\(port)"
            default:
                break
            }
        }
        return headers
    }

    // MARK: - Response Sending

    private func sendResponse(
        status: Int,
        headers: [String: String],
        body: Data,
        on wrapper: NWConnectionWrapper,
        keepAlive: Bool,
        remainingBuffer: Data
    ) {
        precondition(status >= 100 && status < 600, "HTTP status code must be between 100 and 599, got \(status)")

        // Convert dict headers to ordered pairs
        var headerPairs = headers.map { ($0.key, $0.value) }

        // Ensure Content-Type default
        if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
            headerPairs.append(("Content-Type", "application/octet-stream"))
        }

        let responseData = formatHTTPResponse(
            status: status,
            headers: headerPairs,
            body: body,
            keepAlive: keepAlive
        )

        wrapper.connection.send(
            content: responseData,
            completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    Self.logger.debug("Send error: \(error.localizedDescription)")
                    self.removeConnection(wrapper)
                    return
                }

                if keepAlive {
                    // Pipeline: there may be another request in the buffer already
                    self.receiveRequestData(wrapper: wrapper, buffer: remainingBuffer)
                } else {
                    self.removeConnection(wrapper)
                }
            }
        )
    }

    private func sendErrorResponse(
        status: Int,
        message: String,
        on wrapper: NWConnectionWrapper
    ) {
        precondition(status >= 400, "Error response status must be >= 400, got \(status)")
        precondition(!message.isEmpty, "Error message must not be empty")

        let body = Data(message.utf8)
        let headers: [(String, String)] = [("Content-Type", "text/plain")]
        let responseData = formatHTTPResponse(
            status: status,
            headers: headers,
            body: body,
            keepAlive: false
        )

        wrapper.connection.send(
            content: responseData,
            completion: .contentProcessed { [weak self] _ in
                self?.removeConnection(wrapper)
            }
        )
    }

    private func sendAuthChallenge(auth: HTTPDigestAuth, on wrapper: NWConnectionWrapper) {
        let (statusCode, headers, body) = auth.challengeResponse()
        let responseData = formatHTTPResponse(
            status: statusCode,
            headers: headers,
            body: body,
            keepAlive: false
        )

        wrapper.connection.send(
            content: responseData,
            completion: .contentProcessed { [weak self] _ in
                self?.removeConnection(wrapper)
            }
        )
    }

    // MARK: - Helpers

    /// Check whether the request carries WebSocket upgrade headers.
    private func isWebSocketUpgrade(_ request: HTTPRequestHead) -> Bool {
        let upgrade = headerValueFromRequest(named: "Upgrade", in: request.headers)
        return upgrade?.lowercased() == "websocket"
    }

    /// Case-insensitive header lookup on ordered pairs.
    private func headerValueFromRequest(
        named name: String,
        in headers: [(String, String)]
    ) -> String? {
        let lowered = name.lowercased()
        return headers.first(where: { $0.0.lowercased() == lowered })?.1
    }

    /// Convert ordered header pairs to a `[String: String]` dictionary.
    /// If duplicate header names exist, the last value wins.
    private func headersToDict(_ headers: [(String, String)]) -> [String: String] {
        var dict: [String: String] = [:]
        for (key, value) in headers {
            dict[key] = value
        }
        assert(dict.count <= headers.count, "Dictionary cannot have more entries than input pairs")
        return dict
    }

    /// Determine whether the connection should be kept alive based on HTTP
    /// version and `Connection` header.
    private func shouldKeepAlive(_ request: HTTPRequestHead) -> Bool {
        if let connection = headerValueFromRequest(named: "Connection", in: request.headers) {
            return connection.lowercased() == "keep-alive"
        }
        // HTTP/1.1 defaults to keep-alive
        return request.version.contains("1.1")
    }

    // MARK: - Interface Resolution

    /// Map a human-friendly interface string to an NWInterface.InterfaceType.
    private func interfaceType(for name: String) -> NWInterface.InterfaceType {
        switch name.lowercased() {
        case "loopback", "localhost", "lo0":
            return .loopback
        case let n where n.hasPrefix("en"):
            return .wifi // Covers en0, en1 on typical macOS
        default:
            return .other
        }
    }

    /// Find the NWInterface matching the given name or IP address.
    private func findInterface(named name: String) -> NWInterface? {
        // NWPathMonitor can enumerate interfaces but that's async.
        // For now, walk the current path's available interfaces.
        let monitor = NWPathMonitor()
        let path = monitor.currentPath
        monitor.cancel()
        return path.availableInterfaces.first { iface in
            iface.name == name
        }
    }
}

// MARK: - NWHTTPServerError

enum NWHTTPServerError: Error, LocalizedError {
    case tlsIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .tlsIdentityUnavailable:
            return "Unable to obtain or create a self-signed TLS identity"
        }
    }
}

// MARK: - NWConnectionWrapper

/// Hashable wrapper around `NWConnection` so we can store connections in a `Set`.
/// Identity is based on the ObjectIdentifier of the underlying NWConnection.
final class NWConnectionWrapper: Hashable {
    let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    static func == (lhs: NWConnectionWrapper, rhs: NWConnectionWrapper) -> Bool {
        return lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
