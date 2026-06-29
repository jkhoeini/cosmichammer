import AppKit
import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Sound {
        @Test func testSoundCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libsound) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let sound = HSSoundObject(sound: NSSound())
                setSoundCallbackCounted(sound, true, L: L)
                setSoundCallbackCounted(sound, true, L: L)
                setSoundCallbackCounted(sound, false, L: L)
                setSoundCallbackCounted(sound, false, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.sound.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
