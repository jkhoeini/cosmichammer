import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

@_silgen_name("objc_tryCatch")
private func objc_tryCatch(_ block: @convention(block) () -> Void,
                           _ outError: UnsafeMutablePointer<NSString?>?) -> Bool

extension CosmicHammerTests {

    @Suite(.serialized) final class ObjCExceptionTests {

        // The non-exception path: verify that objc_tryCatch returns true
        // when no exception is thrown, and that catchingObjCException returns nil.
        @Test func testReturnsNilOnSuccess() {
            let result = catchingObjCException {
                _ = 1 + 1
            }
            #expect(result == nil, "catchingObjCException should return nil when no exception is thrown")
        }

        @Test func testGenericVersionReturnsValue() {
            let result: Int? = catchingObjCException {
                return 42
            }
            #expect(result == 42, "catchingObjCException<T> should return the value from the closure")
        }

        // Verify the underlying C function works for the success path
        @Test func testObjCTryCatchReturnsTrueOnSuccess() {
            var error: NSString?
            let ok = objc_tryCatch({
                _ = NSDate()
            }, &error)
            #expect(ok == true, "objc_tryCatch should return true on success")
            #expect(error == nil, "error should be nil on success")
        }

        // Verify catching an exception via Lua pcall (the supported path).
        // NSException.raise() in a bare Swift Testing context can crash the
        // test process (signal 11) because the Swift runtime's own exception
        // handling collides with @try/@catch.  The Lua pcall path (used by
        // hs.crash.throwObjCException) works correctly because the error is
        // caught in the C layer before Swift unwinds the stack.
        @Test func testCatchesExceptionViaLua() {
            withLuaState { L in
                _ = luaopen_hs_libcrash(L)
                lua_setglobal(L, "crash")

                // pcall the throwObjCException function — it should return
                // false + an error string containing the exception info
                let ok = luaEval(L, """
                    local ok, err = pcall(crash.throwObjCException, "TestException", "boom")
                    result_ok = ok
                    result_err = err
                    """)
                #expect(ok, "Lua code should not error")

                lua_getglobal(L, "result_ok")
                #expect(lua_toboolean(L, -1) == 0, "pcall should return false for caught exception")
                lua_pop(L, 1)

                lua_getglobal(L, "result_err")
                if lua_type(L, -1) == LUA_TSTRING {
                    let errMsg = String(cString: lua_tostring(L, -1)!)
                    #expect(errMsg.contains("ObjC exception"),
                        "Error should mention ObjC exception, got: \(errMsg)")
                    #expect(errMsg.contains("TestException"),
                        "Error should contain exception name, got: \(errMsg)")
                }
                lua_pop(L, 1)
            }
        }

        @Test func testErrorMessageContainsExceptionNameViaLua() {
            withLuaState { L in
                _ = luaopen_hs_libcrash(L)
                lua_setglobal(L, "crash")

                let ok = luaEval(L, """
                    local ok, err = pcall(crash.throwObjCException, "MyCustomException", "something went wrong")
                    result_err = err
                    """)
                #expect(ok, "Lua code should not error")

                lua_getglobal(L, "result_err")
                if lua_type(L, -1) == LUA_TSTRING {
                    let errMsg = String(cString: lua_tostring(L, -1)!)
                    #expect(errMsg.contains("MyCustomException"),
                        "Error should contain 'MyCustomException', got: \(errMsg)")
                    #expect(errMsg.contains("something went wrong"),
                        "Error should contain reason, got: \(errMsg)")
                }
                lua_pop(L, 1)
            }
        }
    }
}

@_silgen_name("luaopen_hs_libcrash")
private func luaopen_hs_libcrash(_ L: UnsafeMutablePointer<lua_State>?) -> Int32
