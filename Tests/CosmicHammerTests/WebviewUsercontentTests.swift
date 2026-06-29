import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class WebviewUsercontent {
        @Test func testWebviewUsercontentCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libwebviewusercontent) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let portName = "usercontentGauge\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                lua_pushstring(L, portName)
                lua_setglobal(L, "usercontentGaugePortName")

                #expect(luaEval(L, """
                    usercontent = mod.new(usercontentGaugePortName)
                    usercontent:setCallback(function() end)
                    usercontent:setCallback(function() end)
                    usercontent:setCallback(nil)
                    usercontent:setCallback(nil)
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.webview.usercontent.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
