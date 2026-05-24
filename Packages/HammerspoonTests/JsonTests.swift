import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Json {
        init() throws { try loadLuaModule("test_json") }

        @Test func testEncodeDecode() { runLuaTest() }

        @Test func testEncodeDecodeFailures() { runLuaTest() }

        @Test func testReadWrite() { runLuaTest() }
    }
}
