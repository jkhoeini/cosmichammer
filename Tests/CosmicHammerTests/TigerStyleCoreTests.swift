import Testing
import Foundation
import Cocoa
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite(.serialized) final class TigerStyleCoreTests {

        // MARK: - lua_pushany stack balance assertion

        @Test func pushAnyLeavesExactlyOneValueOnStack() {
            withLuaState { L in
                let baseTop = lua_gettop(L)

                lua_pushany(L, "hello")
                #expect(lua_gettop(L) == baseTop + 1, "pushany(string) must push exactly 1 value")
                lua_pop(L, 1)

                lua_pushany(L, 42)
                #expect(lua_gettop(L) == baseTop + 1, "pushany(int) must push exactly 1 value")
                lua_pop(L, 1)

                lua_pushany(L, nil)
                #expect(lua_gettop(L) == baseTop + 1, "pushany(nil) must push exactly 1 value")
                lua_pop(L, 1)

                lua_pushany(L, ["a": 1, "b": 2] as [String: Any])
                #expect(lua_gettop(L) == baseTop + 1, "pushany(dict) must push exactly 1 value")
                lua_pop(L, 1)

                lua_pushany(L, [1, 2, 3] as [Any])
                #expect(lua_gettop(L) == baseTop + 1, "pushany(array) must push exactly 1 value")
                lua_pop(L, 1)

                #expect(lua_gettop(L) == baseTop, "stack must be balanced after all pushany operations")
            }
        }

        // MARK: - Geometry round-trip preserves stack balance

        @Test func geometryTableRoundTripPreservesStack() {
            withLuaState { L in
                let baseTop = lua_gettop(L)

                // Push a point table, then read it back
                lua_pushNSPoint(L, NSPoint(x: 10.5, y: 20.3))
                #expect(lua_gettop(L) == baseTop + 1)
                let point = lua_tableToPoint(L, at: -1)
                #expect(lua_gettop(L) == baseTop + 1, "tableToPoint must not change the stack")
                #expect(point.x == 10.5)
                #expect(point.y == 20.3)
                lua_pop(L, 1)

                // Push a size table, then read it back
                lua_pushNSSize(L, NSSize(width: 100, height: 200))
                #expect(lua_gettop(L) == baseTop + 1)
                let size = lua_tableToSize(L, at: -1)
                #expect(lua_gettop(L) == baseTop + 1, "tableToSize must not change the stack")
                #expect(size.width == 100)
                #expect(size.height == 200)
                lua_pop(L, 1)

                // Push a rect table, then read it back
                lua_pushNSRect(L, NSRect(x: 1, y: 2, width: 3, height: 4))
                #expect(lua_gettop(L) == baseTop + 1)
                let rect = lua_tableToRect(L, at: -1)
                #expect(lua_gettop(L) == baseTop + 1, "tableToRect must not change the stack")
                #expect(rect.origin.x == 1)
                #expect(rect.origin.y == 2)
                #expect(rect.size.width == 3)
                #expect(rect.size.height == 4)
                lua_pop(L, 1)

                #expect(lua_gettop(L) == baseTop, "stack must be balanced after geometry round-trips")
            }
        }

        // MARK: - lua_tovalue recursive depth safety

        @Test func toValueHandlesDeeplyNestedTablesWithoutCrash() {
            withLuaState { L in
                let baseTop = lua_gettop(L)

                // Build a deeply nested table: {inner = {inner = {inner = ... {value = 42}}}}
                let depth = 40
                var luaCode = "return "
                for _ in 0..<depth {
                    luaCode += "{inner="
                }
                luaCode += "{value=42}"
                for _ in 0..<depth {
                    luaCode += "}"
                }

                let result = luaL_dostring(L, luaCode)
                #expect(result == LUA_OK, "deeply nested table construction must succeed")

                // Pull it back out - should not crash
                let value = lua_tovalue(L, at: -1)
                #expect(value != nil, "tovalue should return something for nested tables")
                lua_pop(L, 1)
                #expect(lua_gettop(L) == baseTop, "stack must be balanced after tovalue")
            }
        }

        // MARK: - LuaBoot.pushContext stack assertion

        @Test func pushContextLeavesOneTableOnStack() {
            withLuaState { L in
                let baseTop = lua_gettop(L)
                let context = LuaBoot.Context(
                    extensionsPath: "/test/extensions",
                    configFileDisplayPath: "/test/init.lua",
                    configFilePath: "/test/init.lua",
                    configDir: "/test",
                    dataDir: "/test/data",
                    docsJSONPath: "/test/docs.json",
                    hasInitFile: true,
                    autoloadExtensions: false
                )
                LuaBoot.pushContext(L, context)
                #expect(lua_gettop(L) == baseTop + 1, "pushContext must push exactly one value")
                #expect(lua_type(L, -1) == LUA_TTABLE, "pushContext must push a table")

                // Verify context fields are present
                lua_getfield(L, -1, "extensionsPath")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                #expect(String(cString: lua_tostring(L, -1)) == "/test/extensions")
                lua_pop(L, 1)

                lua_getfield(L, -1, "hasInitFile")
                #expect(lua_type(L, -1) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_pop(L, 1)
                #expect(lua_gettop(L) == baseTop)
            }
        }

        // MARK: - Color table round-trip preserves stack

        @Test func colorTableRoundTripPreservesStack() {
            withLuaState { L in
                let baseTop = lua_gettop(L)

                let originalColor = NSColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0)
                let pushed = lua_pushNSColor(L, originalColor)
                #expect(pushed, "pushNSColor must succeed for sRGB-convertible color")
                #expect(lua_gettop(L) == baseTop + 1, "pushNSColor must push exactly one value")

                let readBack = tableToNSColor(L, at: -1)
                #expect(readBack != nil, "tableToNSColor must return a color for a valid color table")
                #expect(lua_gettop(L) == baseTop + 1, "tableToNSColor must not change the stack")

                lua_pop(L, 1)
                #expect(lua_gettop(L) == baseTop, "stack must be balanced after color round-trip")
            }
        }
    }
}
