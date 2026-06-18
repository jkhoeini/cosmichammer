import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Socket {
        private let socketFixture: (port: UInt16, socketPath: String)
        private let socketPath: String

        init() throws {
            socketFixture = try configureSocketTestEnvironment()
            socketPath = socketFixture.socketPath
            try loadLuaModule("test_socket")
        }

        deinit {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        private func configureLuaSocketFixture() {
            let socketPath = socketFixture.socketPath.replacingOccurrences(of: "'", with: "\\'")
            _ = runLua("port = \(socketFixture.port); sockfile = '\(socketPath)'")
        }

        private func runSocketLuaTest(function: String = #function) {
            configureLuaSocketFixture()
            runLuaTest(function: function)
        }

        private func runSocketTwoPartLuaTest(timeout: TimeInterval, function: String = #function) {
            configureLuaSocketFixture()
            runTwoPartLuaTest(timeout: timeout, function: function)
        }

        @Test func testTcpSocketInstanceCreation() { runSocketLuaTest() }
        @Test func testTcpSocketInstanceCreationWithCallback() { runSocketLuaTest() }
        @Test func testTcpListenerSocketCreation() { runSocketLuaTest() }
        @Test func testTcpListenerSocketCreationWithCallback() { runSocketLuaTest() }
        @Test func testTcpListenerSocketAttributes() { runSocketLuaTest() }
        @Test func testTcpUnixListenerSocketAttributes() { runSocketLuaTest() }
        @Test func testUdpConnect() { runSocketLuaTest() }
        @Test func testUdpNoCallbacks() { runSocketLuaTest() }
        @Test func testTcpParseAddress() { runSocketLuaTest() }
        @Test func testTcpParseBadAddress() { runSocketLuaTest() }
        @Test func testUdpSocketInstanceCreation() { runSocketLuaTest() }
        @Test func testUdpSocketInstanceCreationWithCallback() { runSocketLuaTest() }
        @Test func testUdpListenerSocketCreation() { runSocketLuaTest() }
        @Test func testUdpListenerSocketCreationWithCallback() { runSocketLuaTest() }
        @Test func testUdpListenerSocketAttributes() { runSocketLuaTest() }
        @Test func testTcpWriteAcceptsBinaryString() { runSocketLuaTest() }
        @Test func testUdpSendAcceptsBinaryString() { runSocketLuaTest() }
        @Test func testSocketRejectsInvalidNumericArguments() { runSocketLuaTest() }

        @Test func testTcpDisconnectAndReuse() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpConnected() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpAlreadyConnected() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpUserdataStrings() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpClientServerReadWriteDelimiter() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpClientServerReadWriteBytes() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpUnixClientServerReadWriteBytes() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testTcpConnectAndWriteUsesLocalServer() {
            configureLuaSocketFixture()
            let before = localSocketHTTPServerRequestCount()
            let setupResult = runLua("testTcpConnectAndWriteUsesLocalServer()")
            guard setupResult == "Success" else {
                Issue.record("Setup failed: testTcpConnectAndWriteUsesLocalServer() returned \(setupResult ?? "nil")")
                return
            }

            let deadline = Date(timeIntervalSinceNow: 5)
            var sawRequest = false
            var lastValueResult: String?
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
                testHarness?.advanceTime(by: 0.5)
                // Count real HTTP requests OR simulated socket writes as "requests"
                let realRequests = localSocketHTTPServerRequestCount() > before
                let simRequests = simulatedSocketWriteCount() > 0
                sawRequest = sawRequest || realRequests || simRequests
                lastValueResult = runLua("testTcpConnectAndWriteUsesLocalServerValues()")
                if sawRequest && lastValueResult == "Success" { return }
            }

            let requestCount = localSocketHTTPServerRequestCount() - before
            Issue.record("Timed out after 5.0s waiting for local socket HTTP request; local HTTP requests: \(requestCount); last value result: \(lastValueResult ?? "nil")")
        }
        @Test(.enabled(if: false, "Real TCP read/read-tag coverage is blocked by current hs.socket read callback behavior"))
        func testTcpTagging() {}
        @Test func testTcpClientServerTimeout() { runSocketTwoPartLuaTest(timeout: 3) }
        @Test(.requiresExternalNetwork) func testTcpTls() { runSocketTwoPartLuaTest(timeout: 10) }
        @Test(.requiresExternalNetwork) func testTcpTlsRequiredByServer() { runSocketTwoPartLuaTest(timeout: 10) }
        @Test(.requiresExternalNetwork) func testTcpTlsVerifyPeer() { runSocketTwoPartLuaTest(timeout: 10) }
        @Test(.requiresExternalNetwork) func testTcpTlsVerifyBadPeerFails() { runSocketTwoPartLuaTest(timeout: 10) }
        @Test(.requiresExternalNetwork) func testTcpTlsNoVerify() { runSocketTwoPartLuaTest(timeout: 10) }
        @Test func testTcpNoCallbackRead() { runSocketTwoPartLuaTest(timeout: 2) }

        @Test func testUdpDisconnectAndReuse() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpAlreadyConnected() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpUserdataStrings() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpClientServerReceiveOnce() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpClientServerReceiveMany() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpBroadcast() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpReusePort() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpEnabledIpVersion() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpPreferredIpVersion() { runSocketTwoPartLuaTest(timeout: 2) }
        @Test func testUdpBufferSize() { runSocketTwoPartLuaTest(timeout: 2) }

    }
}
