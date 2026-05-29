import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class JsonFunctionalTests {
        @Test func testEncodeTable() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                #expect(luaEval(L, "result = mod.encode({name = 'test', value = 42})"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let json = String(cString: lua_tostring(L, -1))
                #expect(json.contains("\"name\""))
                #expect(json.contains("\"test\""))
                #expect(json.contains("42"))
            }
        }

        @Test func testDecodeObject() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                #expect(luaEval(L, """
                    result = mod.decode('{"name":"cosmic","count":7}')
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TTABLE)

                lua_getfield(L, -1, "name")
                #expect(String(cString: lua_tostring(L, -1)) == "cosmic")
                lua_pop(L, 1)

                lua_getfield(L, -1, "count")
                #expect(lua_tonumber(L, -1) == 7.0)
            }
        }

        @Test func testDecodeArray() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                #expect(luaEval(L, "result = mod.decode('[1,2,3]')"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TTABLE)

                // Check length is 3 (Lua array)
                let len = luaL_len(L, -1)
                #expect(len == 3)

                // Check first element
                lua_rawgeti(L, -1, 1)
                #expect(lua_tonumber(L, -1) == 1.0)
                lua_pop(L, 1)

                // Check third element
                lua_rawgeti(L, -1, 3)
                #expect(lua_tonumber(L, -1) == 3.0)
            }
        }

        @Test func testRoundTripPreservesTypes() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                // Encode a table with mixed types, decode it, verify types are preserved
                #expect(luaEval(L, """
                    original = {num = 3.14, flag = true, label = "hello"}
                    json = mod.encode(original)
                    decoded = mod.decode(json)
                """))

                // Check number
                #expect(luaEval(L, "return type(decoded.num)"))
                #expect(String(cString: lua_tostring(L, -1)) == "number")
                lua_pop(L, 1)

                #expect(luaEval(L, "return decoded.num"))
                #expect(lua_tonumber(L, -1) == 3.14)
                lua_pop(L, 1)

                // Check boolean
                #expect(luaEval(L, "return type(decoded.flag)"))
                #expect(String(cString: lua_tostring(L, -1)) == "boolean")
                lua_pop(L, 1)

                #expect(luaEval(L, "return decoded.flag"))
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                // Check string
                #expect(luaEval(L, "return decoded.label"))
                #expect(String(cString: lua_tostring(L, -1)) == "hello")
            }
        }

        @Test func testEncodeNestedTable() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                #expect(luaEval(L, """
                    nested = {outer = {inner = "deep"}}
                    result = mod.encode(nested)
                """))
                lua_getglobal(L, "result")
                let json = String(cString: lua_tostring(L, -1))
                #expect(json.contains("\"inner\""))
                #expect(json.contains("\"deep\""))

                // Round-trip and verify nested access
                #expect(luaEval(L, "decoded = mod.decode(result)"))
                #expect(luaEvalString(L, "return decoded.outer.inner") == "deep")
            }
        }

        @Test func testDecodeNull() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                #expect(luaEval(L, """
                    result = mod.decode('{"key": null}')
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TTABLE)
                // JSON null should map to Lua nil (absent key)
                lua_getfield(L, -1, "key")
                #expect(lua_type(L, -1) == LUA_TNIL)
            }
        }

        @Test func testEncodeNonTableFails() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                // Encoding a string (not a table) should error
                let err = luaErrorMsg(L, "mod.encode('not a table')")
                #expect(err != nil)
            }
        }

        @Test func testDecodeMalformedFails() {
            withModuleLoaded(luaopen_hs_libjson) { L in
                // Decoding invalid JSON should return nil
                #expect(luaEval(L, "result = mod.decode('{bad json}')"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TNIL)
            }
        }
    }
}
