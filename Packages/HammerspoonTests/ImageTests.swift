import Testing

extension HammerspoonTests {
    @Suite @MainActor final class Image {
        init() throws { try loadLuaModule("test_image") }

        @Test func testGetExifFromPath() { runLuaTest() }
    }
}
