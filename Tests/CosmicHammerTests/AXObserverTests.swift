import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class AXObserverTests {
        @Test func testAXObserverWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libaxuielementobserver) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustAXObserverWatcherCount(1, L: L)
                adjustAXObserverWatcherCount(1, L: L)
                adjustAXObserverWatcherCount(-1, L: L)
                adjustAXObserverWatcherCount(-1, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.axuielement.observer.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 4)
                #expect(gaugeValues[1] == gaugeValues[0] + 1)
                #expect(gaugeValues[2] == gaugeValues[1] - 1)
                #expect(gaugeValues[3] == gaugeValues[2] - 1)
            }
        }
    }
}
