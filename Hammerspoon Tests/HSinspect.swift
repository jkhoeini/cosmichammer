import XCTest

@objcMembers
class HSinspect: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_inspect")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testSimpleInspect() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSimpleInspect)), "Test failed: testSimpleInspect")
    }
}
