import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class Base64FunctionalTests {
        @Test func testEncodeString() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._encode('hello')"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "aGVsbG8=")
            }
        }

        @Test func testDecodeString() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._decode('aGVsbG8=')"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "hello")
            }
        }

        @Test func testRoundTrip() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._decode(mod._encode('Cosmic Hammer!'))"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "Cosmic Hammer!")
            }
        }

        @Test func testEncodeEmptyString() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._encode('')"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "")
            }
        }

        @Test func testEncodeBinaryData() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // Encode a string with null bytes and high bytes
                #expect(luaEval(L, "result = mod._encode('\\x00\\x01\\xff')"))
                lua_getglobal(L, "result")
                let encoded = String(cString: lua_tostring(L, -1))
                // Verify round-trip: decode it and check length is 3
                #expect(luaEval(L, "decoded = mod._decode(result)"))
                lua_getglobal(L, "decoded")
                var len: Int = 0
                _ = lua_tolstring(L, -1, &len)
                #expect(len == 3)
                // Also verify the base64 encoding is non-empty
                #expect(!encoded.isEmpty)
            }
        }
    }
}
