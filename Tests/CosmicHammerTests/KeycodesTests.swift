import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Keycodes {
        @Test func testKeycodesWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libkeycodes) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    watcher = mod._newcallback(function() end)
                    watcher:_stop()
                    watcher:_stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.keycodes.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
