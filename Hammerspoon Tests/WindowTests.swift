import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Window {
        init() throws { try loadLuaModule("test_window") }
        @Test func testAllWindows() { runLuaTest() }
        @Test(.skipInHeadless) func testDesktop() { runLuaTest() }
        @Test(.skipInHeadless) func testOrderedWindows() { runLuaTest() }
        @Test func testFocusedWindow() { runLuaTest() }
        @Test(.skipInHeadless) func testSnapshots() { runLuaTest() }
        @Test func testTitle() { runLuaTest() }
        @Test(.skipInHeadless) func testRoles() { runLuaTest() }
        @Test func testTopLeft() { runLuaTest() }
        @Test(.skipInHeadless) func testSize() { runLuaTest() }
        @Test(.skipInHeadless) func testMinimize() { runLuaTest() }
        @Test func testPID() { runLuaTest() }
        @Test func testApplication() { runLuaTest() }
        @Test(.skipInHeadless) func testTabs() { runLuaTest() }
        @Test(.skipInHeadless) func testClose() { runLuaTest() }
        @Test(.skipInHeadless) func testFullscreen() { runLuaTest() }

        @Test(.skipInHeadless) func testFullscreenOne() {
            luaTestWithCheckAndTimeout(5, setup: "testFullscreenOneSetup()", check: "testFullscreenOneResult()")
        }

        @Test func testFullscreenTwo() {
            luaTestWithCheckAndTimeout(5, setup: "testFullscreenTwoSetup()", check: "testFullscreenTwoResult()")
        }
    }
}
