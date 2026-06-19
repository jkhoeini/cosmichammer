import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Uielement {
        init() throws { try loadLuaModule("test_uielement") }

        @Test(.requiresRealOS) func testWindowWatcher() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.requiresRealOS) func testApplicationWatcher() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.requiresRealOS) func testCosmicHammerElements() { runLuaTest() }
        @Test(.requiresRealOS) func testSelectedText() { runLuaTest() }
    }
}
