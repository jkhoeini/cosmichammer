import Testing

extension HammerspoonTests {
    @Suite @MainActor final class RequireAll {
        @Test func testRequireAll() {
            let res = runLua("return testrequires()") ?? ""
            let errors = res.components(separatedBy: "\u{1F4A9}")
                .filter { !$0.isEmpty && !$0.contains("failed to create new local port") }
            #expect(errors.isEmpty, "Some modules failed to load: \(errors)")
        }
    }
}
