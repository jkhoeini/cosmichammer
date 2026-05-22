import Testing

extension HammerspoonTests {
    @Suite @MainActor final class FS {
        init() throws {
            try loadLuaModule("test_fs")
            _ = runLua("setUp()")
        }
        @Test func testMkdir() { runLuaTest() }
        @Test func testChdir() { runLuaTest() }
        @Test func testRmdir() { runLuaTest() }
        @Test func testAttributes() { runLuaTest() }
        @Test func testTags() { runLuaTest() }
        @Test func testLinks() { runLuaTest() }
        @Test func testTouch() { runLuaTest() }
        @Test func testFileUTI() { runLuaTest() }
        @Test func testDirWalker() { runLuaTest() }
        @Test func testLockDir() { runLuaTest() }
        @Test func testLock() { runLuaTest() }

        @Test(.skipInHeadless) func testVolumes() {
            luaTestWithCheckAndTimeout(10, setup: "testVolumes()", check: "testVolumesValues()")
        }
    }
}
