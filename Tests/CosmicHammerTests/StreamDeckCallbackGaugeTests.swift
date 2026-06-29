import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libstreamdeck")
private func luaopen_hs_libstreamdeck_for_callback_gauge(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class StreamDeckCallbackGaugeTests {
        @Test func streamDeckDiscoveryCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libstreamdeck_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustStreamDeckDiscoveryCallbackCount(-1000, L: L)
                adjustStreamDeckDiscoveryCallbackCount(1, L: L)
                adjustStreamDeckDiscoveryCallbackCount(1, L: L)
                adjustStreamDeckDiscoveryCallbackCount(-1, L: L)
                adjustStreamDeckDiscoveryCallbackCount(-1000, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.streamdeck.discovery.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [0, 1, 2, 1, 0])
            }
        }

        @Test func streamDeckDeviceCallbackActiveGauges() {
            withModuleLoaded(luaopen_hs_libstreamdeck_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustStreamDeckButtonCallbackCount(-1000, L: L)
                adjustStreamDeckButtonCallbackCount(1, L: L)
                adjustStreamDeckButtonCallbackCount(-1, L: L)

                adjustStreamDeckEncoderCallbackCount(-1000, L: L)
                adjustStreamDeckEncoderCallbackCount(1, L: L)
                adjustStreamDeckEncoderCallbackCount(-1, L: L)

                adjustStreamDeckScreenCallbackCount(-1000, L: L)
                adjustStreamDeckScreenCallbackCount(1, L: L)
                adjustStreamDeckScreenCallbackCount(-1, L: L)

                let buttonValues = sim.metrics
                    .filter { $0.name == "cosmichammer.streamdeck.button.callback.active" }
                    .map(\.value)
                let encoderValues = sim.metrics
                    .filter { $0.name == "cosmichammer.streamdeck.encoder.callback.active" }
                    .map(\.value)
                let screenValues = sim.metrics
                    .filter { $0.name == "cosmichammer.streamdeck.screen.callback.active" }
                    .map(\.value)

                #expect(buttonValues == [0, 1, 0])
                #expect(encoderValues == [0, 1, 0])
                #expect(screenValues == [0, 1, 0])
            }
        }
    }
}
