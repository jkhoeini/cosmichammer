import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class AudiodeviceWatcher {
        @Test func testAudiodeviceWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libaudiodevicewatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    mod.setCallback(function() end)
                    mod.start()
                    mod.start()
                    mod.stop()
                    mod.stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.audiodevice.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
