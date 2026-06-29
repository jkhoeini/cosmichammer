import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class HostLocale {
        @Test func testHostLocaleObserverActiveGauge() {
            withLuaState { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let result = luaopen_hs_libhost_locale(L)
                #expect(result == 1)
                lua_setglobal(L, "locale")
                #expect(luaEval(L, """
                    locale = nil
                    collectgarbage()
                    collectgarbage()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.host.locale.observer.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
