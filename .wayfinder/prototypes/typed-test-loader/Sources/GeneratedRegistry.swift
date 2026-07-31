// PROTOTYPE — generated typed module identity and private factory registry.
import CLua
import Lua

enum BundledLuaModule: String, CaseIterable {
    case callback = "hs.libprototype_callback"
    case nested = "hs.libprototype_nested"
    case simple = "hs.libprototype_simple"
    case userdata = "hs.libprototype_userdata"
}

private extension BundledLuaModule {
    var factory: Lua.lua_CFunction {
        switch self {
        case .callback: prototypeCallbackFactory
        case .nested: prototypeNestedFactory
        case .simple: prototypeSimpleFactoryV2
        case .userdata: prototypeUserdataFactory
        }
    }
}

func registerBundledLuaModules(in state: LuaState) {
    luaL_getsubtable(state, LUA_REGISTRYINDEX, "_PRELOAD")
    for module in BundledLuaModule.allCases {
        lua_pushcclosure(state, module.factory, 0)
        module.rawValue.withCString { key in
            lua_setfield(state, -2, key)
        }
    }
    lua_pop(state, 1)
}

@discardableResult
func loadBundledLuaModule(_ module: BundledLuaModule, in state: LuaState) -> CInt {
    module.factory(state)
}
