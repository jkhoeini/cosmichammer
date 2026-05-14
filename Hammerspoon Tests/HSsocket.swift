import XCTest

@objcMembers
class HSsocketSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_socket")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testTcpSocketInstanceCreation() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpSocketInstanceCreation)), "Test failed: testTcpSocketInstanceCreation")
    }

    func testTcpSocketInstanceCreationWithCallback() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpSocketInstanceCreationWithCallback)), "Test failed: testTcpSocketInstanceCreationWithCallback")
    }

    func testTcpListenerSocketCreation() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpListenerSocketCreation)), "Test failed: testTcpListenerSocketCreation")
    }

    func testTcpListenerSocketCreationWithCallback() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpListenerSocketCreationWithCallback)), "Test failed: testTcpListenerSocketCreationWithCallback")
    }

    func testTcpListenerSocketAttributes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpListenerSocketAttributes)), "Test failed: testTcpListenerSocketAttributes")
    }

    func testTcpUnixListenerSocketAttributes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpUnixListenerSocketAttributes)), "Test failed: testTcpUnixListenerSocketAttributes")
    }

    func testUdpConnect() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpConnect)), "Test failed: testUdpConnect")
    }

    func testUdpNoCallbacks() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpNoCallbacks)), "Test failed: testUdpNoCallbacks")
    }

    func testTcpDisconnectAndReuse() {
        twoPartTestName(#selector(testTcpDisconnectAndReuse), withTimeout: 2)
    }

    func testTcpConnected() {
        twoPartTestName(#selector(testTcpConnected), withTimeout: 2)
    }

    func testTcpAlreadyConnected() {
        twoPartTestName(#selector(testTcpAlreadyConnected), withTimeout: 2)
    }

    func testTcpUserdataStrings() {
        twoPartTestName(#selector(testTcpUserdataStrings), withTimeout: 2)
    }

    func testTcpClientServerReadWriteDelimiter() {
        twoPartTestName(#selector(testTcpClientServerReadWriteDelimiter), withTimeout: 2)
    }

    func testTcpClientServerReadWriteBytes() {
        twoPartTestName(#selector(testTcpClientServerReadWriteBytes), withTimeout: 2)
    }

    func testTcpUnixClientServerReadWriteBytes() {
        twoPartTestName(#selector(testTcpUnixClientServerReadWriteBytes), withTimeout: 2)
    }

    func testTcpTagging() {
        twoPartTestName(#selector(testTcpTagging), withTimeout: 10)
    }

    func testTcpClientServerTimeout() {
        twoPartTestName(#selector(testTcpClientServerTimeout), withTimeout: 3)
    }

    func testTcpTls() {
        twoPartTestName(#selector(testTcpTls), withTimeout: 10)
    }

    func testTcpTlsRequiredByServer() {
        twoPartTestName(#selector(testTcpTlsRequiredByServer), withTimeout: 10)
    }

    func testTcpTlsVerifyPeer() {
        twoPartTestName(#selector(testTcpTlsVerifyPeer), withTimeout: 10)
    }

    func testTcpTlsVerifyBadPeerFails() {
        twoPartTestName(#selector(testTcpTlsVerifyBadPeerFails), withTimeout: 10)
    }

    func testTcpTlsNoVerify() {
        twoPartTestName(#selector(testTcpTlsNoVerify), withTimeout: 10)
    }

    func testTcpNoCallbackRead() {
        twoPartTestName(#selector(testTcpNoCallbackRead), withTimeout: 2)
    }

    func testTcpParseAddress() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpParseAddress)), "Test failed: testTcpParseAddress")
    }

    func testTcpParseBadAddress() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTcpParseBadAddress)), "Test failed: testTcpParseBadAddress")
    }

    func testUdpSocketInstanceCreation() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpSocketInstanceCreation)), "Test failed: testUdpSocketInstanceCreation")
    }

    func testUdpSocketInstanceCreationWithCallback() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpSocketInstanceCreationWithCallback)), "Test failed: testUdpSocketInstanceCreationWithCallback")
    }

    func testUdpListenerSocketCreation() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpListenerSocketCreation)), "Test failed: testUdpListenerSocketCreation")
    }

    func testUdpListenerSocketCreationWithCallback() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpListenerSocketCreationWithCallback)), "Test failed: testUdpListenerSocketCreationWithCallback")
    }

    func testUdpListenerSocketAttributes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUdpListenerSocketAttributes)), "Test failed: testUdpListenerSocketAttributes")
    }

    func testUdpDisconnectAndReuse() {
        twoPartTestName(#selector(testUdpDisconnectAndReuse), withTimeout: 2)
    }

    func testUdpAlreadyConnected() {
        twoPartTestName(#selector(testUdpAlreadyConnected), withTimeout: 2)
    }

    func testUdpUserdataStrings() {
        twoPartTestName(#selector(testUdpUserdataStrings), withTimeout: 2)
    }

    func testUdpClientServerReceiveOnce() {
        twoPartTestName(#selector(testUdpClientServerReceiveOnce), withTimeout: 2)
    }

    func testUdpClientServerReceiveMany() {
        twoPartTestName(#selector(testUdpClientServerReceiveMany), withTimeout: 2)
    }

    func testUdpBroadcast() {
        twoPartTestName(#selector(testUdpBroadcast), withTimeout: 2)
    }

    func testUdpReusePort() {
        twoPartTestName(#selector(testUdpReusePort), withTimeout: 2)
    }

    func testUdpEnabledIpVersion() {
        twoPartTestName(#selector(testUdpEnabledIpVersion), withTimeout: 2)
    }

    func testUdpPreferredIpVersion() {
        twoPartTestName(#selector(testUdpPreferredIpVersion), withTimeout: 2)
    }

    func testUdpBufferSize() {
        twoPartTestName(#selector(testUdpBufferSize), withTimeout: 2)
    }
}
