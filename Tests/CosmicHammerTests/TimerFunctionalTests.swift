import Testing
import Foundation
import CLua
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
    }
}
