import XCTest

@objcMembers
class HSwindowTestsSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_window")
    }

    override func tearDown() {
        runLua("hs.closeConsole()")
        super.tearDown()
    }

    func testAllWindows() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAllWindows)), "Test failed: testAllWindows")
    }

    func testDesktop() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testDesktop)), "Test failed: testDesktop")
    }

    func testOrderedWindows() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testOrderedWindows)), "Test failed: testOrderedWindows")
    }

    func testFocusedWindow() {
        XCTAssertTrue(luaTestFromSelector(#selector(testFocusedWindow)), "Test failed: testFocusedWindow")
    }

    func testSnapshots() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testSnapshots)), "Test failed: testSnapshots")
    }

    func testTitle() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTitle)), "Test failed: testTitle")
    }

    func testRoles() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testRoles)), "Test failed: testRoles")
    }

    func testTopLeft() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTopLeft)), "Test failed: testTopLeft")
    }

    func testSize() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testSize)), "Test failed: testSize")
    }

    func testMinimize() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testMinimize)), "Test failed: testMinimize")
    }

    func testPID() {
        XCTAssertTrue(luaTestFromSelector(#selector(testPID)), "Test failed: testPID")
    }

    func testApplication() {
        XCTAssertTrue(luaTestFromSelector(#selector(testApplication)), "Test failed: testApplication")
    }

    func testTabs() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testTabs)), "Test failed: testTabs")
    }

    func testClose() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testClose)), "Test failed: testClose")
    }

    func testFullscreen() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFullscreen)), "Test failed: testFullscreen")
    }

    func testFullscreenOne() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        luaTestWithCheckAndTimeOut(5, setupCode: "testFullscreenOneSetup()", checkCode: "testFullscreenOneResult()")
    }

    func testFullscreenTwo() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testFullscreenTwoSetup()", checkCode: "testFullscreenTwoResult()")
    }
}
