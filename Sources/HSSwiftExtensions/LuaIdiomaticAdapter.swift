// LuaIdiomaticAdapter.swift
//
// WP0 (FOUNDATION) of the CLua -> tomsci/LuaSwift "Lua" Swift API migration.
//
// This file is *purely additive*. Nothing here is wired into any production
// caller in WP0; the helpers exist only so the characterization/coexistence
// test suites (`IdiomaticEquivalenceTests`, `IdiomaticCoexistenceTests`) can
// exercise the idiomatic `Lua` API side-by-side with the repo's home-grown
// `LuaHelpers.swift` conversions and document where the two diverge.
//
// These helpers are intentionally thin and signature-stable: later work
// packages can grow them into the real production seam, but WP0 only
// characterizes behavior. Runtime stays Lua 5.4 (PUC-Rio via CLua).
//
// -------------------------------------------------------------------------
// NON-DELEGATABLE behaviors (home-grown `LuaHelpers.swift` stays authoritative)
// -------------------------------------------------------------------------
// The idiomatic `LuaState.push(any:)` / `toany(_:guessType:)` cannot replace
// the home-grown conversions for the following cases. Each is verified by a
// characterization test that asserts the *actual* divergence:
//
//   * CFBoolean / NSNumber-as-bool: the home-grown path detects the
//     kCFBooleanTrue/kCFBooleanFalse singletons and pushes a Lua boolean.
//     `push(any:)` treats CFBoolean as an NSNumber and pushes a number (1/0).
//   * Swift `Float`: home-grown promotes to a Lua number; `push(any:)` has no
//     Float case (Float is not Pushable) and boxes it as opaque userdata.
//   * Empty Swift `[Any]`: `[] as? [UInt8]` succeeds, so `push(any:)` matches
//     its `[UInt8]` case first and pushes an empty *string*; the home-grown
//     path always pushes an (empty) table. (Typed empty dictionaries agree.)
//   * Deep/nested structures: the home-grown push does not call lua_checkstack,
//     so an unprotected push of a >LUA_MINSTACK-deep nest can abort. It must be
//     driven under a protected call (or hardened) before relying on it for
//     arbitrary-depth data.
//   * Geometry `__luaSkinType` tables: NSPoint / NSSize / NSRect / NSRange /
//     NSColor / NSFont are pushed by the home-grown path as LuaSkin-compatible
//     tables carrying a `__luaSkinType` tag. `push(any:)` boxes them as opaque
//     `LuaSwift_Type_*` userdata instead.
//   * The retained-userdata seam (`lua_pushretainedUserdata`):
//       - NSImage           -> `hs.image` userdata
//       - NSAttributedString-> `hs.styledtext` userdata
//       - NSDate            -> epoch-seconds number
//       - NSURL / URL       -> absolute-string Lua string
//       - NSValue           -> geometry `__luaSkinType` table
//       - NSColor / NSFont  -> `__luaSkinType` tables
//       - any `LuaUserdataConvertible` -> the module's own metatable userdata
//     `push(any:)` falls through to `push(userdata:)`, producing an opaque
//     `LuaSwift_Type_*` Any-box userdata with no `hs.*` metatable.
//   * The GC generation canary (`lua_bumpStateGeneration` /
//     `lua_isStateGenerationValid`): a repo-owned reload guard with no
//     equivalent in the idiomatic API; it must remain independent of the
//     LuaSwift `_State` lifecycle.

import CLua
import Lua

// MARK: - Entry-point pattern (SAFE error bridging)
//
// CHOSEN APPROACH (post-codex-review redesign):
//
// Swift code in this file NEVER calls `lua_error` / `luaL_error` with live
// Swift ARC objects on the stack. Doing so longjmps past Swift frames and
// skips ARC releases (undefined behavior / leaks). LuaSwift never does this:
// when a `LuaClosure` throws, `LuaClosureWrapper.callClosure` *catches* the
// Swift error, pushes it via `L.push(error:)`, and returns the sentinel
// `LUASWIFT_CALLCLOSURE_ERROR`. Only then does the C trampoline
// `luaswift_callclosurewrapper` call `lua_error(L)` — in C, after every Swift
// frame (and its ARC objects) has already unwound normally. See
// `.build/checkouts/LuaSwift/Sources/Lua/LuaClosureWrapper.swift` and
// `.build/checkouts/LuaSwift/Sources/CLua/extensions.c`.
//
// THE ENTRY-POINT CONTRACT for WP1+ modules:
//
//   * The `luaopen_*` entry-point BODY is NON-THROWING. It only builds the
//     module table by pushing each function as a LuaSwift `LuaClosure` via
//     `L.push(_:)` (use `runEntryPoint` below, which wraps the non-throwing
//     build and returns 1). No Swift error ever crosses the C entry frame.
//
//   * Per-function errors (bad argument, range checks, e.g.
//     `hs.math.randomFromRange`, `hs.base64` decode failures) are THROWN from
//     inside the individual `LuaClosure`s. Those throws are caught by
//     LuaSwift's wrapper and converted to a Lua error via the C trampoline —
//     the only safe path. A thrown error becomes a *catchable* Lua error
//     (recoverable with `pcall`), never a process abort and never an
//     ARC-skipping longjmp from Swift.
//
// `runEntryPoint` is therefore a thin, NON-throwing convenience: it runs a
// table-building body and returns the conventional `1`. It does not catch or
// raise Lua errors itself, because the body cannot throw.

/// Run a NON-throwing module-table-building `body` as the implementation of a
/// `luaopen_*` entry point.
///
/// The body is expected to leave exactly one value (the module table) on the
/// Lua stack — typically by calling one of the `buildModuleTable` helpers — and
/// `runEntryPoint` returns `1` (the `luaopen_*` convention).
///
/// `body` is deliberately NON-throwing: an entry point must never let a Swift
/// error unwind across the C call boundary. Per-function errors belong inside
/// the individual `LuaClosure`s (which throw safely; see file header), not in
/// the entry-point body itself.
@discardableResult
func runEntryPoint(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ body: (LuaState) -> Void
) -> CInt {
    body(L)
    return 1
}

/// Throwing variant of `runEntryPoint` for entry points whose table-building
/// body needs to call throwing helpers (e.g. pushing constant tables built by
/// functions that also serve as `LuaClosure`s).  Errors are fatal — a throw
/// during module registration is a programming bug, not a recoverable Lua
/// error — so the body is called with `try!`.
@discardableResult
func runEntryPoint(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ body: (LuaState) throws -> Void
) -> CInt {
    try! body(L)
    return 1
}

// MARK: - Module table builders

/// Build a module table from an ordered list of `name -> lua_CFunction`
/// pairs, leaving exactly one table on the Lua stack and returning 1 (the
/// idiomatic `luaopen_*` return convention).
@discardableResult
func buildModuleTable(
    _ L: UnsafeMutablePointer<lua_State>!,
    functions: KeyValuePairs<String, lua_CFunction>
) -> CInt {
    lua_createtable(L, 0, CInt(functions.count))
    for (name, fn) in functions {
        lua_pushcclosure(L, fn, 0)
        lua_setfield(L, -2, name)
    }
    return 1
}

/// Build a module table from a dictionary of `name -> LuaClosure` Swift
/// closures, leaving exactly one table on the Lua stack and returning 1.
///
/// Each closure is pushed via the idiomatic `LuaState.push(_:)` so that thrown
/// Swift errors are converted to Lua errors by LuaSwift's closure wrapper.
@discardableResult
func buildModuleTable(
    _ L: UnsafeMutablePointer<lua_State>!,
    closures: [String: LuaClosure]
) -> CInt {
    lua_createtable(L, 0, CInt(closures.count))
    for (name, closure) in closures {
        L.push(closure)
        lua_setfield(L, -2, name)
    }
    return 1
}

// MARK: - Conversion parallels (characterization only)

/// Push `value` using the idiomatic `LuaState.push(any:)`.
///
/// Parallel to the home-grown `lua_pushany`. Provided only so the
/// characterization tests can compare the two; it is **not** a drop-in
/// replacement (see the NON-DELEGATABLE list at the top of this file).
func lua_pushany_idiomatic(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?) {
    L.push(any: value)
}

/// Pull a value using the idiomatic `LuaState.toany(_:guessType:)`.
///
/// Parallel to the home-grown `lua_tovalue`. Provided only for
/// characterization; `guessType: true` so strings/tables resolve to native
/// Swift values rather than `LuaStringRef`/`LuaTableRef` wrappers.
func lua_tovalue_idiomatic(_ L: UnsafeMutablePointer<lua_State>!, at index: CInt) -> Any? {
    return L.toany(index, guessType: true)
}
