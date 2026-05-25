import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Base64 {
        init() throws { try loadLuaModule("test_base64") }

        @Test func testEncode() { runLuaTest() }
        @Test func testDecode() { runLuaTest() }
    }
}
