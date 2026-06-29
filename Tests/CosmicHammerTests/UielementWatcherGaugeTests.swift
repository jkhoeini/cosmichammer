import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libuielementwatcher")
private func luaopen_hs_libuielementwatcher_for_gauge(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class UielementWatcherGaugeTests {
        @Test func testUielementWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libuielementwatcher_for_gauge) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustUielementWatcherCount(-1000, L: L)
                adjustUielementWatcherCount(1, L: L)
                adjustUielementWatcherCount(1, L: L)
                adjustUielementWatcherCount(-1, L: L)
                adjustUielementWatcherCount(-1000, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.uielement.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues == [0, 1, 2, 1, 0])
            }
        }
    }
}
