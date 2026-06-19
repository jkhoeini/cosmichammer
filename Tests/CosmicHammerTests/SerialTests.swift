import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Serial {
        init() throws { try loadLuaModule("test_serial") }

        @Test func testAvailablePortNames() { runLuaTest() }
        @Test func testAvailablePortPaths() { runLuaTest() }
        @Test(.requiresRealOS) func testNewFromName() { runLuaTest() }
        @Test(.requiresRealOS) func testNewFromPath() { runLuaTest() }
        @Test(.requiresRealOS) func testOpenAndClose() { runLuaTest() }
        @Test(.requiresRealOS) func testAttributes() { runLuaTest() }
    }
}
