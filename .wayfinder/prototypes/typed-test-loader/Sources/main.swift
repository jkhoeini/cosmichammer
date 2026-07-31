import CLua
import Lua

private struct ModuleObservation: Equatable {
    let resultCount: CInt
    let stackDelta: CInt
    let resultType: CInt
    let behavior: String
    let shape: String
}

private let legacyFactories: [BundledLuaModule: Lua.lua_CFunction] = [
    .callback: prototypeCallbackFactory,
    .nested: prototypeNestedFactory,
    .simple: prototypeSimpleFactoryV2,
    .userdata: prototypeUserdataFactory,
]

private func withLuaState<T>(_ body: (LuaState) -> T) -> T {
    guard let state = luaL_newstate() else { fatalError("luaL_newstate failed") }
    luaL_openlibs(state)
    defer { lua_close(state) }
    return body(state)
}

private func errorMessage(_ state: LuaState) -> String {
    lua_tostring(state, -1).map(String.init(cString:)) ?? "unknown Lua error"
}

private func behaviorScript(for module: BundledLuaModule) -> String {
    switch module {
    case .callback:
        "return tostring(mod.invoke(function(x) return x + 1 end, 41)) .. ':' .. mod.kind"
    case .nested:
        "return tostring(mod.child.answer) .. ':' .. mod.kind"
    case .simple:
        "return tostring(mod.answer) .. ':' .. mod.kind"
    case .userdata:
        "local value = mod.new(7); return type(value) .. ':' .. tostring(value:value())"
    }
}

private func readBehavior(_ module: BundledLuaModule, in state: LuaState) -> String {
    let script = behaviorScript(for: module)
    guard luaL_loadstring(state, script) == LUA_OK,
          lua_pcall(state, 0, 1, 0) == LUA_OK
    else { fatalError(errorMessage(state)) }
    guard let value = lua_tostring(state, -1) else { fatalError("behavior did not return a string") }
    let result = String(cString: value)
    lua_pop(state, 1)
    return result
}

private func readShape(in state: LuaState) -> String {
    let script = """
    local fields = {}
    for key, value in pairs(mod) do
        fields[#fields + 1] = tostring(key) .. '=' .. type(value)
    end
    table.sort(fields)
    return table.concat(fields, ',')
    """
    guard luaL_loadstring(state, script) == LUA_OK,
          lua_pcall(state, 0, 1, 0) == LUA_OK
    else { fatalError(errorMessage(state)) }
    guard let value = lua_tostring(state, -1) else { fatalError("shape did not return a string") }
    let result = String(cString: value)
    lua_pop(state, 1)
    return result
}

private func observeDirect(
    _ module: BundledLuaModule,
    loader: (LuaState) -> CInt
) -> ModuleObservation {
    withLuaState { state in
        let baseTop = lua_gettop(state)
        let resultCount = loader(state)
        let stackDelta = lua_gettop(state) - baseTop
        let resultType = lua_type(state, -1)
        precondition(resultCount == 1)
        precondition(stackDelta == 1)
        precondition(resultType == LUA_TTABLE)
        lua_setglobal(state, "mod")
        let shape = readShape(in: state)
        let behavior = readBehavior(module, in: state)
        precondition(lua_gettop(state) == baseTop)
        return ModuleObservation(
            resultCount: resultCount,
            stackDelta: stackDelta,
            resultType: resultType,
            behavior: behavior,
            shape: shape,
        )
    }
}

private func observeRequire(_ module: BundledLuaModule) -> ModuleObservation {
    withLuaState { state in
        registerBundledLuaModules(in: state)
        let baseTop = lua_gettop(state)
        let script = """
        local name = '\(module.rawValue)'
        local original = assert(package.preload[name])
        local calls = 0
        local delegated
        package.preload[name] = function(...)
            calls = calls + 1
            delegated = original(...)
            return delegated
        end
        local loaded = require(name)
        assert(calls == 1, 'registered factory must run exactly once')
        assert(rawequal(loaded, delegated), 'require must return the registered factory result')
        assert(rawequal(loaded, package.loaded[name]), 'require result must be cached')
        return loaded
        """
        guard luaL_loadstring(state, script) == LUA_OK,
              lua_pcall(state, 0, 1, 0) == LUA_OK
        else { fatalError(errorMessage(state)) }
        let stackDelta = lua_gettop(state) - baseTop
        let resultType = lua_type(state, -1)
        precondition(stackDelta == 1)
        precondition(resultType == LUA_TTABLE)
        lua_setglobal(state, "mod")
        let shape = readShape(in: state)
        let behavior = readBehavior(module, in: state)
        precondition(lua_gettop(state) == baseTop)
        return ModuleObservation(
            resultCount: 1,
            stackDelta: stackDelta,
            resultType: resultType,
            behavior: behavior,
            shape: shape,
        )
    }
}

var evidence: [String] = []
for module in BundledLuaModule.allCases {
    guard let legacyFactory = legacyFactories[module] else { fatalError("missing legacy factory") }
    let legacy = observeDirect(module) { legacyFactory($0) }
    let typed = observeDirect(module) { loadBundledLuaModule(module, in: $0) }
    let required = observeRequire(module)
    precondition(legacy == typed)
    precondition(typed == required)
    evidence.append("\(module)=\(typed.behavior)")
}

let order = BundledLuaModule.allCases.map(\.rawValue).joined(separator: ",")
#if PROTOTYPE_DEBUG
let configuration = "debug"
#else
let configuration = "release"
#endif
print("configuration=\(configuration) order=\(order) modules=4/4 legacy=typed=require stack=balanced \(evidence.joined(separator: ";"))")
