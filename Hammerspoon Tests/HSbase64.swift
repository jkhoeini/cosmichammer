import XCTest

@objcMembers
class HSbase64: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_base64")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testEncode() {
        XCTAssertTrue(luaTestFromSelector(#selector(testEncode)), "Test failed: testEncode")
    }

    func testDecode() {
        XCTAssertTrue(luaTestFromSelector(#selector(testDecode)), "Test failed: testDecode")
    }
}
