import XCTest

@objcMembers
class HSmouseTestsSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_mouse")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testMouseCount() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testMouseCount)), "Test failed: testMouseCount")
    }

    func testMouseNames() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testMouseNames)), "Test failed: testMouseNames")
    }

    func testMouseAbsolutePosition() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMouseAbsolutePosition)), "Test failed: testMouseAbsolutePosition")
    }

    func testScrollDirection() {
        XCTAssertTrue(luaTestFromSelector(#selector(testScrollDirection)), "Test failed: testScrollDirection")
    }

    func testMouseTrackingSpeed() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMouseTrackingSpeed)), "Test failed: testMouseTrackingSpeed")
    }
}
