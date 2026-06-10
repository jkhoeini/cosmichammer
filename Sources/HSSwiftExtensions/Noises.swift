import Cocoa
import CLua
import Lua
import Foundation

// MARK: - Constants

private let USERDATA_TAG = "hs.noises"
private var refTable: Int32 = LUA_NOREF

// MARK: - Lua functions (stubbed — noise detection is not implemented)

private func noises_listener_gc(_ L: LuaState) throws -> CInt {
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

private func noises_listener_stop(_ L: LuaState) throws -> CInt {
    lua_settop(L, 1)
    return 1
}

private func noises_listener_start(_ L: LuaState) throws -> CInt {
    throw LuaCallError("hs.noises: noise detection is not implemented in this version")
}

private func noises_listener_eq(_ L: LuaState) throws -> CInt {
    let udA = luaL_checkudata(L, 1, USERDATA_TAG)!
    let udB = luaL_checkudata(L, 2, USERDATA_TAG)!
    lua_pushboolean(L, udA == udB ? 1 : 0)
    return 1
}

/// hs.noises.new(fn) -> listener
/// Constructor
/// Creates a new listener for mouth noise recognition (stub — not implemented)
private func noises_listener_new(_ L: LuaState) throws -> CInt {
    guard lua_type(L, 1) == LUA_TFUNCTION else {
        throw LuaCallError("bad argument #1 (expected function)")
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

private func noises_meta_gc(_ L: LuaState) throws -> CInt {
    return 0
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libnoises")
public func luaopen_hs_libnoises(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")  // mt.__index = mt
        L.push(noises_listener_start)
        lua_setfield(L, -2, "start")
        L.push(noises_listener_stop)
        lua_setfield(L, -2, "stop")
        L.push(noises_listener_gc)
        lua_setfield(L, -2, "__gc")
        L.push(noises_listener_eq)
        lua_setfield(L, -2, "__eq")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(noises_listener_new)
        lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(noises_meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
