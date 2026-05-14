import XCTest

@objcMembers
class HSwebsocketSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_websocket")
        runLua("startEchoServer()")
    }

    override func tearDown() {
        runLua("stopEchoServer()")
        super.tearDown()
    }

    func testNew() {
        XCTAssertTrue(luaTestFromSelector(#selector(testNew)), "Test failed: testNew")
    }

    func testEchoData() {
        twoPartTestName(#selector(testEchoData), withTimeout: 8)
    }

    func testEchoText() {
        twoPartTestName(#selector(testEchoText), withTimeout: 8)
    }

    func testOpenStatus() {
        twoPartTestName(#selector(testOpenStatus), withTimeout: 5)
    }

    func testClosedStatus() {
        twoPartTestName(#selector(testClosedStatus), withTimeout: 5)
    }

    func testClosingStatus() {
        twoPartTestName(#selector(testClosingStatus), withTimeout: 5)
    }

    func testLegacy() {
        twoPartTestName(#selector(testLegacy), withTimeout: 8)
    }
}
