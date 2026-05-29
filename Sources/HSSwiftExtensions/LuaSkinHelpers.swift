import CLua
import Foundation

// MARK: - Lua C Macros (not importable to Swift)
//
// CLua exposes Lua's C API inline functions, but some remain as
// C macros that the Swift compiler can't import. We provide Swift
// equivalents here.

/// LUA_REGISTRYINDEX exposed as a Swift constant.
/// CLua makes `LUA_REGISTRYINDEX` available, but extension code has
/// historically referred to `LUA_REGISTRYINDEX_VALUE`.
let LUA_REGISTRYINDEX_VALUE: Int32 = LUA_REGISTRYINDEX

let LUA_RIDX_GLOBALS: Int = 2

// ---------------------------------------------------------------
// Functions NOT provided by CLua's inline bridge
// ---------------------------------------------------------------

func luaL_dostring(_ L: UnsafeMutablePointer<lua_State>!, _ s: UnsafePointer<CChar>!) -> Int32 {
    let r = luaL_loadstring(L, s)
    return r != 0 ? r : lua_pcall(L, 0, LUA_MULTRET, 0)
}

func luaL_checkstring(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> UnsafePointer<CChar>! {
    luaL_checklstring(L, n, nil)
}

@discardableResult
func luaL_error(_ L: UnsafeMutablePointer<lua_State>!, _ fmt: String) -> Int32 {
    lua_pushstring(L, fmt)
    return lua_error(L)
}

func luaL_argcheck(_ L: UnsafeMutablePointer<lua_State>!, _ cond: Bool, _ arg: Int32, _ extramsg: UnsafePointer<CChar>!) {
    if !cond {
        luaL_argerror(L, arg, extramsg)
    }
}

func luaL_checkversion(_ L: UnsafeMutablePointer<lua_State>!) {
    let numSizes = MemoryLayout<lua_Integer>.size * 16 + MemoryLayout<lua_Number>.size
    luaL_checkversion_(L, lua_Number(LUA_VERSION_NUM), numSizes)
}

func lua_isnone(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TNONE
}

// lua_rawlen: the C function returns lua_Unsigned (UInt), but our
// codebase expects Int.  Provide a typed Swift wrapper via @_silgen_name.
@_silgen_name("lua_rawlen")
private func c_lua_rawlen(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UInt

func lua_rawlen(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Int {
    Int(c_lua_rawlen(L, idx))
}

// ---------------------------------------------------------------
// Bool-returning overloads for lua_is* functions
//
// CLua provides these as inline C functions returning Int32 (C int).
// Swift callers overwhelmingly use `if lua_isnil(L, n)` which requires
// Bool.  These Swift wrappers shadow the C imports.
// ---------------------------------------------------------------

func lua_isnil(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TNIL
}

func lua_isstring(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TSTRING
}

func lua_isnumber(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TNUMBER
}

func lua_isboolean(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TBOOLEAN
}

func lua_istable(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TTABLE
}

func lua_isfunction(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TFUNCTION
}

func lua_isuserdata(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TUSERDATA
}

func lua_islightuserdata(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TLIGHTUSERDATA
}

func lua_isnoneornil(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) <= 0
}

// ---------------------------------------------------------------
// Stack guard helpers (debug builds only)
// ---------------------------------------------------------------

#if DEBUG
/// Thread-local stack tracking expected Lua stack levels for stackguard pairs.
private var _stackguardLevels: [Int32] {
    get {
        Thread.current.threadDictionary["_lua_stackguard_levels"] as? [Int32] ?? []
    }
    set {
        Thread.current.threadDictionary["_lua_stackguard_levels"] = newValue
    }
}

func _lua_stackguard_entry(_ L: UnsafeMutablePointer<lua_State>!) {
    guard let L = L else { return }
    _stackguardLevels.append(lua_gettop(L))
}

func _lua_stackguard_exit(_ L: UnsafeMutablePointer<lua_State>!) {
    guard let L = L else { return }
    let expected = _stackguardLevels.removeLast()
    let actual = lua_gettop(L)
    assert(expected == actual,
           "Lua stack imbalance: expected \(expected), got \(actual)")
}
#else
func _lua_stackguard_entry(_ L: Any?) {}
func _lua_stackguard_exit(_ L: Any?) {}
#endif
