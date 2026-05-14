import XCTest

@objcMembers
class HShotkey: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_hotkey")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testAssignable() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAssignable)), "Test failed: testAssignable")
    }

    func testGetHotkeys() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetHotkeys)), "Test failed: testGetHotkeys")
    }

    func testGetSystemAssigned() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testGetSystemAssigned)), "Test failed: testGetSystemAssigned")
    }

    func testBasicHotkey() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        twoPartTestName(#selector(testBasicHotkey), timeout: 2)
    }

    func testRepeatingHotkey() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        twoPartTestName(#selector(testRepeatingHotkey), timeout: 5)
    }

    func testHotkeyStates() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        twoPartTestName(#selector(testHotkeyStates), timeout: 5)
    }
}
