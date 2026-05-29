import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Crash {
        init() throws { try loadLuaModule("test_crash") }

        @Test func testResidentSize() { runLuaTest() }

        @Test func testThrowTheWorld() {
            let result = runLua("testThrowTheWorld()")
            #expect(result?.contains("ObjC exception") == true,
                    "hs.crash.throwObjCException() didn't produce an ObjC exception error")
        }
    }
}
