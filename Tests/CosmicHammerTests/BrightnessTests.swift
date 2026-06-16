import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Brightness {
        init() throws { try loadLuaModule("test_brightness") }

        @Test func testGet() { runLuaTest() }
        @Test func testSet() { runLuaTest() }
        @Test func testAmbient() { runLuaTest() }
    }
}
