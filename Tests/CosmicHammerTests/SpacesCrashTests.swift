import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class SpacesCrashTests {

        // MARK: - Crash 1: Argument validation (precondition -> luaL_checkinteger)

        /// Before fix: precondition kills the process with SIGTRAP.
        /// After fix: pcall catches the Lua error and returns false.
        @Test func spacesWindowSpacesNoArgReturnsError() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                let ok = luaEvalBool(L, "return (pcall(function() return mod.windowSpaces() end))")
                #expect(ok == false, "windowSpaces() with no args should raise a Lua error, not crash")
            }
        }

        @Test func spacesWindowsForSpaceNoArgReturnsError() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                let ok = luaEvalBool(L, "return (pcall(function() return mod.windowsForSpace() end))")
                #expect(ok == false, "windowsForSpace() with no args should raise a Lua error, not crash")
            }
        }

        @Test func spacesMoveWindowToSpacePartialArgReturnsError() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                let ok = luaEvalBool(L, "return (pcall(function() return mod.moveWindowToSpace(100) end))")
                #expect(ok == false, "moveWindowToSpace(100) with only 1 arg should raise a Lua error")
            }
        }

        @Test func spacesWindowSpacesWrongTypeReturnsError() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                let ok = luaEvalBool(L, "return (pcall(function() return mod.windowSpaces('not-a-number') end))")
                #expect(ok == false, "windowSpaces('not-a-number') should raise a Lua error")
            }
        }

        @Test func spacesWindowsForSpaceWrongTypeReturnsError() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                let ok = luaEvalBool(L, "return (pcall(function() return mod.windowsForSpace('bad') end))")
                #expect(ok == false, "windowsForSpace('bad') should raise a Lua error")
            }
        }

        @Test func spacesMoveWindowToSpaceWrongTypeReturnsError() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                let ok = luaEvalBool(L, "return (pcall(function() return mod.moveWindowToSpace('a', 'b') end))")
                #expect(ok == false, "moveWindowToSpace('a','b') should raise a Lua error")
            }
        }

        @Test func spacesWindowSpacesValidArgDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                // windowSpaces with a valid (but non-existent) window ID should return a table
                let resultType = luaEvalString(L, "return type(mod.windowSpaces(99999))")
                #expect(resultType == "table", "windowSpaces(99999) should return a table (possibly empty)")
            }
        }

        @Test func spacesWindowsForSpaceValidArgDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libspaces) { L in
                // windowsForSpace with a bogus space ID should return nil + error, not crash
                #expect(luaEval(L, """
                    local ok, err = pcall(function() return mod.windowsForSpace(99999) end)
                    -- Either it succeeds (returning nil+error or a table) or pcall catches it
                    result = true
                """))
                lua_getglobal(L, "result")
                #expect(lua_toboolean(L, -1) != 0)
            }
        }

        // MARK: - Crash 2: GC safety (SpacesWatcher teardown)

        @Test func spaceWatcherGCAfterStopDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libspaces_watcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    local w = mod.new(function() end)
                    w:start()
                    w:stop()
                    w = nil
                    collectgarbage()
                    collectgarbage()
                """), "SpaceWatcher GC after stop should not crash")
            }
        }

        @Test func spaceWatcherGCWithoutStartDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libspaces_watcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    local w = mod.new(function() end)
                    w = nil
                    collectgarbage()
                    collectgarbage()
                """), "SpaceWatcher GC without start should not crash")
            }
        }

        @Test func spaceWatcherDoubleStopDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libspaces_watcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    local w = mod.new(function() end)
                    w:start()
                    w:stop()
                    w:stop()
                    w = nil
                    collectgarbage()
                """), "Double stop should be safe")
            }
        }

        @Test func spaceWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libspaces_watcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local w = mod.new(function() end)
                    w:start()
                    w:start()
                    w:stop()
                    w:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.spaces.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
