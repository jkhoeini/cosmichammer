import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Alert {
        init() throws { try loadLuaModule("test_alert") }

        @Test func testAlert() { runLuaTest() }
        @Test func testCloseAll() { runLuaTest() }
    }
}
