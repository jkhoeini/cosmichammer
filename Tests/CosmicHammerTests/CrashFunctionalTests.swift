import Testing
import CLua
@testable import HSSwiftExtensions

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

        @Test func testObjCExceptionCaught() {
            withModuleLoaded(luaopen_hs_libcrash) { L in
                // throwObjCException should raise a Lua error that pcall can catch
                #expect(luaEval(L, """
                    ok, err = pcall(mod.throwObjCException, 'TestException', 'test message')
                    caught = not ok
                """))
                lua_getglobal(L, "caught")
                #expect(lua_toboolean(L, -1) != 0, "ObjC exception was not caught by pcall")
                lua_pop(L, 1)

                // The error message should mention ObjC exception
                lua_getglobal(L, "err")
                if lua_type(L, -1) == LUA_TSTRING {
                    let errMsg = String(cString: lua_tostring(L, -1))
                    #expect(errMsg.contains("ObjC exception"))
                }
            }
        }
    }
}
