import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("MJLuaDealloc")
private func MJLuaDealloc()

extension CosmicHammerTests {

    @Suite(.serialized) final class EnvironmentDetachTests {

        // MARK: - Production code exerciser

        /// Calls the ACTUAL MJLuaDealloc production code path.
        /// Before the fix, this would segfault (use-after-free on lua_getextraspace
        /// of a freed lua_State). After the fix, it completes without crashing.
        @Test func mjLuaDeallocDoesNotCrash() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            // Save the shared test harness state so we don't destroy it
            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()

            // Set up a SEPARATE state the same way MJLuaAlloc does
            let L = luaL_newstate()!
            luaL_openlibs(L)
            let harness = SimulatorHarness(seed: 99)
            let env = harness.createEnvironment()
            environmentAttach(L, env)
            environmentSetGlobal(env)
            lua_setCurrentState(L)
            lua_bumpStateGeneration()

            // Create objects that will exercise GC during lua_close
            _ = luaL_dostring(L, """
                local t = {}
                for i = 1, 50 do
                    t[i] = setmetatable({}, {__gc = function() end})
                end
                """)

            // Call the actual production teardown — this is what crashed
            MJLuaDealloc()

            // If we get here, the fix works. Verify state is cleaned up.
            #expect(lua_getCurrentState() == nil,
                "Current state must be nil after MJLuaDealloc")

            // Restore shared state for other tests
            lua_setCurrentState(savedState)
            if let env = savedEnv { environmentSetGlobal(env) }
        }

        /// Exercises MJLuaDealloc repeatedly (simulates hs.reload() spam).
        /// The second crash report was heap corruption from accumulated damage
        /// over multiple reload cycles.
        @Test func repeatedMJLuaDeallocCyclesDoNotCorruptHeap() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()

            for i in 0..<10 {
                let L = luaL_newstate()!
                luaL_openlibs(L)
                let harness = SimulatorHarness(seed: Int64(200 + i))
                let env = harness.createEnvironment()
                environmentAttach(L, env)
                environmentSetGlobal(env)
                lua_setCurrentState(L)
                lua_bumpStateGeneration()

                _ = luaL_dostring(L, """
                    local t = {}
                    for j = 1, 30 do
                        t[j] = string.rep('x', j * 10)
                    end
                    """)

                MJLuaDealloc()
            }

            // Heap is healthy if we can still allocate
            let probe = luaL_newstate()!
            #expect(luaL_dostring(probe, "return 1+1") == LUA_OK)
            lua_close(probe)

            // Restore shared state
            lua_setCurrentState(savedState)
            if let env = savedEnv { environmentSetGlobal(env) }
        }

        // MARK: - GC finalizers access environment during lua_close

        /// Verifies that GC finalizers running during MJLuaDealloc's lua_close
        /// can still read the Environment from extra-space (the retained pointer
        /// is not released until after lua_close completes).
        @Test func gcFinalizerCanAccessEnvironmentDuringMJLuaDealloc() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()

            let L = luaL_newstate()!
            luaL_openlibs(L)
            let harness = SimulatorHarness(seed: 102)
            let env = harness.createEnvironment()
            environmentAttach(L, env)
            environmentSetGlobal(env)
            lua_setCurrentState(L)
            lua_bumpStateGeneration()

            // Register a __gc finalizer that reads the environment
            let gcAccessor: lua_CFunction = { L in
                guard let L = L else { return 0 }
                let extra = lua_getextraspace(L)!
                let raw = extra.load(as: UnsafeMutableRawPointer.self)
                if raw != UnsafeMutableRawPointer(bitPattern: 0) {
                    let env = Unmanaged<Environment>.fromOpaque(raw).takeUnretainedValue()
                    _ = env.clock.secondsSinceEpoch()
                }
                return 0
            }

            // Create userdata with our __gc
            lua_newuserdata(L, 1)
            lua_createtable(L, 0, 1)
            lua_pushcfunction(L, gcAccessor)
            lua_setfield(L, -2, "__gc")
            lua_setmetatable(L, -2)
            lua_setglobal(L, "gcprobe")
            _ = luaL_dostring(L, "gcprobe = nil")

            // MJLuaDealloc triggers lua_close -> GC -> our __gc reads env
            MJLuaDealloc()

            // No crash = finalizer safely accessed the environment
            lua_setCurrentState(savedState)
            if let env = savedEnv { environmentSetGlobal(env) }
        }

        // MARK: - Ordering guarantees

        /// After MJLuaDealloc, generation must have been bumped so any stale
        /// callbacks holding the old generation will correctly bail out.
        @Test func mjLuaDeallocBumpsGeneration() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()

            let L = luaL_newstate()!
            luaL_openlibs(L)
            let harness = SimulatorHarness(seed: 103)
            let env = harness.createEnvironment()
            environmentAttach(L, env)
            environmentSetGlobal(env)
            lua_setCurrentState(L)
            lua_bumpStateGeneration()

            let genBefore = lua_currentStateGeneration()

            MJLuaDealloc()

            let genAfter = lua_currentStateGeneration()
            #expect(genAfter != genBefore,
                "Generation must be bumped by MJLuaDealloc")
            #expect(!lua_isStateGenerationValid(genBefore),
                "Old generation must be invalid after dealloc")

            // Restore shared state
            lua_setCurrentState(savedState)
            if let env = savedEnv { environmentSetGlobal(env) }
        }

        /// environmentDetach called on a live state still works correctly.
        @Test func environmentDetachBeforeLuaCloseReleasesEnvironment() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let L = luaL_newstate()!
            luaL_openlibs(L)
            let harness = SimulatorHarness(seed: 100)
            let env = harness.createEnvironment()
            environmentAttach(L, env)

            environmentDetach(L)

            let extra = lua_getextraspace(L)!
            let raw = extra.load(as: Int.self)
            #expect(raw == 0, "Extra space should be zeroed after detach")

            // Double-detach is a no-op
            environmentDetach(L)

            lua_close(L)
        }
    }
}
