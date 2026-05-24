import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Screen {
        init() throws { try loadLuaModule("test_screen") }

        @Test func testMainScreen() { runLuaTest() }
        @Test func testPrimaryScreen() { runLuaTest() }
        @Test func testAllScreens() { runLuaTest() }
        @Test func testFind() { runLuaTest() }
        @Test func testScreenPositions() { runLuaTest() }
        @Test func testAvailableModes() { runLuaTest() }
        @Test func testCurrentMode() { runLuaTest() }
        @Test(.skipInHeadless) func testSetMode() { runLuaTest() }
        @Test func testSetOrigin() { runLuaTest() }
        @Test func testFrames() { runLuaTest() }
        @Test func testFromUnitRect() { runLuaTest() }
        @Test func testBrightness() { runLuaTest() }
        @Test func testGamma() { runLuaTest() }
        @Test func testId() { runLuaTest() }
        @Test func testName() { runLuaTest() }
        @Test func testPosition() { runLuaTest() }
        @Test func testNextPrevious() { runLuaTest() }
        @Test func testRotation() { runLuaTest() }
        @Test func testSetPrimary() { runLuaTest() }
        @Test func testScreenshots() { runLuaTest() }
        @Test func testToUnitRect() { runLuaTest() }
    }
}
