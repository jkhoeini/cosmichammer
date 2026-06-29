import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class WebviewWindowCallback {
        @Test(.skipInHeadless) func testWebviewWindowCallbackActiveGauge() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            sim.configure(TelemetryConfiguration(enabled: true))

            let result = runLua("""
                local webview = require("hs.webview")
                local view = webview.new({ x = 0, y = 0, w = 120, h = 80 })
                if type(view) ~= "userdata" then
                    return "webview.new returned " .. type(view) .. ": " .. tostring(view)
                end
                view:windowCallback(function() end)
                view:windowCallback(function() end)
                view:windowCallback(nil)
                view:windowCallback(nil)
                view:delete()
                return "ok"
            """)
            #expect(result == "ok")

            let gaugeValues = sim.metrics
                .filter { $0.name == "cosmichammer.webview.window.callback.active" }
                .map(\.value)
            #expect(gaugeValues.count == 2)
            #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
        }
    }
}
