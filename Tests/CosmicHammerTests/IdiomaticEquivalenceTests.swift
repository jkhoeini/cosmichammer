// IdiomaticEquivalenceTests.swift
//
// WP0 characterization matrix: compares the repo's home-grown conversions
// (`lua_pushany` / `lua_tovalue` in LuaHelpers.swift) against the idiomatic
// LuaSwift conversions (`push(any:)` / `toany(_:guessType:)`, surfaced via the
// `*_idiomatic` wrappers in LuaIdiomaticAdapter.swift).
//
// For each case we assert EITHER equivalence OR a documented intentional
// divergence. Divergences are the load-bearing findings for later WPs: they
// pin down exactly which conversions the home-grown path must keep owning.
//
// Pure-Lua state (no AppKit boot) via `withLuaState`.

import Testing
import AppKit
import Foundation
import CLua
import Lua
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite(.serialized) final class IdiomaticEquivalenceTests {

        // MARK: - helpers

        /// Raw byte contents of the Lua string at `idx`, read via lua_tolstring
        /// (NOT String(cString:)) so embedded NULs and invalid UTF-8 survive.
        private func luaStringBytes(_ L: UnsafeMutablePointer<lua_State>, _ idx: Int32) -> [UInt8]? {
            guard lua_type(L, idx) == LUA_TSTRING else { return nil }
            var len: Int = 0
            guard let ptr = lua_tolstring(L, idx, &len) else { return nil }
            return ptr.withMemoryRebound(to: UInt8.self, capacity: len) { base in
                Array(UnsafeBufferPointer(start: base, count: len))
            }
        }

        // MARK: - Strings (assert via byte length + bytes, never String(cString:))

        @Test func stringsEquivalent() {
            let cases: [[UInt8]] = [
                [],                                       // empty
                Array("hello world".utf8),                // ASCII
                [0x61, 0x00, 0x62, 0x00, 0x63],           // embedded NUL
                Array(repeating: 0x7A, count: 100_000),   // large
            ]
            for bytes in cases {
                withLuaState { L in
                    let s = String(decoding: bytes, as: UTF8.self)
                    lua_pushany(L, s)
                    lua_pushany_idiomatic(L, s)
                    let home = luaStringBytes(L, -2)
                    let idiom = luaStringBytes(L, -1)
                    #expect(home != nil)
                    #expect(idiom != nil)
                    // For valid-UTF8 round-trips the byte streams match.
                    #expect(home == idiom)
                    #expect(home?.count == idiom?.count)
                    lua_pop(L, 2)
                }
            }
        }

        @Test func invalidUTF8DataStringEquivalent() {
            // Invalid-UTF8 bytes carried as Data. Both paths push the raw bytes
            // verbatim; assert by byte content, not by String decoding.
            let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x80, 0xC0]
            let data = Data(bytes)
            withLuaState { L in
                lua_pushany(L, data)
                lua_pushany_idiomatic(L, data)
                let home = luaStringBytes(L, -2)
                let idiom = luaStringBytes(L, -1)
                #expect(home == bytes)
                #expect(idiom == bytes)
                lua_pop(L, 2)
            }
        }

        @Test func largeBinaryDataEquivalent() {
            let bytes = (0..<50_000).map { UInt8($0 & 0xFF) }
            let data = Data(bytes)
            withLuaState { L in
                lua_pushany(L, data)
                lua_pushany_idiomatic(L, data)
                #expect(luaStringBytes(L, -2)?.count == bytes.count)
                #expect(luaStringBytes(L, -1) == luaStringBytes(L, -2))
                lua_pop(L, 2)
            }
        }

        // MARK: - Numbers

        @Test func intBoundaryEquivalent() {
            let cases: [Int] = [0, 1, -1, Int(Int32.max), Int(Int32.min),
                                 Int(Int64.max), Int(Int64.min)]
            for v in cases {
                withLuaState { L in
                    lua_pushany(L, v)
                    lua_pushany_idiomatic(L, v)
                    #expect(lua_isinteger(L, -2) != 0)
                    #expect(lua_isinteger(L, -1) != 0)
                    #expect(lua_tointeger(L, -2) == lua_Integer(v))
                    #expect(lua_tointeger(L, -1) == lua_tointeger(L, -2))
                    lua_pop(L, 2)
                }
            }
        }

        @Test func intVsDoubleDistinguished() {
            withLuaState { L in
                lua_pushany(L, 42)        // Int
                lua_pushany(L, 42.0)      // Double
                #expect(lua_isinteger(L, -2) != 0)   // Int -> integer
                #expect(lua_isinteger(L, -1) == 0)   // Double -> float
                lua_pop(L, 2)

                lua_pushany_idiomatic(L, 42)
                lua_pushany_idiomatic(L, 42.0)
                #expect(lua_isinteger(L, -2) != 0)
                #expect(lua_isinteger(L, -1) == 0)
                lua_pop(L, 2)
            }
        }

        @Test func doubleEquivalent() {
            withLuaState { L in
                lua_pushany(L, 3.141592653589793)
                lua_pushany_idiomatic(L, 3.141592653589793)
                #expect(lua_tonumber(L, -2) == 3.141592653589793)
                #expect(lua_tonumber(L, -1) == lua_tonumber(L, -2))
                lua_pop(L, 2)
            }
        }

        // EXPECTED DIVERGENCE — NON-DELEGATABLE.
        // Home-grown promotes Float to a Lua number. push(any:) has no Float
        // case and Float is not Pushable, so it falls through to
        // push(userdata:) and boxes the Float as a LuaSwift_Type_Float userdata
        // (lua_tonumber -> 0.0). Swift `Float` arguments must keep going through
        // the home-grown path.
        @Test func floatDiverges() {
            let f: Float = 1.5
            withLuaState { L in
                lua_pushany(L, f)               // home-grown: number 1.5
                lua_pushany_idiomatic(L, f)     // idiomatic: boxed userdata
                #expect(lua_type(L, -2) == LUA_TNUMBER)
                #expect(lua_tonumber(L, -2) == lua_Number(f))
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func nsNumberIntegerEquivalent() {
            withLuaState { L in
                let n = NSNumber(value: 1)
                lua_pushany(L, n)
                lua_pushany_idiomatic(L, n)
                #expect(lua_isinteger(L, -2) != 0)
                #expect(lua_isinteger(L, -1) != 0)
                #expect(lua_tointeger(L, -2) == 1)
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 2)
            }
        }

        // MARK: - CFBoolean (EXPECTED DIVERGENCE — NON-DELEGATABLE)

        // Home-grown detects the kCFBoolean singletons and pushes a Lua boolean.
        // push(any:) treats CFBoolean as an NSNumber and pushes a number (1/0).
        @Test func cfBooleanDiverges() {
            withLuaState { L in
                lua_pushany(L, kCFBooleanTrue as Any)
                lua_pushany_idiomatic(L, kCFBooleanTrue as Any)
                // home-grown: boolean true
                #expect(lua_type(L, -2) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -2) == 1)
                // idiomatic: number 1 (the documented, intentional divergence)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_tointeger(L, -1) == 1)
                #expect(lua_type(L, -2) != lua_type(L, -1)) // they differ
                lua_pop(L, 2)

                lua_pushany(L, kCFBooleanFalse as Any)
                lua_pushany_idiomatic(L, kCFBooleanFalse as Any)
                #expect(lua_type(L, -2) == LUA_TBOOLEAN)
                #expect(lua_toboolean(L, -2) == 0)
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_tointeger(L, -1) == 0)
                lua_pop(L, 2)
            }
        }

        // MARK: - Tables

        // EXPECTED DIVERGENCE — NON-DELEGATABLE for empty arrays.
        // FINDING: an empty Swift `[Any]` successfully casts to `[UInt8]`
        // (`[] as? [UInt8]` is non-nil), so push(any:) matches its `[UInt8]`
        // case *before* its `Array<Any>` case and pushes an empty Lua *string*,
        // not a table. The home-grown path always produces an (empty) table.
        // Non-empty heterogeneous arrays do NOT hit this (see arrayTableEquivalent).
        @Test func emptyArrayDiverges() {
            withLuaState { L in
                let empty: [Any] = []
                lua_pushany(L, empty)            // home-grown: empty table
                lua_pushany_idiomatic(L, empty)  // idiomatic: empty string
                #expect(lua_type(L, -2) == LUA_TTABLE)
                #expect(lua_rawlen(L, -2) == 0)
                #expect(lua_type(L, -1) == LUA_TSTRING)
                #expect(lua_rawlen(L, -1) == 0)
                lua_pop(L, 2)
            }
        }

        // An explicitly-typed empty dictionary agrees: both produce an empty
        // table (no [UInt8] ambiguity for Dictionary).
        @Test func emptyDictEquivalent() {
            withLuaState { L in
                let empty: [String: Any] = [:]
                lua_pushany(L, empty)
                lua_pushany_idiomatic(L, empty)
                #expect(lua_type(L, -2) == LUA_TTABLE)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                lua_pop(L, 2)
            }
        }

        @Test func arrayTableEquivalent() {
            withLuaState { L in
                let arr: [Any] = [10, 20, 30]
                lua_pushany(L, arr)
                lua_pushany_idiomatic(L, arr)
                // Compare element-wise on both tables.
                for tableIdx in [Int32(-2), Int32(-1)] {
                    #expect(lua_rawlen(L, tableIdx) == 3)
                    for i in 1...3 {
                        lua_rawgeti(L, tableIdx, lua_Integer(i))
                        #expect(lua_tointeger(L, -1) == lua_Integer(i * 10))
                        lua_pop(L, 1)
                    }
                }
                lua_pop(L, 2)
            }
        }

        @Test func dictTableEquivalent() {
            withLuaState { L in
                let dict: [String: Any] = ["a": 1, "b": 2]
                lua_pushany(L, dict)
                lua_pushany_idiomatic(L, dict)
                for tableIdx in [Int32(-2), Int32(-1)] {
                    lua_getfield(L, tableIdx, "a")
                    #expect(lua_tointeger(L, -1) == 1)
                    lua_pop(L, 1)
                    lua_getfield(L, tableIdx, "b")
                    #expect(lua_tointeger(L, -1) == 2)
                    lua_pop(L, 1)
                }
                lua_pop(L, 2)
            }
        }

        @Test func sparseAndZeroKeyTable() {
            // NSDictionary with non-1-based / sparse integer keys. Both paths
            // build a Lua table; assert the addressable entries survive on the
            // idiomatic path (home-grown collapses NSArray holes differently,
            // so we characterize the idiomatic dictionary form here).
            withLuaState { L in
                let dict: [AnyHashable: Any] = [0: "zero", 5: "five", 10: "ten"]
                lua_pushany_idiomatic(L, dict)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                for (k, v) in [(0, "zero"), (5, "five"), (10, "ten")] {
                    lua_rawgeti(L, -1, lua_Integer(k))
                    #expect(lua_type(L, -1) == LUA_TSTRING)
                    var len = 0
                    let s = lua_tolstring(L, -1, &len).map { String(cString: $0) }
                    #expect(s == v)
                    lua_pop(L, 1)
                }
                lua_pop(L, 1)
            }
        }

        @Test func mixedKeyTableIdiomatic() {
            withLuaState { L in
                let dict: [AnyHashable: Any] = ["name": "x", 1: "first"]
                lua_pushany_idiomatic(L, dict)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                lua_getfield(L, -1, "name")
                var len = 0
                #expect(lua_tolstring(L, -1, &len).map { String(cString: $0) } == "x")
                lua_pop(L, 1)
                lua_rawgeti(L, -1, 1)
                #expect(lua_tolstring(L, -1, &len).map { String(cString: $0) } == "first")
                lua_pop(L, 1)
                lua_pop(L, 1)
            }
        }

        // REGRESSION (was nestedCyclicTableTerminates). Fix #3: `lua_pushany`
        // now calls `lua_checkstack` before each recursive push, so a deep but
        // finite nested structure pushed in a bare (unprotected) frame must
        // SUCCEED and round-trip to the right depth/shape — it must NOT trip
        // Lua's api_check and abort the process. We use depth=40 (well past
        // LUA_MINSTACK = 20 but under kMaxPushDepth = 50) to prove the
        // checkstack hardening works without hitting the cycle-guard cap.
        @Test func deepNestedTableSurvivesAndRoundTrips() {
            let depth = 40
            // Build {next = {next = {... value = "leaf"}}} 40 levels deep.
            var node: [String: Any] = ["value": "leaf"]
            for i in 0..<depth {
                node = ["level": i, "next": node]
            }
            let root = node

            withLuaState { L in
                let top = lua_gettop(L)
                // Direct, UNPROTECTED push — this is the abort path that fix #3
                // eliminates. If checkstack hardening regressed, this aborts the
                // whole test process (no recovery possible), so reaching the
                // assertions at all already proves no-abort.
                lua_pushany(L, root)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                // Walk the nest back down and confirm the shape survived.
                // Each lua_getfield pushes a value, so we grow the stack to
                // accommodate the full descent (depth + a few extra slots).
                lua_checkstack(L, Int32(depth + 10))
                var observed = 0
                // Descend through `next` until we reach the leaf table.
                while lua_getfield(L, -1, "next") == LUA_TTABLE {
                    observed += 1
                    // Guard against runaway in case of a bug.
                    if observed > depth + 5 { break }
                }
                lua_pop(L, 1) // pop the non-table `next` (nil at the leaf)
                #expect(observed == depth)

                // At the current top we are sitting on the leaf table; confirm
                // its terminal value.
                #expect(lua_getfield(L, -1, "value") == LUA_TSTRING)
                var len = 0
                #expect(lua_tolstring(L, -1, &len).map { String(cString: $0) } == "leaf")
                lua_pop(L, 1) // value

                lua_settop(L, top) // drop everything we descended through
            }
        }

        // SAFETY characterization for a genuine reference CYCLE. This must NOT
        // rely on api_check abort: the home-grown `lua_pushany` bounds recursion
        // at kMaxPushDepth (50) AND now pre-grows the stack via lua_checkstack,
        // so a self-referential NSDictionary terminates cleanly (it pushes nil
        // once the depth bound is hit) in a bare frame — no protected call, no
        // abort.
        @Test func cyclicTableTerminatesWithoutAbort() {
            withLuaState { L in
                let top = lua_gettop(L)
                let inner = NSMutableDictionary()
                inner["k"] = "v"
                let outer = NSMutableDictionary()
                outer["inner"] = inner
                inner["back"] = outer // cycle

                // Direct unprotected push. Terminates because recursion is
                // depth-bounded; never aborts because each level reserves stack.
                lua_pushany(L, outer)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                lua_settop(L, top)
            }
        }

        // MARK: - Geometry __luaSkinType tables (NON-DELEGATABLE)

        private func expectLuaSkinType(_ L: UnsafeMutablePointer<lua_State>, _ idx: Int32, _ expected: String) {
            #expect(lua_type(L, idx) == LUA_TTABLE)
            let abs = lua_absindex(L, idx)
            lua_getfield(L, abs, "__luaSkinType")
            var len = 0
            #expect(lua_tolstring(L, -1, &len).map { String(cString: $0) } == expected)
            lua_pop(L, 1)
        }

        @Test func geometryHomeGrownTaggedIdiomaticBoxed() {
            withLuaState { L in
                // NSPoint
                lua_pushany(L, NSValue(point: NSPoint(x: 3, y: 4)))
                expectLuaSkinType(L, -1, "NSPoint")
                lua_pushany_idiomatic(L, NSValue(point: NSPoint(x: 3, y: 4)))
                #expect(lua_type(L, -1) == LUA_TUSERDATA) // boxed, NOT a table
                lua_pop(L, 2)

                // NSSize — home-grown tags, idiomatic boxes as opaque userdata.
                lua_pushany(L, NSValue(size: NSSize(width: 5, height: 6)))
                expectLuaSkinType(L, -1, "NSSize")
                lua_pushany_idiomatic(L, NSValue(size: NSSize(width: 5, height: 6)))
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)

                // NSRect — home-grown tags, idiomatic boxes as opaque userdata.
                lua_pushany(L, NSValue(rect: NSRect(x: 1, y: 2, width: 3, height: 4)))
                expectLuaSkinType(L, -1, "NSRect")
                lua_pushany_idiomatic(L, NSValue(rect: NSRect(x: 1, y: 2, width: 3, height: 4)))
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)

                // NSRange — home-grown tags, idiomatic boxes as opaque userdata.
                lua_pushany(L, NSValue(range: NSRange(location: 7, length: 8)))
                expectLuaSkinType(L, -1, "NSRange")
                lua_pushany_idiomatic(L, NSValue(range: NSRange(location: 7, length: 8)))
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)

                // NSColor
                lua_pushany(L, NSColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
                expectLuaSkinType(L, -1, "NSColor")
                lua_pushany_idiomatic(L, NSColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)

                // NSFont
                let font = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
                lua_pushany(L, font)
                expectLuaSkinType(L, -1, "NSFont")
                lua_pushany_idiomatic(L, font)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func geometryRoundTripHomeGrown() {
            // Home-grown round-trip of the geometry helpers via the dedicated
            // __luaSkinType readers (this is the path production relies on).
            withLuaState { L in
                lua_pushNSPoint(L, NSPoint(x: 3, y: 4))
                let p = lua_tableToPoint(L, at: -1)
                #expect(p.x == 3 && p.y == 4)
                lua_pop(L, 1)
            }
        }

        // MARK: - Foundation/AppKit retained-userdata seam (NON-DELEGATABLE)

        // For each of these, the home-grown path produces the repo's
        // userdata/hs.* / scalar result, while push(any:) falls through to a
        // LuaSwift_Type_* Any-box userdata.

        @Test func nsDateDivergesToNumber() {
            withLuaState { L in
                let date = NSDate(timeIntervalSince1970: 1000)
                lua_pushany(L, date)               // home-grown: epoch number
                lua_pushany_idiomatic(L, date)     // idiomatic: boxed userdata
                #expect(lua_type(L, -2) == LUA_TNUMBER)
                #expect(lua_tonumber(L, -2) == 1000)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func nsURLDivergesToString() {
            withLuaState { L in
                let url = NSURL(string: "https://example.com/path")!
                lua_pushany(L, url)                // home-grown: string
                lua_pushany_idiomatic(L, url)      // idiomatic: boxed userdata
                #expect(lua_type(L, -2) == LUA_TSTRING)
                var len = 0
                #expect(lua_tolstring(L, -2, &len).map { String(cString: $0) } == "https://example.com/path")
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func swiftURLDivergesToString() {
            withLuaState { L in
                let url = URL(string: "https://example.com/swift")!
                lua_pushany(L, url)
                lua_pushany_idiomatic(L, url)
                #expect(lua_type(L, -2) == LUA_TSTRING)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func nsValueGeometryAlreadyCoveredButRecheckIdiomaticBox() {
            withLuaState { L in
                lua_pushany_idiomatic(L, NSValue(point: NSPoint(x: 1, y: 1)))
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 1)
            }
        }

        @Test func nsImageDivergesWithoutMetatable() {
            // Without hs.image's metatable installed (pure-Lua state), the
            // home-grown path's lua_pushretainedUserdata fails its metatable
            // lookup and falls back to the description string. The idiomatic
            // path boxes the NSImage as a LuaSwift_Type_* userdata. We assert
            // they differ and document the seam.
            withLuaState { L in
                let image = NSImage(size: NSSize(width: 8, height: 8))
                lua_pushany(L, image)              // no hs.image mt -> string fallback
                lua_pushany_idiomatic(L, image)    // boxed userdata
                #expect(lua_type(L, -2) == LUA_TSTRING)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func nsAttributedStringDivergesWithoutMetatable() {
            withLuaState { L in
                let s = NSAttributedString(string: "styled")
                lua_pushany(L, s)                  // no hs.styledtext mt -> string fallback
                lua_pushany_idiomatic(L, s)        // boxed userdata
                #expect(lua_type(L, -2) == LUA_TSTRING)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        // A minimal LuaUserdataConvertible used purely to characterize the seam.
        private final class FakeConvertible: NSObject, LuaUserdataConvertible {
            var luaUserdataMetatableName: String { "cosmic.test.fakeconvertible" }
            var retainCalled = false
            func luaUserdataWillRetain() { retainCalled = true }
        }

        /// `__gc` that balances the `Unmanaged.passRetained` performed by
        /// `lua_pushretainedUserdata`, so mock-metatable tests do not leak the
        /// retained Swift object when the userdata is collected.
        private static let retainedUserdataGC: lua_CFunction = { L in
            guard let L, let ptr = lua_touserdata(L, 1) else { return 0 }
            let slot = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let opaque = slot.pointee {
                Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(opaque)).release()
                slot.pointee = nil
            }
            return 0
        }

        /// Create (if needed) a mock metatable that includes a real `__gc`
        /// releasing the retained pointer, then pop it off the stack.
        private func installRetainedMetatable(_ L: UnsafeMutablePointer<lua_State>, _ name: String) {
            if luaL_newmetatable(L, name) != 0 {
                lua_pushcclosure(L, Self.retainedUserdataGC, 0)
                lua_setfield(L, -2, "__gc")
            }
            lua_pop(L, 1)
        }

        @Test func luaUserdataConvertibleDivergesWithoutMetatable() {
            withLuaState { L in
                let obj = FakeConvertible()
                // No metatable named cosmic.test.fakeconvertible exists, so the
                // home-grown retained-userdata push fails and falls back to the
                // description string. The idiomatic path boxes it as userdata.
                lua_pushany(L, obj)
                lua_pushany_idiomatic(L, obj)
                #expect(lua_type(L, -2) == LUA_TSTRING)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                lua_pop(L, 2)
            }
        }

        @Test func luaUserdataConvertibleRoutesToOwnMetatableWhenPresent() {
            // When the module's metatable IS installed, the home-grown path
            // produces real userdata under that metatable and invokes the
            // willRetain hook. This is the production behavior the seam exists
            // to preserve; push(any:) cannot replicate it (it has no knowledge
            // of the module's metatable name).
            withLuaState { L in
                let obj = FakeConvertible()
                // Install a metatable WITH a real __gc so the retained pointer
                // pushed below is released when the userdata is collected (no
                // leak). collectgarbage('collect') runs the __gc before the
                // state is closed.
                installRetainedMetatable(L, "cosmic.test.fakeconvertible")

                lua_pushany(L, obj)
                #expect(lua_type(L, -1) == LUA_TUSERDATA)
                #expect(luaL_testudata(L, -1, "cosmic.test.fakeconvertible") != nil)
                #expect(obj.retainCalled == true)
                #expect(lua_testUserdataObject(FakeConvertible.self, L, at: -1,
                                                metatableName: "cosmic.test.fakeconvertible") === obj)
                lua_pop(L, 1)
                // Force the __gc to run so the retain is balanced before close.
                luaL_dostring(L, "collectgarbage('collect')")
            }
        }

        // MARK: - tovalue round-trip parity (where both paths agree)

        @Test func tovalueScalarParity() {
            withLuaState { L in
                lua_pushinteger(L, 7)
                let home = lua_tovalue(L, at: -1) as? Int
                let idiom = lua_tovalue_idiomatic(L, at: -1)
                #expect(home == 7)
                // toany returns AnyHashable(Int); compare via Int extraction.
                #expect((idiom as? Int) == 7 || (idiom as? AnyHashable).flatMap { $0 as? Int } == 7)
                lua_pop(L, 1)

                lua_pushstring(L, "abc")
                let homeS = lua_tovalue(L, at: -1) as? String
                let idiomS = lua_tovalue_idiomatic(L, at: -1) as? String
                #expect(homeS == "abc")
                #expect(idiomS == "abc")
                lua_pop(L, 1)

                lua_pushboolean(L, 1)
                #expect((lua_tovalue(L, at: -1) as? Bool) == true)
                #expect((lua_tovalue_idiomatic(L, at: -1) as? Bool) == true)
                lua_pop(L, 1)
            }
        }

        // MARK: - SAFE error bridging (Fix #1: no Swift-side lua_error)

        // A throwing LuaClosure pushed via L.push(_:) must, when CALLED, raise a
        // CATCHABLE Lua error (routed through LuaSwift's C trampoline:
        // callClosure pushes the error and returns LUASWIFT_CALLCLOSURE_ERROR,
        // and luaswift_callclosurewrapper calls lua_error in C). It must NOT be
        // a Swift-side lua_error (which would longjmp past Swift frames). We
        // prove "catchable" by recovering the error through pcall.
        @Test func throwingLuaClosureRaisesCatchableLuaError() {
            withLuaState { L in
                let top = lua_gettop(L)
                // Push a Lua function backed by a Swift closure that throws.
                L.push({ (_: LuaState) throws -> CInt in
                    throw L.error("boom from swift closure")
                })
                // Call it under pcall: 0 args, 0 results. A catchable error
                // returns LUA_ERRRUN and leaves the message on the stack — it
                // does NOT abort and does NOT escape as a Swift error.
                let rc = lua_pcallk(L, 0, 0, 0, 0, nil)
                #expect(rc == LUA_ERRRUN)
                #expect(lua_type(L, -1) == LUA_TSTRING)
                var len = 0
                let msg = lua_tolstring(L, -1, &len).map { String(cString: $0) } ?? ""
                #expect(msg.contains("boom from swift closure"))
                lua_settop(L, top)
            }
        }

        // The WP1 entry-point pattern end-to-end: build a module table with
        // runEntryPoint + buildModuleTable(closures:) where one function throws
        // on bad input (the randomFromRange / base64-decode shape). The built
        // table's functions are callable; the throwing one raises a catchable
        // Lua error via pcall; the happy path returns a normal result.
        @Test func entryPointModuleTableErrorsAreCatchable() {
            withLuaState { L in
                let top = lua_gettop(L)

                // Simulate a luaopen_* entry point: NON-throwing body that only
                // builds the table by pushing LuaClosures. Per-function errors
                // live INSIDE the closures and are thrown safely.
                let rc = runEntryPoint(L) { L in
                    buildModuleTable(L, closures: [
                        // Happy path: doubles its integer argument.
                        "double": { (L: LuaState) throws -> CInt in
                            let n = lua_tointeger(L, 1)
                            lua_pushinteger(L, n * 2)
                            return 1
                        },
                        // Error path: throws on a bad range (randomFromRange shape).
                        "needsPositive": { (L: LuaState) throws -> CInt in
                            let n = lua_tointeger(L, 1)
                            if n <= 0 {
                                throw L.error("argument must be positive")
                            }
                            lua_pushinteger(L, n)
                            return 1
                        },
                    ])
                }
                #expect(rc == 1)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                lua_setglobal(L, "mod")

                // Happy path returns normally.
                #expect(luaL_dostring(L, "return mod.double(21)") == LUA_OK)
                #expect(lua_tointeger(L, -1) == 42)
                lua_settop(L, top)

                // Error path is catchable via pcall — NOT an abort.
                #expect(luaL_dostring(L, """
                    local ok, err = pcall(function() return mod.needsPositive(-1) end)
                    assert(ok == false, 'expected pcall failure')
                    assert(type(err) == 'string', 'expected string error')
                    assert(err:find('must be positive'), 'wrong error: ' .. tostring(err))
                    return true
                """) == LUA_OK)
                lua_settop(L, top)

                // Error path happy case still works.
                #expect(luaL_dostring(L, "return mod.needsPositive(7)") == LUA_OK)
                #expect(lua_tointeger(L, -1) == 7)
                lua_settop(L, top)
            }
        }
    }
}
