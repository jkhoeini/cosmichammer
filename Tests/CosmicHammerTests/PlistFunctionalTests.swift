import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class PlistFunctionalTests {
        @Test func testReadWriteRoundTrip() throws {
            withModuleLoaded(luaopen_hs_libplist) { L in
                let tmpPath = NSTemporaryDirectory() + "hs_test_\(UUID().uuidString).plist"
                defer { try? FileManager.default.removeItem(atPath: tmpPath) }

                let escapedPath = tmpPath.replacingOccurrences(of: "'", with: "\\'")

                // Write a plist file
                #expect(luaEval(L, """
                    result = mod.write('\(escapedPath)', {name = 'test', count = 42})
                """))
                lua_getglobal(L, "result")
                #expect(lua_toboolean(L, -1) != 0, "plist write failed")
                lua_pop(L, 1)

                // Read it back
                #expect(luaEval(L, "data = mod.read('\(escapedPath)')"))
                lua_getglobal(L, "data")
                #expect(lua_type(L, -1) == LUA_TTABLE)

                lua_getfield(L, -1, "name")
                #expect(String(cString: lua_tostring(L, -1)) == "test")
                lua_pop(L, 1)

                lua_getfield(L, -1, "count")
                #expect(lua_tonumber(L, -1) == 42.0)
            }
        }

        @Test func testEncodeXML() {
            withModuleLoaded(luaopen_hs_libplist) { L in
                // writeString with binary=false (default) produces XML plist
                #expect(luaEval(L, """
                    result = mod.writeString({greeting = 'hi'})
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING)

                var len: Int = 0
                let ptr = lua_tolstring(L, -1, &len)!
                let data = Data(bytes: ptr, count: len)
                let str = String(data: data, encoding: .utf8)!
                #expect(str.contains("plist"))
                #expect(str.contains("greeting"))
            }
        }

        @Test func testEncodeBinary() {
            withModuleLoaded(luaopen_hs_libplist) { L in
                // writeString with binary=true produces binary plist (starts with "bplist")
                #expect(luaEval(L, """
                    result = mod.writeString({key = 'val'}, true)
                """))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING)

                var len: Int = 0
                let ptr = lua_tolstring(L, -1, &len)!
                let data = Data(bytes: ptr, count: len)
                // Binary plist starts with "bplist"
                #expect(data.count >= 6)
                let prefix = String(data: data.prefix(6), encoding: .ascii)
                #expect(prefix == "bplist")
            }
        }
    }
}
