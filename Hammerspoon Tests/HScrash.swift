import XCTest

@objcMembers
class HScrash: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_crash")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testResidentSize() {
        XCTAssertTrue(luaTestFromSelector(#selector(testResidentSize)), "Test failed: testResidentSize")
    }

    func testThrowTheWorld() {
        let result = runLua("testThrowTheWorld()")
        XCTAssertTrue(result?.contains("objc_exception_throw") ?? false, "hs.crash.throwException() didn't throw an exception")
    }
}
