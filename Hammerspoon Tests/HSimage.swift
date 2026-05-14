import XCTest

@objcMembers
class HSimage: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_image")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testGetExifFromPath() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetExifFromPath)), "Test failed: testGetExifFromPath")
    }
}
