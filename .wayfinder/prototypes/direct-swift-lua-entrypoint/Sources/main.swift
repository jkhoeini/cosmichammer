import CLua
import Darwin
import Lua

private let moduleName = "prototype.direct_swift_entrypoint"

private func luaopenPrototype(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let L else { return 0 }
    lua_createtable(L, 0, 1)
    lua_pushinteger(L, 42)
    lua_setfield(L, -2, "answer")
    return 1
}

private func installPreload(
    _ L: UnsafeMutablePointer<lua_State>,
    entrypoint: Lua.lua_CFunction
) {
    luaL_getsubtable(L, LUA_REGISTRYINDEX, "_PRELOAD")
    lua_pushcclosure(L, entrypoint, 0)
    lua_setfield(L, -2, moduleName)
    lua_pop(L, 1)
}

let productionTyped: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = luaopenPrototype
let luaSwiftTyped: Lua.lua_CFunction = productionTyped

guard let L = luaL_newstate() else { fatalError("luaL_newstate failed") }
defer { lua_close(L) }
luaL_openlibs(L)
installPreload(L, entrypoint: luaSwiftTyped)

let script = "local m = require('\(moduleName)'); assert(m.answer == 42)"
guard luaL_loadstring(L, script) == LUA_OK, lua_pcall(L, 0, 0, 0) == LUA_OK else {
    let message = lua_tostring(L, -1).map(String.init(cString:)) ?? "unknown Lua error"
    fatalError(message)
}

#if PROTOTYPE_DEBUG
let configuration = "debug"
#else
let configuration = "release"
#endif
print("configuration=\(configuration) preload=require-ok answer=42")
