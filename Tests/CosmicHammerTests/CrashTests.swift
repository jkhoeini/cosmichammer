import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Crash {
        init() throws { try loadLuaModule("test_crash") }

        @Test func testResidentSize() { runLuaTest() }

        // Disabled: NSException.raise() inside the swift-testing process
        // causes SIGSEGV (signal 11) regardless of @try/@catch or Lua pcall,
        // killing the entire test runner and preventing all subsequent suites
        // from executing.  The non-throwing ObjC exception infrastructure is
        // verified by ObjCExceptionTests.testReturnsNilOnSuccess et al.
        @Test(.disabled("NSException.raise() crashes the swift-testing process (signal 11)"))
        func testThrowTheWorld() {}
    }
}
