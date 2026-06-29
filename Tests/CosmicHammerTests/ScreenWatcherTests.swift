import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ScreenWatcher {
        @Test func testScreenWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libscreenwatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    watcher = mod.new(function() end)
                    activeWatcher = mod.newWithActiveScreen(function() end)
                    watcher:start()
                    watcher:start()
                    activeWatcher:start()
                    activeWatcher:start()
                    watcher:stop()
                    watcher:stop()
                    activeWatcher:stop()
                    activeWatcher:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.screen.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 4)
                let deltas = zip(gaugeValues, gaugeValues.dropFirst()).map { $0.1 - $0.0 }
                #expect(deltas == [1, -1, -1])
            }
        }
    }
}
