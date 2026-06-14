import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class TigerStyleMediaTests {

        // MARK: - Hash assertions

        @Test func testHashSHA3_256DoesNotFireAssertions() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('SHA3_256')
                    obj:append('tigerstyle')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash.count == 64, "SHA3-256 hex digest must be 64 characters")
                #expect(!hash.isEmpty)
            }
        }

        @Test func testHashAllTypesProduceOutput() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                let types = ["CRC32", "MD5", "SHA1", "SHA256", "SHA512",
                             "SHA3_224", "SHA3_256", "SHA3_384", "SHA3_512"]
                for hashType in types {
                    #expect(luaEval(L, """
                        obj = mod.new('\(hashType)')
                        obj:append('data')
                        obj:finish()
                        result = obj:value()
                    """), "Hash type \(hashType) should succeed")
                    lua_getglobal(L, "result")
                    #expect(lua_type(L, -1) == LUA_TSTRING,
                            "\(hashType) should produce a string result")
                    let hash = String(cString: lua_tostring(L, -1))
                    #expect(!hash.isEmpty, "\(hashType) hash must not be empty")
                    lua_pop(L, 1)
                }
            }
        }

        @Test func testHashModuleRegistration() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                // Module table must contain 'new' and 'types'
                #expect(luaEval(L, "return type(mod.new) == 'function'"))
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                #expect(luaEval(L, "return type(mod.types) == 'table'"))
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                // types table must have at least the 13 known hash types
                let count = luaEvalInt(L, "return #mod.types")
                #expect(count == 13, "hashLookupTable should have 13 entries")
            }
        }

        @Test func testHashHmacWithSecret() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                #expect(luaEval(L, """
                    obj = mod.new('hmacSHA256', 'secretkey')
                    obj:append('message')
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let hash = String(cString: lua_tostring(L, -1))
                #expect(hash.count == 64, "HMAC-SHA256 hex digest must be 64 characters")
            }
        }

        @Test func testHashFinishIdempotent() {
            withModuleLoaded(luaopen_hs_libhash) { L in
                // Calling finish twice should not crash (teardown is idempotent)
                #expect(luaEval(L, """
                    obj = mod.new('MD5')
                    obj:append('test')
                    obj:finish()
                    obj:finish()
                    result = obj:value()
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING)
            }
        }
    }
}
