import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class TestCaseSelf {
        @Test func testrunLua() {
            let result = runLua("return 'hello world!'")
            #expect(result == "hello world!", "Lua code evaluation is not working")
        }

        @Test func testTestLuaSuccess() {
            let result = runLua("return 'Success'")
            #expect(result == "Success")
        }
    }
}
