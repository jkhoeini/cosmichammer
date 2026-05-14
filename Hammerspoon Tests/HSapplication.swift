import XCTest

@objcMembers
class HSapplicationTests: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_application")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testInitWithPidFailures() {
        XCTAssertTrue(luaTestFromSelector(#selector(testInitWithPidFailures)), "Test failed: testInitWithPidFailures")
    }

    func testInitWithPid() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testInitWithPid)), "Test failed: testInitWithPid")
    }

    func testAttributesFromBundleID() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAttributesFromBundleID)), "Test failed: testAttributesFromBundleID")
    }

    func testBasicAttributes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testBasicAttributes)), "Test failed: testBasicAttributes")
    }

    func testFrontmostApplication() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFrontmostApplication)), "Test failed: testFrontmostApplication")
    }

    func testRunningApplications() {
        XCTAssertTrue(luaTestFromSelector(#selector(testRunningApplications)), "Test failed: testRunningApplications")
    }

    func testHiding() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        luaTestWithCheckAndTimeOut(5, setupCode: "testHiding()", checkCode: "testHidingValues()")
    }

    func testKilling() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testKilling()", checkCode: "testKillingValues()")
    }

    func testForceKilling() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testForceKilling()", checkCode: "testForceKillingValues()")
    }

    func testWindows() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        luaTestWithCheckAndTimeOut(5, setupCode: "testWindows()", checkCode: "testWindowsValues()")
    }

    func testMenus() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMenus)), "Test failed: testMenus")
    }

    func testMenusAsync() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testMenusAsync()", checkCode: "testMenusAsyncValues()")
    }

    func testUTI() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUTI)), "Test failed: testUTI")
    }

    func testLocalizationFunctions() {
        XCTAssertTrue(luaTestFromSelector(#selector(testLocalizationFunctions)), "Test failed: testLocalizationFunctions")
    }
}
