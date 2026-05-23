import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Serial {
        init() throws { try loadLuaModule("test_serial") }

        @Test func testAvailablePortNames() { runLuaTest() }
        @Test func testAvailablePortPaths() { runLuaTest() }
        @Test(.skipInHeadless) func testNewFromName() { runLuaTest() }
        @Test(.skipInHeadless) func testNewFromPath() { runLuaTest() }
        @Test(.skipInHeadless) func testOpenAndClose() { runLuaTest() }
        @Test(.skipInHeadless) func testAttributes() { runLuaTest() }
    }
}
