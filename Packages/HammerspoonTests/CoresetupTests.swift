import Testing
import Foundation

extension HammerspoonTests {
    @Suite @MainActor final class Coresetup {
        init() throws { try loadLuaModule("test_coresetup") }
        @Test func testOSExit() { runLuaTest() }
        @Test func testConfigDir() { runLuaTest() }
        @Test func testDocstringsJSONFile() { runLuaTest() }
        @Test func testProcessInfo() { runLuaTest() }
        @Test func testAccessibilityState() { runLuaTest() }
        @Test func testAutoLaunch() { runLuaTest() }
        @Test func testAutomaticallyCheckForUpdates() { runLuaTest() }
        @Test func testCheckForUpdates() { runLuaTest() }
        @Test func testCleanUTF8forConsole() { runLuaTest() }
        @Test func testConsoleOnTop() { runLuaTest() }
        @Test func testDockIcon() { runLuaTest() }
        @Test func testGetObjectMetatable() { runLuaTest() }
        @Test func testMenuIcon() { runLuaTest() }

        @Test func testShutdownCallback() {
            HScoresetupHelper.resetShutdownFlag()
            HScoresetupHelper.registerShutdownLib()
            runLuaTest()
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
                if HScoresetupHelper.shutdownFired() { return }
            }
            Issue.record("hs.shutdownCallback was not called successfully")
        }
    }
}
