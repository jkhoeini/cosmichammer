import Cocoa
import Foundation
import LuaSkin

// MARK: - Constants

private let USERDATA_TAG = "hs.noises"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Lua functions (stubbed — noise detection is not implemented)

private let noises_listener_gc: lua_CFunction = { L in
    let userdata = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: Int32.self)
    let skin = LuaSkin.skin(with: L)
    let fn = userdata.pointee
    if fn != LUA_NOREF {
        _ = skin.luaUnref(refTable, ref: fn)
    }
    return 0
}

private let noises_listener_stop: lua_CFunction = { L in
    lua_settop(L, 1)
    return 1
}

private let noises_listener_start: lua_CFunction = { L in
    return luaL_error(L, "hs.noises: noise detection is not implemented in this version")
}

private let noises_listener_eq: lua_CFunction = { L in
    let udA = luaL_checkudata(L, 1, USERDATA_TAG)!
    let udB = luaL_checkudata(L, 2, USERDATA_TAG)!
    lua_pushboolean(L, udA == udB ? 1 : 0)
    return 1
}

/// hs.noises.new(fn) -> listener
/// Constructor
/// Creates a new listener for mouth noise recognition (stub — not implemented)
private let noises_listener_new: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    let ud = lua_newuserdata(L, MemoryLayout<Int32>.size)!
        .assumingMemoryBound(to: Int32.self)
    lua_pushvalue(L, 1)
    ud.pointee = skin.luaRef(refTable)

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private let noises_meta_gc: lua_CFunction = { _ in
    return 0
}

// MARK: - Lua registration tables

// Metatable for created objects when _new invoked
private var noises_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),  func: noises_listener_start),
    luaL_Reg(name: strdup("stop"),   func: noises_listener_stop),
    luaL_Reg(name: strdup("__gc"),   func: noises_listener_gc),
    luaL_Reg(name: strdup("__eq"),   func: noises_listener_eq),
    luaL_Reg(name: nil,              func: nil),
]

// Functions for returned object when module loads
private var noisesLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),  func: noises_listener_new),
    luaL_Reg(name: nil,            func: nil),
]

// Metatable for returned object when module loads
private var noises_meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: noises_meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libnoises")
public func luaopen_hs_libnoises(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &noisesLib,
                                    metaFunctions: &noises_meta_gcLib,
                                    objectFunctions: &noises_metalib)
    return 1
}
