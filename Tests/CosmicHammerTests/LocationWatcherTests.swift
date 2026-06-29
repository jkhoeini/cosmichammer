import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_liblocation")
private func luaopen_hs_liblocation_for_watcher(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class LocationWatcher {
        @Test func testLocationWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_liblocation_for_watcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                setLocationWatcherCounted(true, L: L)
                setLocationWatcherCounted(true, L: L)
                setLocationWatcherCounted(false, L: L)
                setLocationWatcherCounted(false, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.location.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
