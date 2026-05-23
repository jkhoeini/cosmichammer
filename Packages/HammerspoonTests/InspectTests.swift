import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Inspect {
        init() throws { try loadLuaModule("test_inspect") }

        @Test func testSimpleInspect() { runLuaTest() }
    }
}
