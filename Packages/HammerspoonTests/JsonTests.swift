import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Json {
        init() throws { try loadLuaModule("test_json") }

        @Test func testEncodeDecode() { runLuaTest() }

        @Test func testEncodeDecodeFailures() {
            let result = runLua("testEncodeDecodeFailures()")
            #expect(result != "Success", "Expected failure but got Success")
        }

        @Test func testReadWrite() { runLuaTest() }
    }
}
