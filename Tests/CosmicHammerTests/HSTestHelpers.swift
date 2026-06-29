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
let otelCollectorTestsEnabled: Bool = ProcessInfo.processInfo.environment["OTEL_COLLECTOR_TESTS"] != nil
let otelStressTestsEnabled: Bool = ProcessInfo.processInfo.environment["OTEL_STRESS_TESTS"] != nil
let otelBenchmarkTestsEnabled: Bool = ProcessInfo.processInfo.environment["OTEL_BENCHMARK_TESTS"] != nil

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

struct LocalOTLPHTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

final class LocalOTLPHTTPReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CosmicHammerTests.LocalOTLPHTTPReceiver")
    private let lock = NSLock()
    private var receivedRequests: [LocalOTLPHTTPRequest] = []
    let endpoint: String

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw socketTestError("Invalid local OTLP receiver port \(port)")
        }
        listener = try NWListener(using: .tcp, on: nwPort)
        endpoint = "http://127.0.0.1:\(port)"

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
            throw socketTestError("Timed out starting local OTLP HTTP receiver")
        }
        if let startupError = startupState.error() {
            throw startupError
        }
    }

    convenience init() throws {
        try self.init(port: reserveLocalNetworkPort())
    }

    deinit {
        listener.cancel()
    }

    func requests() -> [LocalOTLPHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests
    }

    func waitForRequests(count: Int, timeout: TimeInterval) -> [LocalOTLPHTTPRequest] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let snapshot = requests()
            if snapshot.count >= count {
                return snapshot
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return requests()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let request = self.parseRequest(nextBuffer) {
                self.lock.lock()
                self.receivedRequests.append(request)
                self.lock.unlock()
                self.sendOK(on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: nextBuffer)
        }
    }

    private func sendOK(on connection: NWConnection) {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(
            content: response,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func parseRequest(_ data: Data) -> LocalOTLPHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else {
            return nil
        }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        return LocalOTLPHTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
    }
}

@MainActor private var localWebSocketEchoServer: LocalWebSocketEchoServer?

@MainActor
func configureSocketTestEnvironment() throws -> (port: UInt16, socketPath: String) {
    let port = try reserveLocalNetworkPort()
    setenv("COSMIC_HAMMER_TEST_SOCKET_PORT", String(port), 1)

    let socketPath = "/tmp/cosmic-hammer-\(UUID().uuidString).sock"
    setenv("COSMIC_HAMMER_TEST_SOCKET_PATH", socketPath, 1)

    // Socket tests run entirely through SimulatedSocket; set env vars
    // pointing at a synthetic HTTP endpoint so Lua test code has valid
    // host/port values even though no real server is listening.
    setenv("COSMIC_HAMMER_TEST_SOCKET_HTTP_HOST", "127.0.0.1", 1)
    setenv("COSMIC_HAMMER_TEST_SOCKET_HTTP_PORT", String(port), 1)

    return (port, socketPath)
}

@MainActor
func configureHttpTestEnvironment() throws {
    // HTTP tests run entirely through SimulatedNetwork; no real server needed.
    let base = "http://127.0.0.1:19876"
    setenv("COSMIC_HAMMER_TEST_HTTP_BASE_URL", base, 1)

    bootstrapLuaForTesting()
    let L = lua_getCurrentState()!
    let env = environmentGet(L)
    if let netSim = env.network as? SimulatedNetwork {
        let okBody = "local deterministic response\n"
        netSim.httpResponses["\(base)/redirect"] = HTTPResponse(
            statusCode: 301,
            headers: ["Location": "\(base)/ok", "Content-Type": "text/plain"],
            body: Data()
        )
        netSim.httpResponses["\(base)/ok"] = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/plain"],
            body: okBody.data(using: .utf8)
        )
    }
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
            let spinDuration: TimeInterval = testHarness != nil ? 0.001 : 0.1
            RunLoop.main.run(until: Date(timeIntervalSinceNow: spinDuration))
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

    /// Skip tests that need production OS APIs bypassing the DST simulator
    /// (accessibility, event taps, serial hardware, ramdisks, etc.).
    static var requiresRealOS: Self {
        .disabled("Test requires production OS APIs not available under DST")
    }

    static var requiresExternalNetwork: Self {
        .enabled(if: externalNetworkTestsEnabled, "Test requires external network; set EXTERNAL_NETWORK_TESTS=1 to run")
    }

    static var requiresOTELCollector: Self {
        .enabled(if: otelCollectorTestsEnabled, "Test requires OTEL_COLLECTOR_TESTS=1")
    }

    static var requiresOTELStress: Self {
        .enabled(if: otelStressTestsEnabled, "Test requires OTEL_STRESS_TESTS=1")
    }

    static var requiresOTELBenchmark: Self {
        .enabled(if: otelBenchmarkTestsEnabled, "Test requires OTEL_BENCHMARK_TESTS=1")
    }
}
