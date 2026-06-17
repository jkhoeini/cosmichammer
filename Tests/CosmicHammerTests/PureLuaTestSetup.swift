import CLua
import Foundation
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

/// Lock serializing access to the global Environment across parallel test suites.
/// Without this, concurrent withLuaState calls race on environmentSetGlobal / environmentClearGlobal.
let globalEnvLock = NSLock()

/// Create a standalone Lua state with standard libraries open, run the body,
/// then close it.  This avoids the AppKit-dependent MJLuaAlloc path and
/// works headlessly in `swift test`.
func withLuaState(_ body: (UnsafeMutablePointer<lua_State>) throws -> Void) rethrows {
    try withLuaState(faults: FaultConfig(), body)
}

func withLuaState(faults: FaultConfig, _ body: (UnsafeMutablePointer<lua_State>) throws -> Void) rethrows {
    globalEnvLock.lock()
    let L = luaL_newstate()!
    luaL_openlibs(L)
    let harness = SimulatorHarness(seed: 42)
    let simEnv = harness.createEnvironment(faults: faults)
    environmentAttach(L, simEnv)
    environmentSetGlobal(simEnv)
    defer {
        environmentClearGlobal()
        // lua_close triggers __gc which may call environmentGet(L),
        // so close before detaching the environment.
        let extra = lua_getextraspace(L)!
        let envRaw = extra.load(as: UnsafeMutableRawPointer?.self)
        lua_close(L)
        if let envRaw = envRaw {
            Unmanaged<Environment>.fromOpaque(envRaw).release()
        }
        globalEnvLock.unlock()
    }
    try body(L)
}

/// Create a fresh Lua state, call `luaopenFn` to register a module, set the
/// returned table as global "mod", run `body`, then close the state.
func withModuleLoaded(_ luaopenFn: @escaping (UnsafeMutablePointer<lua_State>?) -> Int32,
                      _ body: (UnsafeMutablePointer<lua_State>) throws -> Void) rethrows {
    try withLuaState { L in
        let result = luaopenFn(L)
        assert(result == 1, "Module registration failed")
        lua_setglobal(L, "mod")  // module table accessible as "mod" in Lua
        try body(L)
    }
}

/// Run a string of Lua code.  Returns true on success.
func luaEval(_ L: UnsafeMutablePointer<lua_State>, _ code: String) -> Bool {
    return luaL_dostring(L, code) == LUA_OK
}

/// Run a Lua expression and return the top-of-stack result as a String (if it is one).
func luaEvalString(_ L: UnsafeMutablePointer<lua_State>, _ code: String) -> String? {
    if luaL_dostring(L, code) == LUA_OK {
        if lua_type(L, -1) == LUA_TSTRING {
            return String(cString: lua_tostring(L, -1))
        }
    }
    return nil
}

/// Run a Lua expression and return the top-of-stack result as a Double (if it is a number).
func luaEvalNumber(_ L: UnsafeMutablePointer<lua_State>, _ code: String) -> Double? {
    if luaL_dostring(L, code) == LUA_OK {
        if lua_type(L, -1) == LUA_TNUMBER {
            return lua_tonumber(L, -1)
        }
    }
    return nil
}

/// Run a Lua expression and return the top-of-stack result as an Int (if it is an integer).
func luaEvalInt(_ L: UnsafeMutablePointer<lua_State>, _ code: String) -> Int? {
    if luaL_dostring(L, code) == LUA_OK {
        if lua_type(L, -1) == LUA_TNUMBER && lua_isinteger(L, -1) != 0 {
            return Int(lua_tointeger(L, -1))
        }
    }
    return nil
}

/// Run a Lua expression and return the top-of-stack result as a Bool.
func luaEvalBool(_ L: UnsafeMutablePointer<lua_State>, _ code: String) -> Bool? {
    if luaL_dostring(L, code) == LUA_OK {
        if lua_type(L, -1) == LUA_TBOOLEAN {
            return lua_toboolean(L, -1) != 0
        }
    }
    return nil
}

/// Return the Lua error message from a failed luaL_dostring call.
func luaErrorMsg(_ L: UnsafeMutablePointer<lua_State>, _ code: String) -> String? {
    if luaL_dostring(L, code) != LUA_OK {
        if lua_type(L, -1) == LUA_TSTRING {
            let msg = String(cString: lua_tostring(L, -1))
            lua_pop(L, 1)
            return msg
        }
        lua_pop(L, 1)
        return "unknown error"
    }
    return nil
}
