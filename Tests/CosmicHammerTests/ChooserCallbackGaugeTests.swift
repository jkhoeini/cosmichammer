import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ChooserCallbackGauge {
        @Test func testChooserCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libchooser) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    c = mod.new(function() end)
                    c:hideCallback(function() end)
                    c:hideCallback(function() end)
                    c:hideCallback(nil)
                    c:choices(function() return { { text = "dynamic" } } end)
                    c:choices({ { text = "static" } })
                    c:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.chooser.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 6)
                #expect(gaugeValues[1] == gaugeValues[0] + 1)
                #expect(gaugeValues[2] == gaugeValues[1] - 1)
                #expect(gaugeValues[3] == gaugeValues[2] + 1)
                #expect(gaugeValues[4] == gaugeValues[3] - 1)
                #expect(gaugeValues[5] == gaugeValues[4] - 1)
            }
        }
    }
}
