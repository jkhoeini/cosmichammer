import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Hotkey {
        init() throws { try loadLuaModule("test_hotkey") }

        @Test func testAssignable() { runLuaTest() }
        @Test func testGetHotkeys() { runLuaTest() }
        @Test(.skipInHeadless) func testGetSystemAssigned() { runLuaTest() }

        @Test(.skipInHeadless) func testBasicHotkey() {
            runTwoPartLuaTest(timeout: 2)
        }

        @Test(.skipInHeadless) func testRepeatingHotkey() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.skipInHeadless) func testHotkeyStates() {
            runTwoPartLuaTest(timeout: 5)
        }
    }
}
