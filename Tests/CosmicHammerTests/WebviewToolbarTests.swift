import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class WebviewToolbar {
        @Test func testWebviewToolbarCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libwebviewtoolbar) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let identifier = "toolbarGauge\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                lua_pushstring(L, identifier)
                lua_setglobal(L, "toolbarGaugeIdentifier")

                #expect(luaEval(L, """
                    toolbar = mod.new(toolbarGaugeIdentifier, {
                        { id = "item", label = "Item" },
                    })
                    toolbar:setCallback(function() end)
                    toolbar:setCallback(function() end)
                    toolbar:setCallback(nil)
                    toolbar:setCallback(nil)
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.webview.toolbar.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
