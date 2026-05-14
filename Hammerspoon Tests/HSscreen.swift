import XCTest

@objcMembers
class HSscreenSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_screen")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testMainScreen() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMainScreen)), "Test failed: testMainScreen")
    }

    func testPrimaryScreen() {
        XCTAssertTrue(luaTestFromSelector(#selector(testPrimaryScreen)), "Test failed: testPrimaryScreen")
    }

    func testAllScreens() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAllScreens)), "Test failed: testAllScreens")
    }

    func testFind() {
        XCTAssertTrue(luaTestFromSelector(#selector(testFind)), "Test failed: testFind")
    }

    func testScreenPositions() {
        XCTAssertTrue(luaTestFromSelector(#selector(testScreenPositions)), "Test failed: testScreenPositions")
    }

    func testAvailableModes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAvailableModes)), "Test failed: testAvailableModes")
    }

    func testCurrentMode() {
        XCTAssertTrue(luaTestFromSelector(#selector(testCurrentMode)), "Test failed: testCurrentMode")
    }

    func testSetMode() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testSetMode)), "Test failed: testSetMode")
    }

    func testSetOrigin() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSetOrigin)), "Test failed: testSetOrigin")
    }

    func testFrames() {
        XCTAssertTrue(luaTestFromSelector(#selector(testFrames)), "Test failed: testFrames")
    }

    func testFromUnitRect() {
        XCTAssertTrue(luaTestFromSelector(#selector(testFromUnitRect)), "Test failed: testFromUnitRect")
    }

    func testBrightness() {
        XCTAssertTrue(luaTestFromSelector(#selector(testBrightness)), "Test failed: testBrightness")
    }

    func testGamma() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGamma)), "Test failed: testGamma")
    }

    func testId() {
        XCTAssertTrue(luaTestFromSelector(#selector(testId)), "Test failed: testId")
    }

    func testName() {
        XCTAssertTrue(luaTestFromSelector(#selector(testName)), "Test failed: testName")
    }

    func testPosition() {
        XCTAssertTrue(luaTestFromSelector(#selector(testPosition)), "Test failed: testPosition")
    }

    func testNextPrevious() {
        XCTAssertTrue(luaTestFromSelector(#selector(testNextPrevious)), "Test failed: testNextPrevious")
    }

    func testRotation() {
        XCTAssertTrue(luaTestFromSelector(#selector(testRotation)), "Test failed: testRotation")
    }

    func testSetPrimary() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSetPrimary)), "Test failed: testSetPrimary")
    }

    func testScreenshots() {
        XCTAssertTrue(luaTestFromSelector(#selector(testScreenshots)), "Test failed: testScreenshots")
    }

    func testToUnitRect() {
        XCTAssertTrue(luaTestFromSelector(#selector(testToUnitRect)), "Test failed: testToUnitRect")
    }
}
