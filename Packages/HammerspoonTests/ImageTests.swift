import Testing

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Image {
        init() throws { try loadLuaModule("test_image") }

        @Test func testGetExifFromPath() { runLuaTest() }
    }
}
