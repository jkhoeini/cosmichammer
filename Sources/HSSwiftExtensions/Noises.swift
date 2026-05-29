import Cocoa
import CLua
import Foundation

// MARK: - Constants

private let USERDATA_TAG = "hs.noises"
private var refTable: Int32 = LUA_NOREF

// MARK: - Lua functions (stubbed — noise detection is not implemented)

private let noises_listener_gc: lua_CFunction = { L in
    let userdata = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: Int32.self)
    let fn = userdata.pointee
    if fn != LUA_NOREF {
        // Unreference callback from the module ref table
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        luaL_unref(L, -1, fn)
        lua_pop(L, 1)
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
    guard lua_type(L, 1) == LUA_TFUNCTION else {
        return luaL_argerror(L, 1, "expected function")
    }

    let ud = lua_newuserdata(L, MemoryLayout<Int32>.size)!
        .assumingMemoryBound(to: Int32.self)
    // Store callback in the module ref table
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
    lua_pushvalue(L, 1)
    ud.pointee = luaL_ref(L, -2)
    lua_pop(L, 1) // pop module ref table

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
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")  // mt.__index = mt
    luaL_setfuncs(L, &noises_metalib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(noisesLib.count - 1))
    luaL_setfuncs(L, &noisesLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(noises_meta_gcLib.count - 1))
    luaL_setfuncs(L, &noises_meta_gcLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
