// PROTOTYPE — generated direct-reference registry. Delete after the decision is absorbed.
import CLua
import Lua

private struct BundledLuaModule {
    let preloadKey: String
    let factory: Lua.lua_CFunction
}

private let bundledLuaModules: [BundledLuaModule] = [
    BundledLuaModule(preloadKey: "hs.libprototype_callback", factory: prototypeCallbackFactory),
    BundledLuaModule(preloadKey: "hs.libprototype_nested", factory: prototypeNestedFactory),
    BundledLuaModule(preloadKey: "hs.libprototype_simple", factory: prototypeSimpleFactoryV2),
    BundledLuaModule(preloadKey: "hs.libprototype_userdata", factory: prototypeUserdataFactory),
]

func registerBundledLuaModules(in state: LuaState) {
    luaL_getsubtable(state, LUA_REGISTRYINDEX, "_PRELOAD")
    for module in bundledLuaModules {
        lua_pushcclosure(state, module.factory, 0)
        module.preloadKey.withCString { key in
            lua_setfield(state, -2, key)
        }
    }
    lua_pop(state, 1)
}
