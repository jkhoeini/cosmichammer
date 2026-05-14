import XCTest

@objcMembers
class HSalert: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_alert")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testAlert() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAlert)), "Test failed: testAlert")
    }

    func testCloseAll() {
        XCTAssertTrue(luaTestFromSelector(#selector(testCloseAll)), "Test failed: testCloseAll")
    }
}
