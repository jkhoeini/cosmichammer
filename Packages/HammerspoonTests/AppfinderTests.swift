import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Appfinder {
        init() throws { try loadLuaModule("test_appfinder") }

        @Test func testAppFromName() { runLuaTest() }
        @Test func testAppFromWindowTitle() { runLuaTest() }
        @Test func testAppFromWindowTitlePattern() { runLuaTest() }
        @Test func testWindowFromWindowTitle() { runLuaTest() }
        @Test func testWindowFromWindowTitlePattern() { runLuaTest() }
    }
}
