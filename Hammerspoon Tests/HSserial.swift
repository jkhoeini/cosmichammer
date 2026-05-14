import XCTest

@objcMembers
class HSserialSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_serial")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testAvailablePortNames() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAvailablePortNames)), "Test failed: testAvailablePortNames")
    }

    func testAvailablePortPaths() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAvailablePortPaths)), "Test failed: testAvailablePortPaths")
    }

    func testNewFromName() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testNewFromName)), "Test failed: testNewFromName")
    }

    func testNewFromPath() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testNewFromPath)), "Test failed: testNewFromPath")
    }

    func testOpenAndClose() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testOpenAndClose)), "Test failed: testOpenAndClose")
    }

    func testAttributes() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testAttributes)), "Test failed: testAttributes")
    }
}
