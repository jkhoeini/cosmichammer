import XCTest

@objcMembers
class HSuielementTestsSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_uielement")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testWindowWatcher() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        twoPartTestName(#selector(testWindowWatcher), withTimeout: 5)
    }

    func testApplicationWatcher() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        twoPartTestName(#selector(testApplicationWatcher), withTimeout: 5)
    }

    func testHammerspoonElements() {
        XCTAssertTrue(luaTestFromSelector(#selector(testHammerspoonElements)), "Test failed: testHammerspoonElements")
    }

    func testSelectedText() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testSelectedText)), "Test failed: testSelectedText")
    }
}
