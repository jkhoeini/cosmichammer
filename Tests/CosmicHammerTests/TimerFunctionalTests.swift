import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class TimerFunctionalTests {
        @Test func testTimerCreation() {
            withModuleLoaded(luaopen_hs_libtimer) { L in
                // Save/restore the global Lua state so pending callbacks from
                // the bootstrapped state survive through this standalone test.
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                // Create a timer with mod.new(interval, fn)
                #expect(luaEval(L, """
                    t = mod.new(1.0, function() end)
                    result = (t ~= nil)
                """))
                lua_getglobal(L, "result")
                #expect(lua_toboolean(L, -1) != 0, "timer creation should return a non-nil object")
            }
        }

        @Test func testTimerStartStop() {
            withModuleLoaded(luaopen_hs_libtimer) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                // Create a timer
                #expect(luaEval(L, """
                    t = mod.new(0.5, function() end)
                """))

                // Should not be running initially
                #expect(luaEval(L, "return t:running()"))
                #expect(lua_toboolean(L, -1) == 0, "timer should not be running initially")
                lua_pop(L, 1)

                // Start it
                #expect(luaEval(L, "t:start()"))

                // Should now be running
                #expect(luaEval(L, "return t:running()"))
                #expect(lua_toboolean(L, -1) != 0, "timer should be running after start")
                lua_pop(L, 1)

                // Stop it
                #expect(luaEval(L, "t:stop()"))

                // Should no longer be running
                #expect(luaEval(L, "return t:running()"))
                #expect(lua_toboolean(L, -1) == 0, "timer should not be running after stop")
            }
        }

        @Test func testTimerActiveGauge() {
            withModuleLoaded(luaopen_hs_libtimer) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    t = mod.new(0.5, function() end)
                    t:start()
                    t:start()
                    t:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.timer.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func testTimerCallbackPropagatesSchedulingSpanContext() throws {
            try withModuleLoaded(luaopen_hs_libtimer) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(
                    enabled: true,
                    callbackSampleRates: ["hs.timer": 1]
                ))
                let parentSpanID = try #require(sim.startSpan(
                    name: "schedule.timer",
                    kind: .internalSpan,
                    attributes: [:],
                    startTime: nil
                ))

                #expect(luaEval(L, """
                    fired = false
                    t = mod.doAfter(1.0, function()
                        fired = true
                    end)
                """))
                sim.endSpan(id: parentSpanID, status: .ok, attributes: [:], endTime: nil)

                let clock = env.clock as! SimulatedClock
                clock.advance(by: 1.0)

                #expect(luaEval(L, "return fired"))
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                let callbackSpan = sim.spans.first {
                    $0.name == "lua.callback" && $0.attributes["cosmichammer.lua.callback.name"] == "hs.timer"
                }
                #expect(callbackSpan?.parentSpanID == parentSpanID)
                #expect(callbackSpan?.ended == true)
            }
        }
    }
}
