import CLua
import Foundation
import HSDSTCore
import HSDSTSimulator
import HSSwiftExtensions

@_silgen_name("luaopen_hs_libopentelemetry")
private func luaopen_hs_libopentelemetry(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

private let luaRegistryIndexValue: Int32 = LUA_REGISTRYINDEX

struct LuaBenchmarkReturn {
    var operations: Int
    var checksum: Int
}

final class LuaOTELBenchmarkRuntime {
    private let L: UnsafeMutablePointer<lua_State>
    private let environment: Environment

    init(telemetryBackend: TelemetryBackend) throws {
        guard let state = luaL_newstate() else {
            throw BenchmarkError.lua("unable to create Lua state")
        }
        L = state
        luaL_openlibs(L)

        switch telemetryBackend {
        case .simulated:
            let harness = SimulatorHarness(seed: 42)
            environment = harness.createEnvironment()
        case .production:
            environment = createProductionEnvironment()
        }
        environmentAttach(L, environment)
        environmentSetGlobal(environment)

        let result = luaopen_hs_libopentelemetry(L)
        guard result == 1, lua_type(L, -1) == LUA_TTABLE else {
            throw BenchmarkError.lua("luaopen_hs_libopentelemetry did not return a module table")
        }
        lua_setglobal(L, "otel")
    }

    deinit {
        environmentClearGlobal()
        let extra = lua_getextraspace(L)!
        let envRaw = extra.load(as: UnsafeMutableRawPointer?.self)
        lua_close(L)
        if let envRaw {
            Unmanaged<Environment>.fromOpaque(envRaw).release()
        }
    }

    func configureTelemetry(enabled: Bool) throws {
        let enabledLiteral = enabled ? "true" : "false"
        let code = """
        otel.configure({
          enabled = \(enabledLiteral),
          serviceName = "cosmichammer-otel-benchmark",
          exporter = "console",
          traces = true,
          logs = true,
          metrics = true,
          callbackSampleRates = {
            ["hs.eventtap"] = 0,
            ["hs.sqlite3.progressHandler"] = 0,
          },
        })
        """
        try eval(code)
    }

    func loadRunFunction(scriptURL: URL) throws -> Int32 {
        let baseTop = lua_gettop(L)
        let path = scriptURL.path as NSString
        let loadResult = luaL_loadfilex(L, path.fileSystemRepresentation, nil)
        guard loadResult == LUA_OK else {
            let message = popLuaError(defaultMessage: "unable to load \(scriptURL.path)")
            lua_settop(L, baseTop)
            throw BenchmarkError.lua(message)
        }

        guard lua_pcall(L, 0, 1, 0) == LUA_OK else {
            let message = popLuaError(defaultMessage: "error evaluating \(scriptURL.path)")
            lua_settop(L, baseTop)
            throw BenchmarkError.lua(message)
        }

        guard lua_type(L, -1) == LUA_TTABLE else {
            lua_settop(L, baseTop)
            throw BenchmarkError.lua("\(scriptURL.lastPathComponent) must return a table")
        }

        lua_getfield(L, -1, "run")
        guard lua_type(L, -1) == LUA_TFUNCTION else {
            lua_settop(L, baseTop)
            throw BenchmarkError.lua("\(scriptURL.lastPathComponent) must return a run function")
        }

        let ref = luaL_ref(L, luaRegistryIndexValue)
        lua_pop(L, 1)
        assert(lua_gettop(L) == baseTop)
        return ref
    }

    func releaseRunFunction(_ ref: Int32) {
        luaL_unref(L, luaRegistryIndexValue, ref)
    }

    func run(ref: Int32, iterations: Int) throws -> LuaBenchmarkReturn {
        let baseTop = lua_gettop(L)
        lua_rawgeti(L, luaRegistryIndexValue, lua_Integer(ref))
        lua_pushinteger(L, lua_Integer(iterations))

        guard lua_pcall(L, 1, 1, 0) == LUA_OK else {
            let message = popLuaError(defaultMessage: "benchmark run failed")
            lua_settop(L, baseTop)
            throw BenchmarkError.lua(message)
        }

        guard lua_type(L, -1) == LUA_TTABLE else {
            lua_settop(L, baseTop)
            throw BenchmarkError.lua("benchmark run must return a table")
        }

        let tableIndex = lua_absindex(L, -1)
        let operations = integerField("operations", at: tableIndex) ?? iterations
        let checksum = integerField("checksum", at: tableIndex) ?? 0
        lua_settop(L, baseTop)
        return LuaBenchmarkReturn(operations: operations, checksum: checksum)
    }

    func telemetryCounters() -> TelemetryCounters {
        TelemetryCounters(status: environment.telemetry.status())
    }

    // Benchmarks intentionally execute checked-in local Lua workloads and small
    // configuration snippets inside an isolated Lua state.
    private func eval(_ code: String) throws {
        guard luaL_loadstring(L, code) == LUA_OK else {
            throw BenchmarkError.lua(popLuaError(defaultMessage: "Lua evaluation failed"))
        }
        guard lua_pcall(L, 0, LUA_MULTRET, 0) == LUA_OK else {
            throw BenchmarkError.lua(popLuaError(defaultMessage: "Lua evaluation failed"))
        }
    }

    private func integerField(_ name: String, at tableIndex: Int32) -> Int? {
        lua_getfield(L, tableIndex, name)
        defer { lua_pop(L, 1) }
        guard lua_isinteger(L, -1) != 0 else { return nil }
        return Int(lua_tointeger(L, -1))
    }

    private func popLuaError(defaultMessage: String) -> String {
        defer { lua_pop(L, 1) }
        guard lua_type(L, -1) == LUA_TSTRING, let rawMessage = lua_tostring(L, -1) else {
            return defaultMessage
        }
        return String(cString: rawMessage)
    }
}
