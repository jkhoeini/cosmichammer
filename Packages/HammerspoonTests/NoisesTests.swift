import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Noises {
        init() throws { try loadLuaModule("test_noises") }

        @Test func testStartStop() { runLuaTest() }
    }
}
