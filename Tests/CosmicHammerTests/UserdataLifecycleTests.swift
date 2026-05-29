import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libhash")
private func luaopen_hs_libhash_ud(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {

    @Suite(.serialized) final class UserdataLifecycleTests {

        /// Helper: open a Lua state with hs.hash loaded as the global "hash".
        private func withHashState(_ body: (UnsafeMutablePointer<lua_State>) throws -> Void) rethrows {
            try withLuaState { L in
                _ = luaopen_hs_libhash_ud(L)
                lua_setglobal(L, "hash")
                try body(L)
            }
        }

        @Test func testHashNewReturnsUserdata() {
            withHashState { L in
                let ok = luaEval(L, "obj = hash.new('SHA256')")
                #expect(ok, "hash.new('SHA256') should succeed")
                lua_getglobal(L, "obj")
                #expect(lua_type(L, -1) == LUA_TUSERDATA,
                    "hash.new should return userdata, got type \(lua_type(L, -1))")
            }
        }

        @Test func testHashUserdataHasMetatable() {
            withHashState { L in
                _ = luaEval(L, "obj = hash.new('MD5')")
                lua_getglobal(L, "obj")
                let hasMeta = lua_getmetatable(L, -1)
                #expect(hasMeta != 0, "hash userdata should have a metatable")
            }
        }

        @Test func testHashUserdataTostring() {
            withHashState { L in
                _ = luaEval(L, "obj = hash.new('SHA256')")
                lua_getglobal(L, "obj")
                let cstr = luaL_tolstring(L, -1, nil)!
                let str = String(cString: cstr)
                #expect(str.contains("hs.hash"), "__tostring should contain 'hs.hash'")
                #expect(str.contains("SHA256"), "__tostring should contain 'SHA256'")
            }
        }

        @Test func testHashUserdataGC() {
            // Create a hash object, set it to nil, run GC, verify no crash
            withHashState { L in
                _ = luaEval(L, "obj = hash.new('CRC32')")
                _ = luaEval(L, "obj = nil")
                _ = luaEval(L, "collectgarbage('collect')")
                _ = luaEval(L, "collectgarbage('collect')")
                // If we get here without crashing, the GC handler works
                #expect(true, "GC of hash userdata should not crash")
            }
        }

        @Test func testHashComputeSHA256() {
            withHashState { L in
                // SHA256 of "" is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
                _ = luaEval(L, "obj = hash.new('SHA256')")
                _ = luaEval(L, "obj:append('')")
                _ = luaEval(L, "obj:finish()")
                let val = luaEvalString(L, "return obj:value()")
                #expect(val == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                    "SHA256 of empty string should match known value, got \(val ?? "nil")")
            }
        }

        @Test func testHashComputeMD5() {
            withHashState { L in
                // MD5 of "hello" is 5d41402abc4b2a76b9719d911017c592
                _ = luaEval(L, "obj = hash.new('MD5')")
                _ = luaEval(L, "obj:append('hello')")
                _ = luaEval(L, "obj:finish()")
                let val = luaEvalString(L, "return obj:value()")
                #expect(val == "5d41402abc4b2a76b9719d911017c592",
                    "MD5 of 'hello' should match known value, got \(val ?? "nil")")
            }
        }

        @Test func testHashComputeCRC32() {
            withHashState { L in
                // CRC32 of "hello" is 3610a686
                _ = luaEval(L, "obj = hash.new('CRC32')")
                _ = luaEval(L, "obj:append('hello')")
                _ = luaEval(L, "obj:finish()")
                let val = luaEvalString(L, "return obj:value()")
                #expect(val == "3610a686",
                    "CRC32 of 'hello' should match known value, got \(val ?? "nil")")
            }
        }

        @Test func testHashAppendAfterFinishReturnsNil() {
            withHashState { L in
                _ = luaEval(L, "obj = hash.new('SHA256')")
                _ = luaEval(L, "obj:append('data')")
                _ = luaEval(L, "obj:finish()")
                // Appending after finish should return nil + error
                let result = luaEvalBool(L, "return obj:append('more') == nil")
                #expect(result == true,
                    "Appending after finish should return nil")
            }
        }

        @Test func testHashValueBeforeFinishIsNil() {
            withHashState { L in
                _ = luaEval(L, "obj = hash.new('SHA1')")
                _ = luaEval(L, "obj:append('test')")
                let result = luaEvalBool(L, "return obj:value() == nil")
                #expect(result == true,
                    "value() before finish should return nil")
            }
        }

        @Test func testHashTypeMethod() {
            withHashState { L in
                _ = luaEval(L, "obj = hash.new('SHA512')")
                let typeName = luaEvalString(L, "return obj:type()")
                #expect(typeName == "SHA512",
                    "type() should return 'SHA512', got \(typeName ?? "nil")")
            }
        }

        @Test func testHashMultipleAppends() {
            withHashState { L in
                // SHA256("helloworld") = 936a185caaa266bb9cbe981e9e05cb78cd732b0b3280eb944412bb6f8f8f07af
                _ = luaEval(L, "obj = hash.new('SHA256')")
                _ = luaEval(L, "obj:append('hello')")
                _ = luaEval(L, "obj:append('world')")
                _ = luaEval(L, "obj:finish()")
                let val = luaEvalString(L, "return obj:value()")
                #expect(val == "936a185caaa266bb9cbe981e9e05cb78cd732b0b3280eb944412bb6f8f8f07af",
                    "SHA256 of 'helloworld' via multiple appends should match known value, got \(val ?? "nil")")
            }
        }
    }
}
