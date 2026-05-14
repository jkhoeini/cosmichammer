import XCTest

@objcMembers
class HSmathSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_math")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testRandomFloat() {
        XCTAssertTrue(luaTestFromSelector(#selector(testRandomFloat)), "Test failed: testRandomFloat")
    }

    func testRandomFromRange() {
        XCTAssertTrue(luaTestFromSelector(#selector(testRandomFromRange)), "Test failed: testRandomFromRange")
    }
}
