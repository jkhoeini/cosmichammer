import Testing
import CLua
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libcrash")
private func luaopen_hs_libcrash(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class CrashFunctionalTests {
        @Test func testResidentSize() {
            withModuleLoaded(luaopen_hs_libcrash) { L in
                #expect(luaEval(L, "result = mod.residentSize()"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                let size = lua_tointeger(L, -1)
                // Resident size should be a positive number (at least a few MB)
                #expect(size > 0, "residentSize should be positive, got \(size)")
            }
        }

        // Disabled: NSException.raise() inside the swift-testing process
        // causes SIGSEGV (signal 11) regardless of @try/@catch or Lua pcall,
        // killing the entire test runner and preventing all subsequent suites
        // from executing.  The non-throwing paths are verified by
        // ObjCExceptionTests.testReturnsNilOnSuccess et al.
        @Test(.disabled("NSException.raise() crashes the swift-testing process (signal 11)"))
        func testObjCExceptionCaught() {}
    }
}
