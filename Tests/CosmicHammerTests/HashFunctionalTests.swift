import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class HashFunctionalTests {
        @Test func testSHA256() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('SHA256')
                    obj:append('hello')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            }
        }

        @Test func testMD5() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('MD5')
                    obj:append('hello')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash == "5d41402abc4b2a76b9719d911017c592")
            }
        }

        @Test func testCRC32() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('CRC32')
                    obj:append('hello')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash == "3610a686")
            }
        }

        @Test func testSHA1() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('SHA1')
                    obj:append('hello')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
            }
        }

        @Test func testSHA512() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('SHA512')
                    obj:append('hello')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash == "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043")
            }
        }

        @Test func testHMACSHA256() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('hmacSHA256', 'secret')
                    obj:append('hello')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                // HMAC-SHA256("secret", "hello")
                #expect(hash == "88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b")
            }
        }

        @Test func testNewObjectAppendFinish() {
            // Test the streaming API: create, append multiple chunks, finish, get value
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('SHA256')
                    obj:append('hel')
                    obj:append('lo')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                let hash = String(cString: lua_tostring(L, -1))
                // SHA256("hello") computed in two chunks should equal single-shot
                #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            }
        }
    }
}
