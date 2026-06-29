import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class WebviewEvaluateJavaScriptCallback {
        @Test func testWebviewEvaluateJavaScriptCallbackActiveGauge() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            sim.configure(TelemetryConfiguration(enabled: true))

            let token = WebViewEvaluateJavaScriptCallbackGaugeToken(L: L)
            token.finish(L: L)
            token.finish(L: L)

            let gaugeValues = sim.metrics
                .filter { $0.name == "cosmichammer.webview.evaluate_javascript.callback.active" }
                .map(\.value)
            #expect(gaugeValues.count == 2)
            #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
        }
    }
}
