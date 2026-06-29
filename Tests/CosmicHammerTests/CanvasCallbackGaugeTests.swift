import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libcanvas")
private func luaopen_hs_libcanvas_for_callback_gauge(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class CanvasCallbackGaugeTests {
        @Test func testCanvasMouseCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libcanvas_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local canvas = mod.new({ x = 0, y = 0, w = 10, h = 10 })
                    canvas:mouseCallback(function() end)
                    canvas:mouseCallback(nil)
                    canvas:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.canvas.mouse.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func testCanvasDraggingCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libcanvas_for_callback_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local canvas = mod.new({ x = 0, y = 0, w = 10, h = 10 })
                    canvas:draggingCallback(function() return true end)
                    canvas:draggingCallback(nil)
                    canvas:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.canvas.dragging.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
