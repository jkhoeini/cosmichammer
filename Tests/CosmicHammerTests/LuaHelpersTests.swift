import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite(.serialized) final class LuaHelpersTests {

        // MARK: - Basic types

        @Test func testPushNil() {
            withLuaState { L in
                lua_pushany(L, nil)
                #expect(lua_type(L, -1) == LUA_TNIL)
            }
        }

        @Test func testPushBool() {
            withLuaState { L in
                lua_pushany(L, true)
                #expect(lua_type(L, -1) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -1) == 1)

                lua_pushany(L, false)
                #expect(lua_type(L, -1) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -1) == 0)
            }
        }

        @Test func testPushInt() {
            withLuaState { L in
                lua_pushany(L, 42)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_isinteger(L, -1) != 0)
                #expect(lua_tointeger(L, -1) == 42)
            }
        }

        @Test func testPushDouble() {
            withLuaState { L in
                lua_pushany(L, 3.14)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_tonumber(L, -1) == 3.14)
            }
        }

        @Test func testPushString() {
            withLuaState { L in
                lua_pushany(L, "hello")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let s = String(cString: lua_tostring(L, -1)!)
                #expect(s == "hello")
            }
        }

        @Test func testPushEmptyString() {
            withLuaState { L in
                lua_pushany(L, "")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                var len: Int = 0
                _ = lua_tolstring(L, -1, &len)
                #expect(len == 0)
            }
        }

        // MARK: - NSNumber edge cases

        @Test func testPushNSNumberInteger() {
            withLuaState { L in
                lua_pushany(L, NSNumber(value: 99) as Any)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_isinteger(L, -1) != 0)
                #expect(lua_tointeger(L, -1) == 99)
            }
        }

        @Test func testPushNSNumberFloat() {
            withLuaState { L in
                lua_pushany(L, NSNumber(value: 2.718) as Any)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                let val = lua_tonumber(L, -1)
                #expect(abs(val - 2.718) < 0.001)
            }
        }

        @Test func testPushCFBooleanTrue() {
            withLuaState { L in
                lua_pushany(L, kCFBooleanTrue as Any)
                #expect(lua_type(L, -1) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -1) == 1)
            }
        }

        @Test func testPushCFBooleanFalse() {
            withLuaState { L in
                lua_pushany(L, kCFBooleanFalse as Any)
                #expect(lua_type(L, -1) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -1) == 0)
            }
        }

        @Test func testPushNSNumberOne() {
            withLuaState { L in
                // NSNumber(value: 1) must push as a Lua number, NOT a boolean
                lua_pushany(L, NSNumber(value: 1) as Any)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_tointeger(L, -1) == 1)
            }
        }

        // MARK: - Foundation types

        @Test func testPushNSDate() {
            withLuaState { L in
                let date = NSDate(timeIntervalSince1970: 1700000000.0)
                lua_pushany(L, date)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                let val = lua_tonumber(L, -1)
                #expect(abs(val - 1700000000.0) < 0.01)
            }
        }

        @Test func testPushNSURL() {
            withLuaState { L in
                let url = NSURL(string: "https://example.com/path")!
                lua_pushany(L, url)
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let s = String(cString: lua_tostring(L, -1)!)
                #expect(s == "https://example.com/path")
            }
        }

        @Test func testPushNSData() {
            withLuaState { L in
                let bytes: [UInt8] = [0x48, 0x65, 0x6c, 0x6c, 0x6f]  // "Hello"
                let data = NSData(bytes: bytes, length: bytes.count)
                lua_pushany(L, data)
                #expect(lua_type(L, -1) == LUA_TSTRING)
                var len: Int = 0
                let ptr = lua_tolstring(L, -1, &len)!
                #expect(len == 5)
                let s = String(cString: ptr)
                #expect(s == "Hello")
            }
        }

        @Test func testPushNSNull() {
            withLuaState { L in
                lua_pushany(L, NSNull())
                #expect(lua_type(L, -1) == LUA_TNIL)
            }
        }

        // MARK: - Collections

        @Test func testPushArray() {
            withLuaState { L in
                let arr: [Any] = [1, "two", 3.0]
                lua_pushany(L, arr)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                // Check length
                let len = luaL_len(L, -1)
                #expect(len == 3)

                // Check element 1 (integer 1)
                lua_rawgeti(L, -1, 1)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                lua_pop(L, 1)

                // Check element 2 (string "two")
                lua_rawgeti(L, -1, 2)
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let s = String(cString: lua_tostring(L, -1)!)
                #expect(s == "two")
                lua_pop(L, 1)

                // Check element 3 (number 3.0)
                lua_rawgeti(L, -1, 3)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                lua_pop(L, 1)
            }
        }

        @Test func testPushDict() {
            withLuaState { L in
                let dict: [String: Any] = ["a": 1, "b": "two"]
                lua_pushany(L, dict)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                lua_getfield(L, -1, "a")
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)

                lua_getfield(L, -1, "b")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let s = String(cString: lua_tostring(L, -1)!)
                #expect(s == "two")
                lua_pop(L, 1)
            }
        }

        @Test func testPushNestedTable() {
            withLuaState { L in
                let nested: [String: Any] = [
                    "arr": [10, 20] as [Any],
                    "dict": ["x": 42] as [String: Any],
                ]
                lua_pushany(L, nested)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                // Check nested array
                lua_getfield(L, -1, "arr")
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(luaL_len(L, -1) == 2)
                lua_pop(L, 1)

                // Check nested dict
                lua_getfield(L, -1, "dict")
                #expect(lua_type(L, -1) == LUA_TTABLE)
                lua_getfield(L, -1, "x")
                #expect(lua_tointeger(L, -1) == 42)
                lua_pop(L, 2)
            }
        }

        @Test func testPushEmptyArray() {
            withLuaState { L in
                let arr: [Any] = []
                lua_pushany(L, arr)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(luaL_len(L, -1) == 0)
            }
        }

        @Test func testPushEmptyDict() {
            withLuaState { L in
                let dict: [String: Any] = [:]
                lua_pushany(L, dict)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(luaL_len(L, -1) == 0)
            }
        }

        // MARK: - lua_tovalue round-trips

        @Test func testToValueString() {
            withLuaState { L in
                lua_pushstring(L, "hello world")
                let val = lua_tovalue(L, at: -1)
                #expect(val as? String == "hello world")
            }
        }

        @Test func testToValueNumber() {
            withLuaState { L in
                lua_pushnumber(L, 3.14)
                let val = lua_tovalue(L, at: -1)
                #expect(val as? Double == 3.14)
            }
        }

        @Test func testToValueBool() {
            withLuaState { L in
                lua_pushboolean(L, 1)
                let val = lua_tovalue(L, at: -1)
                #expect(val as? Bool == true)

                lua_pushboolean(L, 0)
                let val2 = lua_tovalue(L, at: -1)
                #expect(val2 as? Bool == false)
            }
        }

        @Test func testToValueNil() {
            withLuaState { L in
                lua_pushnil(L)
                let val = lua_tovalue(L, at: -1)
                #expect(val == nil)
            }
        }

        @Test func testToValueTable() {
            withLuaState { L in
                // Push {name = "test", count = 5}
                lua_createtable(L, 0, 2)
                lua_pushstring(L, "test")
                lua_setfield(L, -2, "name")
                lua_pushinteger(L, 5)
                lua_setfield(L, -2, "count")

                let val = lua_tovalue(L, at: -1)
                let dict = val as? [String: Any]
                #expect(dict != nil)
                #expect(dict?["name"] as? String == "test")
                #expect(dict?["count"] as? Int == 5)
            }
        }

        @Test func testToValueArrayTable() {
            withLuaState { L in
                // Push {1, 2, 3}
                lua_createtable(L, 3, 0)
                for i: lua_Integer in 1...3 {
                    lua_pushinteger(L, i)
                    lua_rawseti(L, -2, i)
                }

                let val = lua_tovalue(L, at: -1)
                let arr = val as? [Any]
                #expect(arr != nil)
                #expect(arr?.count == 3)
                #expect(arr?[0] as? Int == 1)
                #expect(arr?[1] as? Int == 2)
                #expect(arr?[2] as? Int == 3)
            }
        }

        @Test func testToValueDictTable() {
            withLuaState { L in
                // Push {a = 1}
                lua_createtable(L, 0, 1)
                lua_pushinteger(L, 1)
                lua_setfield(L, -2, "a")

                let val = lua_tovalue(L, at: -1)
                let dict = val as? [String: Any]
                #expect(dict != nil)
                #expect(dict?["a"] as? Int == 1)
            }
        }

        // MARK: - Geometry helpers

        @Test func testPushAndPullNSPoint() {
            withLuaState { L in
                let pt = NSMakePoint(10.5, 20.5)
                lua_pushNSPoint(L, pt)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                let pulled = lua_tableToPoint(L, at: -1)
                #expect(abs(pulled.x - 10.5) < 0.001)
                #expect(abs(pulled.y - 20.5) < 0.001)
            }
        }

        @Test func testPushAndPullNSSize() {
            withLuaState { L in
                let sz = NSMakeSize(100.0, 200.0)
                lua_pushNSSize(L, sz)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                let pulled = lua_tableToSize(L, at: -1)
                #expect(abs(pulled.width - 100.0) < 0.001)
                #expect(abs(pulled.height - 200.0) < 0.001)
            }
        }

        @Test func testPushAndPullNSRect() {
            withLuaState { L in
                let rect = NSMakeRect(5.0, 10.0, 300.0, 400.0)
                lua_pushNSRect(L, rect)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                let pulled = lua_tableToRect(L, at: -1)
                #expect(abs(pulled.origin.x - 5.0) < 0.001)
                #expect(abs(pulled.origin.y - 10.0) < 0.001)
                #expect(abs(pulled.size.width - 300.0) < 0.001)
                #expect(abs(pulled.size.height - 400.0) < 0.001)
            }
        }

        // MARK: - Edge cases

        @Test func testPushDepthLimit() {
            withLuaState { L in
                // Build a deeply nested array exceeding kMaxPushDepth (50).
                // At the depth limit, lua_pushany pushes nil which collapses
                // array elements.  We verify the outermost layers are tables
                // and that we eventually hit nil before the full depth.
                var current: Any = "leaf"
                for _ in 0..<55 {
                    current = [current] as [Any]
                }
                lua_pushany(L, current)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                // Walk down by reading index 1 at each level
                var depth = 0
                while lua_type(L, -1) == LUA_TTABLE {
                    lua_rawgeti(L, -1, 1)
                    lua_remove(L, -2) // remove parent to keep stack bounded
                    depth += 1
                    if depth > 60 { break }  // safety valve
                }
                // At depth limit (50) the inner value is pushed as nil,
                // so we should stop before 55
                #expect(depth <= 51, "Should hit depth limit before 55 levels")
            }
        }

        @Test func testArrayWithZeroKey() {
            withLuaState { L in
                // Create table with key 0 — should be treated as dict, not array
                lua_createtable(L, 0, 2)
                lua_pushinteger(L, 100)
                lua_rawseti(L, -2, 0)      // t[0] = 100
                lua_pushinteger(L, 200)
                lua_rawseti(L, -2, 1)      // t[1] = 200

                let val = lua_tovalue(L, at: -1)
                // Key 0 means not sequential 1..n, so should come back as dictionary
                let dict = val as? [String: Any]
                #expect(dict != nil)
            }
        }

        // MARK: - State generation canary

        @Test func testStateGeneration() {
            let gen = lua_currentStateGeneration()
            #expect(lua_isStateGenerationValid(gen) == true)
        }

        @Test func testStateGenerationBump() {
            let before = lua_currentStateGeneration()
            lua_bumpStateGeneration()
            let after = lua_currentStateGeneration()
            #expect(after == before &+ 1)
            #expect(lua_isStateGenerationValid(before) == false)
            #expect(lua_isStateGenerationValid(after) == true)
        }

        // MARK: - Round-trip: push then tovalue

        @Test func testRoundTripInt() {
            withLuaState { L in
                lua_pushany(L, 42)
                let val = lua_tovalue(L, at: -1)
                #expect(val as? Int == 42)
            }
        }

        @Test func testRoundTripString() {
            withLuaState { L in
                lua_pushany(L, "round-trip")
                let val = lua_tovalue(L, at: -1)
                #expect(val as? String == "round-trip")
            }
        }

        @Test func testRoundTripDict() {
            withLuaState { L in
                let orig: [String: Any] = ["key": "value", "num": 7]
                lua_pushany(L, orig)
                let val = lua_tovalue(L, at: -1) as? [String: Any]
                #expect(val?["key"] as? String == "value")
                #expect(val?["num"] as? Int == 7)
            }
        }

        @Test func testRoundTripArray() {
            withLuaState { L in
                let orig: [Any] = [10, 20, 30]
                lua_pushany(L, orig)
                let val = lua_tovalue(L, at: -1) as? [Any]
                #expect(val?.count == 3)
                #expect(val?[0] as? Int == 10)
                #expect(val?[2] as? Int == 30)
            }
        }
    }
}
