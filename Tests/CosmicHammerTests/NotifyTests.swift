import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Notify {
        @Test func testNotifyUserdataActiveGauge() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, "n = mod._new('notify-active-gauge-test')"))
                lua_getglobal(L, "n")
                try #expect(nt_userdata_gc(L) == 0)
                lua_pop(L, 1)
                lua_pushnil(L)
                lua_setglobal(L, "n")

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.notify.userdata.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
