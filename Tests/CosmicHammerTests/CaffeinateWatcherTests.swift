import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class CaffeinateWatcher {
        @Test func testCaffeinateWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libcaffeinatewatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    watcher = mod.new(function() end)
                    watcher:start()
                    watcher:start()
                    watcher:stop()
                    watcher:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.caffeinate.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
