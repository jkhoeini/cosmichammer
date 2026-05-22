import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Crash {
        init() throws { try loadLuaModule("test_crash") }

        @Test func testResidentSize() { runLuaTest() }

        @Test func testThrowTheWorld() {
            let result = runLua("testThrowTheWorld()")
            #expect(result?.contains("objc_exception_throw") == true,
                    "hs.crash.throwException() didn't throw an exception")
        }
    }
}
