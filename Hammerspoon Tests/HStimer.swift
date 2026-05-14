import XCTest

@objcMembers
class HStimerSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_timer")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testDays() {
        XCTAssertTrue(luaTestFromSelector(#selector(testDays)), "Test failed: testDays")
    }

    func testHours() {
        XCTAssertTrue(luaTestFromSelector(#selector(testHours)), "Test failed: testHours")
    }

    func testLocalTime() {
        XCTAssertTrue(luaTestFromSelector(#selector(testLocalTime)), "Test failed: testLocalTime")
    }

    func testMinutes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMinutes)), "Test failed: testMinutes")
    }

    func testSeconds() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSeconds)), "Test failed: testSeconds")
    }

    func testSecondsSinceEpoch() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSecondsSinceEpoch)), "Test failed: testSecondsSinceEpoch")
    }

    func testUsleep() {
        XCTAssertTrue(luaTestFromSelector(#selector(testUsleep)), "Test failed: testUsleep")
    }

    func testWeeks() {
        XCTAssertTrue(luaTestFromSelector(#selector(testWeeks)), "Test failed: testWeeks")
    }

    func testDoAfter() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testDoAfterStart()", checkCode: "testTimerValueCheck()")
    }

    func testDoAt() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testDoAtStart()", checkCode: "testTimerValueCheck()")
    }

    func testDoEvery() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testDoEveryStart()", checkCode: "testTimerValueCheck()")
    }

    func testDoUntil() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testDoUntilStart()", checkCode: "testTimerValueCheck()")
    }

    func testDoWhile() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testDoWhileStart()", checkCode: "testTimerValueCheck()")
    }

    func testWaitUntil() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testWaitUntilStart()", checkCode: "testTimerValueCheck()")
    }

    func testWaitWhile() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testWaitWhileStart()", checkCode: "testTimerValueCheck()")
    }

    func testNew() {
        XCTAssertTrue(luaTestFromSelector(#selector(testNew)), "Test failed: testNew")
    }

    func testToString() {
        XCTAssertTrue(luaTestFromSelector(#selector(testToString)), "Test failed: testToString")
    }

    func testRunningAndStartStop() {
        XCTAssertTrue(luaTestFromSelector(#selector(testRunningAndStartStop)), "Test failed: testRunningAndStartStop")
    }

    func testTriggers() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTriggers)), "Test failed: testTriggers")
    }

    func testImmediateFire() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testImmediateFireStart()", checkCode: "testTimerValueCheck()")
    }
}
