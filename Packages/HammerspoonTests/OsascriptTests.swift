import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Osascript {
        init() throws { try loadLuaModule("test_osascript") }

        @Test func testJavaScriptParseError() { runLuaTest() }
        @Test func testJavaScriptAddition() { runLuaTest() }
        @Test func testJavaScriptDestructuring() { runLuaTest() }
        @Test func testJavaScriptString() { runLuaTest() }
        @Test func testJavaScriptArray() { runLuaTest() }
        @Test func testJavaScriptJsonStringify() { runLuaTest() }
        @Test func testJavaScriptJsonParse() { runLuaTest() }
        @Test func testJavaScriptJsonParseError() { runLuaTest() }
        @Test func testAppleScriptParseError() { runLuaTest() }
        @Test func testAppleScriptAddition() { runLuaTest() }
        @Test func testAppleScriptString() { runLuaTest() }
        @Test func testAppleScriptArray() { runLuaTest() }
        @Test func testAppleScriptDict() { runLuaTest() }
        @Test func testAppleScriptExecutionError() { runLuaTest() }
    }
}
