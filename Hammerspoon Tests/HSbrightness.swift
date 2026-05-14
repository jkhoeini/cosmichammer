import XCTest

@objcMembers
class HSbrightness: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_brightness")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testGet() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testGet)), "Test failed: testGet")
    }

    func testSet() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testSet)), "Test failed: testSet")
    }

    func testAmbient() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAmbient)), "Test failed: testAmbient")
    }
}
