import XCTest

@objcMembers
class HSnoisesSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_noises")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testStartStop() {
        XCTAssertTrue(luaTestFromSelector(#selector(testStartStop)), "Test failed: testStartStop")
    }
}
