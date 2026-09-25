import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ScreenWatcher {
        @Test func testScreenWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libscreenwatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    watcher = mod.new(function() end)
                    activeWatcher = mod.newWithActiveScreen(function() end)
                    watcher:start()
                    watcher:start()
                    activeWatcher:start()
                    activeWatcher:start()
                    watcher:stop()
                    watcher:stop()
                    activeWatcher:stop()
                    activeWatcher:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.screen.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 4)
                let deltas = zip(gaugeValues, gaugeValues.dropFirst()).map { $0.1 - $0.0 }
                #expect(deltas == [1, -1, -1])
            }
        }

        @Test func displayEventWatcherDeliversPublicKindsAndStops() {
            withModuleLoaded(luaopen_hs_libscreenwatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let screen = environmentGet(L).screen as! SimulatedScreen
                #expect(luaEval(L, """
                    events = {}
                    watcher = mod.newWithDisplayEvents(function(event, displayID)
                        table.insert(events, event .. ':' .. displayID)
                    end):start()
                    """))

                for kind in [
                    DisplayReconfigurationEvent.Kind.added,
                    .removed, .moved, .resized, .disabled, .enabled,
                ] {
                    screen.simulateDisplayReconfigurationEvent(.init(kind: kind, displayID: 12))
                }
                #expect(luaEvalString(L, "return table.concat(events, ',')") ==
                        "added:12,removed:12,moved:12,resized:12")

                #expect(luaEval(L, "watcher:stop(); watcher:stop()"))
                screen.simulateDisplayReconfigurationEvent(.init(kind: .added, displayID: 13))
                #expect(luaEvalString(L, "return table.concat(events, ',')") ==
                        "added:12,removed:12,moved:12,resized:12")
            }
        }

        @Test func displayEventWatcherPinsUntilStoppedAndAllowsCollectionAfterward() {
            withModuleLoaded(luaopen_hs_libscreenwatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let screen = environmentGet(L).screen as! SimulatedScreen
                #expect(luaEval(L, """
                    count = 0
                    watcher = mod.newWithDisplayEvents(function() count = count + 1 end):start()
                    alias = watcher
                    watcher = nil
                    collectgarbage()
                """))
                screen.simulateDisplayReconfigurationEvent(.init(kind: .added, displayID: 3))
                #expect(luaEvalString(L, "return tostring(count)") == "1")
                #expect(luaEval(L, "alias:stop(); alias = nil; collectgarbage(); collectgarbage()"))
            }
        }
    }
}
