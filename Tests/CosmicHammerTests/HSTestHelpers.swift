import Testing
import Foundation
import Darwin
import Network
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

let isHeadless: Bool = ProcessInfo.processInfo.environment["HEADLESS"] != nil
let externalNetworkTestsEnabled: Bool = ProcessInfo.processInfo.environment["EXTERNAL_NETWORK_TESTS"] != nil

private func socketTestError(_ message: String) -> NSError {
    NSError(domain: "CosmicHammerTests.Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
}

private func bindIPv4Socket(kind: Int32, port: UInt16) throws -> (fd: Int32, port: UInt16) {
    let fd = Darwin.socket(AF_INET, kind, 0)
    guard fd >= 0 else {
        throw socketTestError("socket() failed: \(String(cString: strerror(errno)))")
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY)

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        let message = "bind() failed: \(String(cString: strerror(errno)))"
        Darwin.close(fd)
        throw socketTestError(message)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.getsockname(fd, socketAddress, &length)
        }
    }
    guard getsocknameResult == 0 else {
        let message = "getsockname() failed: \(String(cString: strerror(errno)))"
        Darwin.close(fd)
        throw socketTestError(message)
    }

    return (fd, UInt16(bigEndian: boundAddress.sin_port))
}

private func reserveLocalNetworkPort() throws -> UInt16 {
    var lastError: Error?

    for _ in 0..<20 {
        do {
            let tcp = try bindIPv4Socket(kind: SOCK_STREAM, port: 0)
            defer { Darwin.close(tcp.fd) }

            let udp = try bindIPv4Socket(kind: SOCK_DGRAM, port: tcp.port)
            Darwin.close(udp.fd)

            return tcp.port
        } catch {
            lastError = error
        }
    }

    throw lastError ?? socketTestError("Unable to reserve local test port")
}

private final class LocalNetworkServerStartupState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func error() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

private final class LocalHTTPRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CosmicHammerTests.LocalHTTPRedirectServer")
    let baseURL: String

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw socketTestError("Invalid local HTTP test port \(port)")
        }

        listener = try NWListener(using: .tcp, on: nwPort)
        baseURL = "http://127.0.0.1:\(port)"

        let ready = DispatchSemaphore(value: 0)
        let startupState = LocalNetworkServerStartupState()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupState.setError(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            throw socketTestError("Timed out starting local HTTP test server")
        }
        if let startupError = startupState.error() {
            throw startupError
        }
    }

    deinit {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"

            let status: String
            let body: String
            var headers = ["Connection": "close", "Content-Type": "text/plain"]
            if path == "/redirect" {
                status = "301 Moved Permanently"
                body = ""
                headers["Location"] = "\(baseURL)/ok"
            } else if path == "/ok" {
                status = "200 OK"
                body = "local deterministic response\n"
            } else {
                status = "404 Not Found"
                body = "not found\n"
            }

            headers["Content-Length"] = "\(body.utf8.count)"
            let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            let response = "HTTP/1.1 \(status)\r\n\(headerLines)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    connection.cancel()
                }
            })
        }
    }
}

@MainActor private var localHTTPRedirectServer: LocalHTTPRedirectServer?

private final class LocalSocketHTTPServer: @unchecked Sendable {
    private let listenFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "CosmicHammerTests.LocalSocketHTTPServer")
    private let requestLock = NSLock()
    private var requestCounter = 0
    let port: UInt16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw socketTestError("socket() failed: \(String(cString: strerror(errno)))")
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = "bind() failed: \(String(cString: strerror(errno)))"
            Darwin.close(fd)
            throw socketTestError(message)
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let message = "listen() failed: \(String(cString: strerror(errno)))"
            Darwin.close(fd)
            throw socketTestError(message)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(fd, socketAddress, &length)
            }
        }
        guard getsocknameResult == 0 else {
            let message = "getsockname() failed: \(String(cString: strerror(errno)))"
            Darwin.close(fd)
            throw socketTestError(message)
        }

        listenFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func requestCount() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requestCounter
    }

    private func acceptConnection() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        queue.async { [weak self] in
            self?.handle(clientFD)
        }
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = Darwin.read(clientFD, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        requestLock.lock()
        requestCounter += 1
        requestLock.unlock()

        let body = "local deterministic response\n"
        let response = "HTTP/1.0 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: Close\r\n\r\n\(body)"
        let bytes = [UInt8](response.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(clientFD, base, remaining)
                if written <= 0 { break }
                remaining -= written
                base += written
            }
        }
        Darwin.shutdown(clientFD, SHUT_WR)
        usleep(50_000)
    }
}

@MainActor private var localSocketHTTPServer: LocalSocketHTTPServer?

private final class LocalWebSocketEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CosmicHammerTests.LocalWebSocketEchoServer")
    private let countLock = NSLock()
    private var binaryFrameCount = 0
    private var textFrameCount = 0
    let url: String

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw socketTestError("Invalid local websocket test port \(port)")
        }

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        listener = try NWListener(using: parameters, on: nwPort)
        url = "ws://127.0.0.1:\(port)/"

        let ready = DispatchSemaphore(value: 0)
        let startupState = LocalNetworkServerStartupState()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupState.setError(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            throw socketTestError("Timed out starting local websocket test server")
        }
        if let startupError = startupState.error() {
            throw startupError
        }
    }

    deinit {
        listener.cancel()
    }

    func receivedBinaryFrameCount() -> Int {
        countLock.lock()
        defer { countLock.unlock() }
        return binaryFrameCount
    }

    func receivedTextFrameCount() -> Int {
        countLock.lock()
        defer { countLock.unlock() }
        return textFrameCount
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            guard
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            else {
                connection.cancel()
                return
            }
            let payload = data ?? Data()
            switch metadata.opcode {
            case .binary:
                countLock.lock()
                binaryFrameCount += 1
                countLock.unlock()
            case .text:
                countLock.lock()
                textFrameCount += 1
                countLock.unlock()
            case .close:
                connection.cancel()
                return
            default:
                receiveMessage(on: connection)
                return
            }

            let responseMetadata = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
            let responseContext = NWConnection.ContentContext(
                identifier: "CosmicHammerTests.LocalWebSocketEchoServer.echo",
                metadata: [responseMetadata]
            )
            connection.send(
                content: payload,
                contentContext: responseContext,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.receiveMessage(on: connection)
                }
            )
        }
    }
}

@MainActor private var localWebSocketEchoServer: LocalWebSocketEchoServer?

@MainActor
func configureSocketTestEnvironment() throws -> (port: UInt16, socketPath: String) {
    let port = try reserveLocalNetworkPort()
    setenv("COSMIC_HAMMER_TEST_SOCKET_PORT", String(port), 1)

    let socketPath = "/tmp/cosmic-hammer-\(UUID().uuidString).sock"
    setenv("COSMIC_HAMMER_TEST_SOCKET_PATH", socketPath, 1)

    if localSocketHTTPServer == nil {
        localSocketHTTPServer = try LocalSocketHTTPServer()
    }
    if let server = localSocketHTTPServer {
        setenv("COSMIC_HAMMER_TEST_SOCKET_HTTP_HOST", "127.0.0.1", 1)
        setenv("COSMIC_HAMMER_TEST_SOCKET_HTTP_PORT", String(server.port), 1)
    }

    return (port, socketPath)
}

@MainActor
func configureHttpTestEnvironment() throws {
    if localHTTPRedirectServer == nil {
        localHTTPRedirectServer = try LocalHTTPRedirectServer(port: reserveLocalNetworkPort())
    }

    guard let server = localHTTPRedirectServer else {
        throw socketTestError("Local HTTP test server was not created")
    }
    setenv("COSMIC_HAMMER_TEST_HTTP_BASE_URL", server.baseURL, 1)
}

@MainActor
func localSocketHTTPServerRequestCount() -> Int {
    localSocketHTTPServer?.requestCount() ?? 0
}

@MainActor
func simulatedSocketWriteCount() -> Int {
    // Access the simulated socket from the lua_State's environment
    let L = lua_getCurrentState()
    guard let L = L else { return 0 }
    let env = environmentGet(L)
    if let simSocket = env.socket as? SimulatedSocket {
        return simSocket.sentData.count
    }
    return 0
}

@MainActor
func configureWebsocketTestEnvironment() throws {
    if localWebSocketEchoServer == nil {
        localWebSocketEchoServer = try LocalWebSocketEchoServer(port: reserveLocalNetworkPort())
    }

    guard let server = localWebSocketEchoServer else {
        throw socketTestError("Local websocket test server was not created")
    }
    setenv("COSMIC_HAMMER_TEST_WEBSOCKET_URL", server.url, 1)
}

@MainActor
func localWebSocketBinaryFrameCount() -> Int {
    localWebSocketEchoServer?.receivedBinaryFrameCount() ?? 0
}

@MainActor
func localWebSocketTextFrameCount() -> Int {
    localWebSocketEchoServer?.receivedTextFrameCount() ?? 0
}

@MainActor
func runLua(_ code: String) -> String? {
    luaRunString(code)
}

@MainActor
func loadLuaModule(_ name: String) throws {
    bootstrapLuaForTesting()
    let result = runLua("require('\(name)')")
    try #require(result == "true", "Unable to load \(name).lua")
}

@MainActor
func runLuaTest(function: String = #function) {
    let funcName = function.replacingOccurrences(of: "()", with: "")
    let result = runLua("\(funcName)()")
    #expect(result == "Success", "Lua test \(funcName) failed: \(result ?? "nil")")
}

@MainActor
func luaTestWithCheckAndTimeout(
    _ timeout: TimeInterval, setup: String, check: String
) {
    let setupResult = runLua(setup)
    guard setupResult == "Success" else {
        Issue.record("Setup failed: \(setup) returned \(setupResult ?? "nil")")
        return
    }
    let deadline = Date(timeIntervalSinceNow: timeout)
    var lastResult: String?
    while Date() < deadline {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            testHarness?.advanceTime(by: 0.1)
        }
        lastResult = runLua(check)
        if lastResult == "Success" { return }
    }
    Issue.record("Timed out after \(timeout)s: \(check); last result: \(lastResult ?? "nil")")
}

@MainActor
func runTwoPartLuaTest(timeout: TimeInterval, function: String = #function) {
    let funcName = function.replacingOccurrences(of: "()", with: "")
    luaTestWithCheckAndTimeout(timeout, setup: "\(funcName)()", check: "\(funcName)Values()")
}

extension Trait where Self == Testing.ConditionTrait {
    static var skipInHeadless: Self {
        .enabled(if: !isHeadless, "Test requires hardware (display, audio, etc.)")
    }

    static var requiresExternalNetwork: Self {
        .enabled(if: externalNetworkTestsEnabled, "Test requires external network; set EXTERNAL_NETWORK_TESTS=1 to run")
    }
}
