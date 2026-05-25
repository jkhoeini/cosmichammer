import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Brightness {
        init() throws { try loadLuaModule("test_brightness") }

        @Test(.skipInHeadless) func testGet() { runLuaTest() }
        @Test(.skipInHeadless) func testSet() { runLuaTest() }
        @Test func testAmbient() { runLuaTest() }
    }
}
