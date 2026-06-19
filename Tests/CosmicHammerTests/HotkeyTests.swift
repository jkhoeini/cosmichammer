import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Hotkey {
        init() throws { try loadLuaModule("test_hotkey") }

        @Test func testAssignable() { runLuaTest() }
        @Test func testGetHotkeys() { runLuaTest() }
        @Test(.requiresRealOS) func testGetSystemAssigned() { runLuaTest() }

        @Test(.requiresRealOS) func testBasicHotkey() {
            runTwoPartLuaTest(timeout: 2)
        }

        @Test(.requiresRealOS) func testRepeatingHotkey() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.requiresRealOS) func testHotkeyStates() {
            runTwoPartLuaTest(timeout: 5)
        }
    }
}
