// IdiomaticCoexistenceTests.swift
//
// WP0 GATING experiment: prove that bringing the idiomatic LuaSwift `_State`
// into existence on the already-booted `hs.*` Lua state does NOT disturb the
// repo's existing machinery — specifically:
//   * the pre-existing hs.image / hs.styledtext metatables stay pointer-stable,
//   * the home-grown GC generation canary is untouched,
//   * the stack stays balanced,
//   * the retained-userdata seam still routes NSImage -> hs.image and
//     NSAttributedString -> hs.styledtext AFTER _State exists,
//   * a LuaUserdataConvertible still round-trips, and
//   * collectgarbage runs are crash-free with the canary still valid.
//
// Booted hs.* state via bootstrapLuaForTesting() (same pattern as
// ObjectConversionRegressionTests), so this suite requires
// COSMIC_HAMMER_TEST_RESOURCES.

import Testing
import AppKit
import Foundation
import CLua
import Lua
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite(.serialized) @MainActor final class IdiomaticCoexistenceTests {

        private func metatablePointer(_ L: UnsafeMutablePointer<lua_State>, _ name: String) -> UnsafeRawPointer? {
            luaL_getmetatable(L, name)
            defer { lua_pop(L, 1) }
            guard lua_type(L, -1) == LUA_TTABLE else { return nil }
            return lua_topointer(L, -1)
        }

        /// True if LuaSwift's internal `_State` has been instantiated, detected
        /// via the registry-registered `LuaSwift_State` metatable. (The
        /// `maybeGetState()` accessor is `internal` to the Lua module, so we
        /// observe the side effect rather than call it directly.)
        private func stateExists(_ L: UnsafeMutablePointer<lua_State>) -> Bool {
            luaL_getmetatable(L, "LuaSwift_State")
            defer { lua_pop(L, 1) }
            return lua_type(L, -1) == LUA_TTABLE
        }

        // Fix #2: the _State-absence check uses a FRESH standalone state
        // (withLuaState) so it is immune to test ordering. The booted hs.*
        // state is a singleton and another suite running first could have
        // already triggered _State init, making an absence assertion flaky.
        // The pointer-stability and canary invariants are checked on the
        // shared booted state, where they are meaningful.
        @Test func stateIsAbsentOnFreshLuaState() {
            // A brand-new Lua state (no LuaSwift interaction) must NOT have
            // the LuaSwift_State metatable registered.
            withLuaState { L in
                luaL_getmetatable(L, "LuaSwift_State")
                #expect(lua_type(L, -1) == LUA_TNIL)
                lua_pop(L, 1)

                // After forcing _State via push(closure:), it must appear.
                L.push(closure: { () -> Int in 0 })
                lua_pop(L, 1)

                luaL_getmetatable(L, "LuaSwift_State")
                #expect(lua_type(L, -1) == LUA_TTABLE)
                lua_pop(L, 1)
            }
        }

        @Test func bringingUpStateDoesNotDisturbExistingMachinery() {
            bootstrapLuaForTesting()
            // Ensure the hs.* metatables we care about exist before we touch
            // LuaSwift's _State.
            _ = runLua("require('hs.image'); require('hs.styledtext')")

            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            // --- BEFORE: capture canary, stack, metatable pointers ---
            let canaryBefore = lua_currentStateGeneration()
            let topBefore = lua_gettop(L)

            let imageMTBefore = metatablePointer(L, "hs.image")
            let styledMTBefore = metatablePointer(L, "hs.styledtext")
            #expect(imageMTBefore != nil)
            #expect(styledMTBefore != nil)

            // --- FORCE _State init (idempotent if already present) ---
            // push(closure:) wraps the closure in a LuaClosureWrapper, whose
            // push registers the wrapper metatable -> getState(). A bare scalar
            // push would NOT trigger it, so we deliberately use a closure.
            L.push(closure: { () -> Int in 0 })
            lua_pop(L, 1) // discard the pushed function

            // --- AFTER ---
            // LuaSwift_State must now be present.
            #expect(stateExists(L))

            // Pre-existing metatables must be pointer-stable.
            #expect(metatablePointer(L, "hs.image") == imageMTBefore)
            #expect(metatablePointer(L, "hs.styledtext") == styledMTBefore)

            // Stack balanced and canary unchanged.
            #expect(lua_gettop(L) == topBefore)
            #expect(lua_currentStateGeneration() == canaryBefore)
            #expect(lua_isStateGenerationValid(canaryBefore))
        }

        @Test func nsImageStillRoutesToHsImageAfterStateExists() {
            bootstrapLuaForTesting()
            _ = runLua("require('hs.image')")
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            // Make sure _State exists.
            L.push(closure: { () -> Int in 0 })
            lua_pop(L, 1)

            let image = NSImage(size: NSSize(width: 12, height: 12))
            lua_pushany(L, image)
            #expect(lua_type(L, -1) == LUA_TUSERDATA)
            #expect(luaL_testudata(L, -1, "hs.image") != nil)
            lua_pop(L, 1)
        }

        @Test func nsAttributedStringStillRoutesToStyledtextAfterStateExists() {
            bootstrapLuaForTesting()
            _ = runLua("require('hs.styledtext')")
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            L.push(closure: { () -> Int in 0 })
            lua_pop(L, 1)

            let s = NSAttributedString(string: "coexist")
            lua_pushany(L, s)
            #expect(lua_type(L, -1) == LUA_TUSERDATA)
            #expect(luaL_testudata(L, -1, "hs.styledtext") != nil)
            lua_pop(L, 1)
        }

        // Typed convertible round-trip with its own metatable installed.
        private final class CoexistConvertible: NSObject, LuaUserdataConvertible {
            let tag: String
            init(tag: String) { self.tag = tag }
            var luaUserdataMetatableName: String { "cosmic.coexist.convertible" }
            func luaUserdataWillRetain() {}
        }

        /// `__gc` that balances the `Unmanaged.passRetained` performed by
        /// `lua_pushretainedUserdata`, preventing the retained Swift object
        /// from leaking when the userdata is collected.
        private static let retainedUserdataGC: lua_CFunction = { L in
            guard let L, let ptr = lua_touserdata(L, 1) else { return 0 }
            let slot = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let opaque = slot.pointee {
                Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(opaque)).release()
                slot.pointee = nil
            }
            return 0
        }

        @Test func luaUserdataConvertibleRoundTripsAfterStateExists() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            // Install the convertible's metatable WITH a real __gc so the
            // retained pointer pushed below is released when the userdata is
            // collected (fix #5b: no leak).
            if luaL_newmetatable(L, "cosmic.coexist.convertible") != 0 {
                lua_pushcclosure(L, Self.retainedUserdataGC, 0)
                lua_setfield(L, -2, "__gc")
            }
            lua_pop(L, 1)

            // Force _State.
            L.push(closure: { () -> Int in 0 })
            lua_pop(L, 1)

            let obj = CoexistConvertible(tag: "rt")
            lua_pushany(L, obj)
            #expect(lua_type(L, -1) == LUA_TUSERDATA)
            #expect(luaL_testudata(L, -1, "cosmic.coexist.convertible") != nil)
            let recovered = lua_testUserdataObject(
                CoexistConvertible.self, L, at: -1,
                metatableName: "cosmic.coexist.convertible"
            )
            #expect(recovered === obj)
            lua_pop(L, 1)
            // Force the __gc to run so the retain is balanced.
            luaL_dostring(L, "collectgarbage('collect')")
        }

        @Test func garbageCollectionAfterStateIsCrashFreeAndCanaryValid() {
            bootstrapLuaForTesting()
            _ = runLua("require('hs.image')")
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            let canaryBefore = lua_currentStateGeneration()

            // Force _State, then push & drop some idiomatic closures to give the
            // collector LuaSwift-managed userdata to reclaim.
            L.push(closure: { () -> Int in 0 })
            lua_pop(L, 1)
            L.push(closure: { (_: Int) -> Int in 0 })
            lua_pop(L, 1)

            // Fix #4: create REAL repo userdata (hs.image) via Lua so the GC
            // test proves that existing retained-pointer userdata with __gc
            // finalizers survives garbage collection after _State is registered.
            // `hs.image.imageFromName` returns an hs.image userdata backed by
            // a retained NSImage.
            #expect(luaL_dostring(L, """
                _G._gcTestImage = hs.image.imageFromName('NSApplicationIcon')
            """) == LUA_OK)
            // Confirm the userdata was created.
            lua_getglobal(L, "_gcTestImage")
            #expect(lua_type(L, -1) == LUA_TUSERDATA)
            #expect(luaL_testudata(L, -1, "hs.image") != nil)
            lua_pop(L, 1)

            // Run two full GC cycles — first collects, second finalizes.
            #expect(luaL_dostring(L, "collectgarbage('collect')") == LUA_OK)
            #expect(luaL_dostring(L, "collectgarbage('collect')") == LUA_OK)

            // The hs.image userdata must survive GC (it's still referenced by
            // the global). Its metatable and type must be intact.
            lua_getglobal(L, "_gcTestImage")
            #expect(lua_type(L, -1) == LUA_TUSERDATA)
            #expect(luaL_testudata(L, -1, "hs.image") != nil)
            lua_pop(L, 1)

            // Clean up the global ref so the image can be collected normally.
            #expect(luaL_dostring(L, "_G._gcTestImage = nil") == LUA_OK)

            #expect(stateExists(L))
            #expect(lua_currentStateGeneration() == canaryBefore)
            #expect(lua_isStateGenerationValid(canaryBefore))
        }
    }
}
