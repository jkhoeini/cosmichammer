import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Inspect {
        init() throws { try loadLuaModule("test_inspect") }

        @Test func testSimpleInspect() { runLuaTest() }
    }
}
