import XCTest

@objcMembers
class HSappfinder: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_appfinder")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testAppFromName() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppFromName)), "Test failed: testAppFromName")
    }

    func testAppFromWindowTitle() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppFromWindowTitle)), "Test failed: testAppFromWindowTitle")
    }

    func testAppFromWindowTitlePattern() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppFromWindowTitlePattern)), "Test failed: testAppFromWindowTitlePattern")
    }

    func testWindowFromWindowTitle() {
        XCTAssertTrue(luaTestFromSelector(#selector(testWindowFromWindowTitle)), "Test failed: testWindowFromWindowTitle")
    }

    func testWindowFromWindowTitlePattern() {
        XCTAssertTrue(luaTestFromSelector(#selector(testWindowFromWindowTitlePattern)), "Test failed: testWindowFromWindowTitlePattern")
    }
}
