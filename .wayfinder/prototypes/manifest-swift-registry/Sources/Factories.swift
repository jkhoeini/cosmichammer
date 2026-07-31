import CLua
import Lua

private let prototypeUserdataMetatable = "prototype.userdata"

private func prototypeUserdataValue(_ state: LuaState!) -> CInt {
    guard let state,
          let storage = luaL_checkudata(state, 1, prototypeUserdataMetatable)
    else { return 0 }
    lua_pushinteger(state, storage.assumingMemoryBound(to: lua_Integer.self).pointee)
    return 1
}

private func prototypeUserdataNew(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    let value = luaL_checkinteger(state, 1)
    let storage = lua_newuserdatauv(state, MemoryLayout<lua_Integer>.size, 0)!
    storage.assumingMemoryBound(to: lua_Integer.self).initialize(to: value)
    luaL_getmetatable(state, prototypeUserdataMetatable)
    lua_setmetatable(state, -2)
    return 1
}

func prototypeUserdataFactory(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    if luaL_newmetatable(state, prototypeUserdataMetatable) != 0 {
        lua_pushcfunction(state, prototypeUserdataValue)
        lua_setfield(state, -2, "value")
        lua_pushvalue(state, -1)
        lua_setfield(state, -2, "__index")
    }
    lua_pop(state, 1)
    lua_createtable(state, 0, 1)
    lua_pushcfunction(state, prototypeUserdataNew)
    lua_setfield(state, -2, "new")
    return 1
}

func prototypeSimpleFactoryV2(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    lua_createtable(state, 0, 2)
    lua_pushinteger(state, 42)
    lua_setfield(state, -2, "answer")
    lua_pushstring(state, "simple")
    lua_setfield(state, -2, "kind")
    return 1
}

private func prototypeInvokeCallback(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    luaL_checktype(state, 1, LUA_TFUNCTION)
    let value = luaL_checkinteger(state, 2)
    lua_pushvalue(state, 1)
    lua_pushinteger(state, value)
    precondition(lua_pcall(state, 1, 1, 0) == LUA_OK)
    return 1
}

func prototypeCallbackFactory(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    lua_createtable(state, 0, 2)
    lua_pushcfunction(state, prototypeInvokeCallback)
    lua_setfield(state, -2, "invoke")
    lua_pushstring(state, "callback")
    lua_setfield(state, -2, "kind")
    return 1
}

private func prototypeNestedChildFactory(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    lua_createtable(state, 0, 1)
    lua_pushinteger(state, 9)
    lua_setfield(state, -2, "answer")
    return 1
}

func prototypeNestedFactory(_ state: LuaState!) -> CInt {
    guard let state else { return 0 }
    lua_createtable(state, 0, 2)
    _ = prototypeNestedChildFactory(state)
    lua_setfield(state, -2, "child")
    lua_pushstring(state, "nested")
    lua_setfield(state, -2, "kind")
    return 1
}
