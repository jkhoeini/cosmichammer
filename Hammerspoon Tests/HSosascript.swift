import XCTest

@objcMembers
class HSosascriptSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_osascript")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testJavaScriptParseError() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptParseError)), "Test failed: testJavaScriptParseError")
    }

    func testJavaScriptAddition() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptAddition)), "Test failed: testJavaScriptAddition")
    }

    func testJavaScriptDestructuring() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptDestructuring)), "Test failed: testJavaScriptDestructuring")
    }

    func testJavaScriptString() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptString)), "Test failed: testJavaScriptString")
    }

    func testJavaScriptArray() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptArray)), "Test failed: testJavaScriptArray")
    }

    func testJavaScriptJsonStringify() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptJsonStringify)), "Test failed: testJavaScriptJsonStringify")
    }

    func testJavaScriptJsonParse() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptJsonParse)), "Test failed: testJavaScriptJsonParse")
    }

    func testJavaScriptJsonParseError() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJavaScriptJsonParseError)), "Test failed: testJavaScriptJsonParseError")
    }

    func testAppleScriptParseError() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppleScriptParseError)), "Test failed: testAppleScriptParseError")
    }

    func testAppleScriptAddition() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppleScriptAddition)), "Test failed: testAppleScriptAddition")
    }

    func testAppleScriptString() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppleScriptString)), "Test failed: testAppleScriptString")
    }

    func testAppleScriptArray() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppleScriptArray)), "Test failed: testAppleScriptArray")
    }

    func testAppleScriptDict() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppleScriptDict)), "Test failed: testAppleScriptDict")
    }

    func testAppleScriptExecutionError() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAppleScriptExecutionError)), "Test failed: testAppleScriptExecutionError")
    }
}
