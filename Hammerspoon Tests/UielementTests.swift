import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Uielement {
        init() throws { try loadLuaModule("test_uielement") }

        @Test(.skipInHeadless) func testWindowWatcher() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.skipInHeadless) func testApplicationWatcher() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testHammerspoonElements() { runLuaTest() }
        @Test(.skipInHeadless) func testSelectedText() { runLuaTest() }
    }
}
