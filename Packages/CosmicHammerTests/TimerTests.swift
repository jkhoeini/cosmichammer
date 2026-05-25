import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Timer {
        init() throws { try loadLuaModule("test_timer") }

        @Test func testDays() { runLuaTest() }
        @Test func testHours() { runLuaTest() }
        @Test func testLocalTime() { runLuaTest() }
        @Test func testMinutes() { runLuaTest() }
        @Test func testSeconds() { runLuaTest() }
        @Test func testSecondsSinceEpoch() { runLuaTest() }
        @Test func testUsleep() { runLuaTest() }
        @Test func testWeeks() { runLuaTest() }
        @Test func testNew() { runLuaTest() }
        @Test func testToString() { runLuaTest() }
        @Test func testRunningAndStartStop() { runLuaTest() }
        @Test func testTriggers() { runLuaTest() }

        @Test func testDoAfter() {
            luaTestWithCheckAndTimeout(5, setup: "testDoAfterStart()", check: "testTimerValueCheck()")
        }

        @Test func testDoAt() {
            luaTestWithCheckAndTimeout(5, setup: "testDoAtStart()", check: "testTimerValueCheck()")
        }

        @Test func testDoEvery() {
            luaTestWithCheckAndTimeout(5, setup: "testDoEveryStart()", check: "testTimerValueCheck()")
        }

        @Test func testDoUntil() {
            luaTestWithCheckAndTimeout(5, setup: "testDoUntilStart()", check: "testTimerValueCheck()")
        }

        @Test func testDoWhile() {
            luaTestWithCheckAndTimeout(5, setup: "testDoWhileStart()", check: "testTimerValueCheck()")
        }

        @Test func testWaitUntil() {
            luaTestWithCheckAndTimeout(5, setup: "testWaitUntilStart()", check: "testTimerValueCheck()")
        }

        @Test func testWaitWhile() {
            luaTestWithCheckAndTimeout(5, setup: "testWaitWhileStart()", check: "testTimerValueCheck()")
        }

        @Test func testImmediateFire() {
            luaTestWithCheckAndTimeout(5, setup: "testImmediateFireStart()", check: "testTimerValueCheck()")
        }
    }
}
