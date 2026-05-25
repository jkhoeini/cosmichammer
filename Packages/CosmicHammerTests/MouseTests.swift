import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Mouse {
        init() throws { try loadLuaModule("test_mouse") }

        @Test(.skipInHeadless) func testMouseCount() { runLuaTest() }
        @Test(.skipInHeadless) func testMouseNames() { runLuaTest() }
        @Test func testMouseAbsolutePosition() { runLuaTest() }
        @Test func testScrollDirection() { runLuaTest() }
        @Test func testMouseTrackingSpeed() { runLuaTest() }
    }
}
