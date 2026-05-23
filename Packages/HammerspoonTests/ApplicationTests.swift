import Testing
import Foundation

extension HammerspoonTests {
    @Suite @MainActor final class Application {
        init() throws { try loadLuaModule("test_application") }

        @Test func testInitWithPidFailures() { runLuaTest() }
        @Test(.skipInHeadless) func testInitWithPid() { runLuaTest() }
        @Test func testAttributesFromBundleID() { runLuaTest() }
        @Test func testBasicAttributes() { runLuaTest() }
        @Test(.skipInHeadless) func testFrontmostApplication() { runLuaTest() }
        @Test func testRunningApplications() { runLuaTest() }
        @Test func testMenus() { runLuaTest() }
        @Test func testUTI() { runLuaTest() }
        @Test func testLocalizationFunctions() { runLuaTest() }

        @Test(.skipInHeadless) func testHiding() {
            luaTestWithCheckAndTimeout(5, setup: "testHiding()", check: "testHidingValues()")
        }

        @Test func testKilling() {
            luaTestWithCheckAndTimeout(5, setup: "testKilling()", check: "testKillingValues()")
        }

        @Test func testForceKilling() {
            luaTestWithCheckAndTimeout(5, setup: "testForceKilling()", check: "testForceKillingValues()")
        }

        @Test(.skipInHeadless) func testWindows() {
            luaTestWithCheckAndTimeout(5, setup: "testWindows()", check: "testWindowsValues()")
        }

        @Test func testMenusAsync() {
            luaTestWithCheckAndTimeout(5, setup: "testMenusAsync()", check: "testMenusAsyncValues()")
        }
    }
}
