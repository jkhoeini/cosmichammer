import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Hotkey {
        init() throws { try loadLuaModule("test_hotkey") }

        @Test func testAssignable() { runLuaTest() }
        @Test func testGetHotkeys() { runLuaTest() }
        @Test(.requiresRealOS) func testGetSystemAssigned() { runLuaTest() }

        @Test(.requiresRealOS) func testBasicHotkey() {
            runTwoPartLuaTest(timeout: 2)
        }

        @Test(.requiresRealOS) func testRepeatingHotkey() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.requiresRealOS) func testHotkeyStates() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testHotkeyActiveGauge() {
            withModuleLoaded(luaopen_hs_libhotkey) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    hk = mod._new({}, 12, function() end)
                    hk:enable()
                    hk:enable()
                    hk:disable()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.hotkey.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
