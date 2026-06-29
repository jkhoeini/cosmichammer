import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_liblsqlite3")
private func luaopen_hs_liblsqlite3_for_callback_gauge(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class SQLite3CallbackGaugeTests {
        @Test func sqliteHookCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_liblsqlite3_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local db = mod.open_memory()
                    db:busy_handler(function() return false end)
                    db:busy_handler(function() return false end)
                    db:progress_handler(1, function() return false end)
                    db:trace(function() end)
                    db:update_hook(function() end)
                    db:commit_hook(function() return false end)
                    db:rollback_hook(function() end)
                    db:busy_timeout(0)
                    db:progress_handler(nil)
                    db:trace(nil)
                    db:update_hook(nil)
                    db:commit_hook(nil)
                    db:rollback_hook(nil)
                    db:close()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.sqlite3.hook.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1, 0])
            }
        }

        @Test func sqliteFunctionCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_liblsqlite3_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local db = mod.open_memory()
                    assert(db:create_function("noop", 0, function(ctx) end))
                    assert(db:create_aggregate("noop_agg", 0, function(ctx) end, function(ctx) end))
                    db:close()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.sqlite3.function.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 2, 0])
            }
        }
    }
}
