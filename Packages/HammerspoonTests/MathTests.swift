import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Math {
        init() throws { try loadLuaModule("test_math") }

        @Test func testRandomFloat() { runLuaTest() }
        @Test func testRandomFromRange() { runLuaTest() }
    }
}
