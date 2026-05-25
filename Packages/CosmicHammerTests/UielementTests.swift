import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Uielement {
        init() throws { try loadLuaModule("test_uielement") }

        @Test(.skipInHeadless) func testWindowWatcher() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.skipInHeadless) func testApplicationWatcher() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testCosmicHammerElements() { runLuaTest() }
        @Test(.skipInHeadless) func testSelectedText() { runLuaTest() }
    }
}
