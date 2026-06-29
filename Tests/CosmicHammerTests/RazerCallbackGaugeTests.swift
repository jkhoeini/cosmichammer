import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_librazer")
private func luaopen_hs_librazer_for_callback_gauge(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class RazerCallbackGaugeTests {
        @Test func razerDiscoveryCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_librazer_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustRazerDiscoveryCallbackCount(-1000, L: L)
                adjustRazerDiscoveryCallbackCount(1, L: L)
                adjustRazerDiscoveryCallbackCount(1, L: L)
                adjustRazerDiscoveryCallbackCount(-1, L: L)
                adjustRazerDiscoveryCallbackCount(-1000, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.razer.discovery.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [0, 1, 2, 1, 0])
            }
        }

        @Test func razerButtonCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_librazer_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustRazerButtonCallbackCount(-1000, L: L)
                adjustRazerButtonCallbackCount(1, L: L)
                adjustRazerButtonCallbackCount(-1, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.razer.button.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [0, 1, 0])
            }
        }
    }
}
