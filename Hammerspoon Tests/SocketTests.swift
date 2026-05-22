import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Socket {
        init() throws { try loadLuaModule("test_socket") }

        @Test func testTcpSocketInstanceCreation() { runLuaTest() }
        @Test func testTcpSocketInstanceCreationWithCallback() { runLuaTest() }
        @Test func testTcpListenerSocketCreation() { runLuaTest() }
        @Test func testTcpListenerSocketCreationWithCallback() { runLuaTest() }
        @Test func testTcpListenerSocketAttributes() { runLuaTest() }
        @Test func testTcpUnixListenerSocketAttributes() { runLuaTest() }
        @Test func testUdpConnect() { runLuaTest() }
        @Test func testUdpNoCallbacks() { runLuaTest() }
        @Test func testTcpParseAddress() { runLuaTest() }
        @Test func testTcpParseBadAddress() { runLuaTest() }
        @Test func testUdpSocketInstanceCreation() { runLuaTest() }
        @Test func testUdpSocketInstanceCreationWithCallback() { runLuaTest() }
        @Test func testUdpListenerSocketCreation() { runLuaTest() }
        @Test func testUdpListenerSocketCreationWithCallback() { runLuaTest() }
        @Test func testUdpListenerSocketAttributes() { runLuaTest() }

        @Test func testTcpDisconnectAndReuse() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpConnected() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpAlreadyConnected() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpUserdataStrings() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpClientServerReadWriteDelimiter() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpClientServerReadWriteBytes() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpUnixClientServerReadWriteBytes() { runTwoPartLuaTest(timeout: 2) }
        @Test func testTcpTagging() { runTwoPartLuaTest(timeout: 10) }
        @Test func testTcpClientServerTimeout() { runTwoPartLuaTest(timeout: 3) }
        @Test func testTcpTls() { runTwoPartLuaTest(timeout: 10) }
        @Test func testTcpTlsRequiredByServer() { runTwoPartLuaTest(timeout: 10) }
        @Test func testTcpTlsVerifyPeer() { runTwoPartLuaTest(timeout: 10) }
        @Test func testTcpTlsVerifyBadPeerFails() { runTwoPartLuaTest(timeout: 10) }
        @Test func testTcpTlsNoVerify() { runTwoPartLuaTest(timeout: 10) }
        @Test func testTcpNoCallbackRead() { runTwoPartLuaTest(timeout: 2) }

        @Test func testUdpDisconnectAndReuse() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpAlreadyConnected() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpUserdataStrings() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpClientServerReceiveOnce() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpClientServerReceiveMany() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpBroadcast() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpReusePort() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpEnabledIpVersion() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpPreferredIpVersion() { runTwoPartLuaTest(timeout: 2) }
        @Test func testUdpBufferSize() { runTwoPartLuaTest(timeout: 2) }
    }
}
