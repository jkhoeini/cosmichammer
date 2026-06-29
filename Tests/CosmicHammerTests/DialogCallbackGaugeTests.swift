import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libdialog")
private func luaopen_hs_libdialog_for_callback_gauge(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class DialogCallbackGaugeTests {
        @Test func testDialogColorCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libdialog_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                setDialogColorCallbackCounted(false, L: L)
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                setDialogColorCallbackCounted(true, L: L)
                setDialogColorCallbackCounted(true, L: L)
                setDialogColorCallbackCounted(false, L: L)
                setDialogColorCallbackCounted(false, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.dialog.color.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 0])
            }
        }

        @Test func testDialogWebviewAlertCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libdialog_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let token = DialogWebviewAlertCallbackGaugeToken(L: L)
                token.finish(L: L)
                token.finish(L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.dialog.webview_alert.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 0])
            }
        }
    }
}
