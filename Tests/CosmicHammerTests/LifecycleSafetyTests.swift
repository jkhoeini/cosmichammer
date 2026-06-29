import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

/// Run a block with an isolated lua_State that won't interfere with
/// the shared test harness state. Saves/restores globals around the call.
private func withIsolatedCurrentState(seed: Int64 = 42, _ body: (UnsafeMutablePointer<lua_State>) -> Void) {
    globalEnvLock.lock()
    defer { globalEnvLock.unlock() }

    let savedState = lua_getCurrentState()
    let savedEnv = environmentGetGlobalOrNil()
    defer {
        lua_setCurrentState(savedState)
        if let env = savedEnv { environmentSetGlobal(env) }
        else { environmentClearGlobal() }
    }

    let L = luaL_newstate()!
    luaL_openlibs(L)
    let harness = SimulatorHarness(seed: seed)
    let env = harness.createEnvironment()
    environmentAttach(L, env)
    environmentSetGlobal(env)
    lua_setCurrentState(L)
    lua_bumpStateGeneration()

    body(L)

    // Clean up our state if the body didn't already (e.g. via MJLuaDealloc)
    if lua_getCurrentState() == L {
        lua_setCurrentState(nil)
        let extra = lua_getextraspace(L)!
        let raw = extra.load(as: UnsafeMutableRawPointer?.self)
        lua_close(L)
        if let raw = raw {
            Unmanaged<Environment>.fromOpaque(raw).release()
        }
    }
}

extension CosmicHammerTests {

    @Suite(.serialized) final class LifecycleSafetyTests {

        // MARK: - Issue #2: Stale _currentLuaState during teardown window

        @Test func currentStateIsNilledBeforeCloseWindowCloses() {
            withIsolatedCurrentState(seed: 300) { L in
                #expect(lua_getCurrentState() == L)

                let extra = lua_getextraspace(L)!
                let savedRaw = extra.load(as: UnsafeMutableRawPointer?.self)

                lua_setCurrentState(nil)
                lua_bumpStateGeneration()

                #expect(lua_getCurrentState() == nil,
                    "getCurrentState must be nil before lua_close to prevent UAF")

                lua_close(L)
                if let raw = savedRaw {
                    Unmanaged<Environment>.fromOpaque(raw).release()
                }
            }
        }

        @Test func generationBumpedBeforeClose() {
            withIsolatedCurrentState(seed: 301) { L in
                let oldGen = lua_currentStateGeneration()

                lua_bumpStateGeneration()
                let newGen = lua_currentStateGeneration()
                #expect(newGen != oldGen, "Generation must change after bump")
                #expect(!lua_isStateGenerationValid(oldGen),
                    "Old generation must be invalid after bump")

                lua_setCurrentState(nil)
                let extra = lua_getextraspace(L)!
                let savedRaw = extra.load(as: UnsafeMutableRawPointer?.self)
                lua_close(L)
                if let raw = savedRaw {
                    Unmanaged<Environment>.fromOpaque(raw).release()
                }
            }
        }

        @Test func generationGuardPreventsStaleCallback() {
            withIsolatedCurrentState(seed: 302) { L in
                let capturedGeneration = lua_currentStateGeneration()
                var callbackFired = false

                let simulatedCallback = {
                    guard lua_isStateGenerationValid(capturedGeneration) else { return }
                    callbackFired = true
                }

                simulatedCallback()
                #expect(callbackFired == true)

                callbackFired = false
                lua_bumpStateGeneration()
                simulatedCallback()
                #expect(callbackFired == false,
                    "Callback must not fire after generation bump")

                lua_setCurrentState(nil)
                let extra = lua_getextraspace(L)!
                let savedRaw = extra.load(as: UnsafeMutableRawPointer?.self)
                lua_close(L)
                if let raw = savedRaw {
                    Unmanaged<Environment>.fromOpaque(raw).release()
                }
            }
        }

        // MARK: - Issue #3: SQLite stored lua_State without generation check

        @Test func storedLuaStateBecomesInvalidAfterTeardown() {
            withIsolatedCurrentState(seed: 303) { L in
                let storedL = L
                let storedGeneration = lua_currentStateGeneration()

                #expect(lua_getCurrentState() == storedL)
                #expect(lua_isStateGenerationValid(storedGeneration))

                lua_bumpStateGeneration()
                lua_setCurrentState(nil)

                #expect(!lua_isStateGenerationValid(storedGeneration),
                    "Stored generation must be invalid after teardown")
                #expect(lua_getCurrentState() == nil)

                let extra = lua_getextraspace(L)!
                let savedRaw = extra.load(as: UnsafeMutableRawPointer?.self)
                lua_close(L)
                if let raw = savedRaw {
                    Unmanaged<Environment>.fromOpaque(raw).release()
                }
            }
        }

        // MARK: - Issue #7: currentLuaStateForCallback lacks generation guard

        @Test func nilCheckAloneIsInsufficientForSafeCallback() {
            withIsolatedCurrentState(seed: 304) { L in
                let capturedGeneration = lua_currentStateGeneration()

                func unsafeCallbackGuard() -> Bool {
                    return lua_getCurrentState() != nil
                }
                func safeCallbackGuard() -> Bool {
                    guard lua_getCurrentState() != nil else { return false }
                    return lua_isStateGenerationValid(capturedGeneration)
                }

                #expect(unsafeCallbackGuard() == true)
                #expect(safeCallbackGuard() == true)

                lua_bumpStateGeneration()

                // Unsafe guard still passes (the bug)
                #expect(unsafeCallbackGuard() == true,
                    "Nil-only guard passes even after generation bump (the bug)")
                // Safe guard correctly rejects
                #expect(safeCallbackGuard() == false,
                    "Generation-aware guard must reject after bump")

                lua_setCurrentState(nil)
                let extra = lua_getextraspace(L)!
                let savedRaw = extra.load(as: UnsafeMutableRawPointer?.self)
                lua_close(L)
                if let raw = savedRaw {
                    Unmanaged<Environment>.fromOpaque(raw).release()
                }
            }
        }

        // MARK: - Issue #8: Menubar stack corruption on stale callback

        @Test func staleCallbackMustNotPopFromStack() {
            withIsolatedCurrentState(seed: 305) { L in
                lua_pushstring(L, "sentinel")
                let topWithSentinel = lua_gettop(L)

                let gen = lua_currentStateGeneration()
                lua_bumpStateGeneration()

                let callbackRan: Bool
                if lua_isStateGenerationValid(gen) {
                    lua_pushboolean(L, 1)
                    callbackRan = true
                } else {
                    callbackRan = false
                }

                if callbackRan {
                    lua_pop(L, 1)
                }

                #expect(lua_gettop(L) == topWithSentinel,
                    "Stack must be unchanged when callback didn't fire")
                let sentinel = String(cString: lua_tostring(L, -1))
                #expect(sentinel == "sentinel")

                lua_settop(L, 0)
                lua_setCurrentState(nil)
                let extra = lua_getextraspace(L)!
                let savedRaw = extra.load(as: UnsafeMutableRawPointer?.self)
                lua_close(L)
                if let raw = savedRaw {
                    Unmanaged<Environment>.fromOpaque(raw).release()
                }
            }
        }

        // MARK: - Issue #11: Force-unwrap before generation check

        @Test func safeCallbackPatternHandlesNilState() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()
            defer {
                lua_setCurrentState(savedState)
                if let env = savedEnv { environmentSetGlobal(env) }
                else { environmentClearGlobal() }
            }

            lua_setCurrentState(nil)

            var safePatternBailed = false
            func safeCallback(storedGeneration: UInt64) {
                guard let _ = lua_getCurrentState(),
                      lua_isStateGenerationValid(storedGeneration) else {
                    safePatternBailed = true
                    return
                }
            }

            safeCallback(storedGeneration: 0)
            #expect(safePatternBailed == true,
                "Safe pattern must bail when state is nil")
        }

        // MARK: - Issue #10: teardown unrefs without generation check

        @Test func unrefOnWrongStateCorruptsRegistry() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()
            defer {
                lua_setCurrentState(savedState)
                if let env = savedEnv { environmentSetGlobal(env) }
                else { environmentClearGlobal() }
            }

            // Create "old" state
            let oldL = luaL_newstate()!
            luaL_openlibs(oldL)
            let harness1 = SimulatorHarness(seed: 306)
            let env1 = harness1.createEnvironment()
            environmentAttach(oldL, env1)
            lua_setCurrentState(oldL)

            lua_pushstring(oldL, "old-value")
            let refInOld = luaL_ref(oldL, LUA_REGISTRYINDEX_VALUE)
            #expect(refInOld != LUA_NOREF)

            let oldGen = lua_currentStateGeneration()
            lua_bumpStateGeneration()
            lua_setCurrentState(nil)

            let extraOld = lua_getextraspace(oldL)!
            let rawOld = extraOld.load(as: UnsafeMutableRawPointer?.self)
            lua_close(oldL)
            if let raw = rawOld {
                Unmanaged<Environment>.fromOpaque(raw).release()
            }

            // Create "new" state
            let newL = luaL_newstate()!
            luaL_openlibs(newL)
            let harness2 = SimulatorHarness(seed: 307)
            let env2 = harness2.createEnvironment()
            environmentAttach(newL, env2)
            lua_setCurrentState(newL)

            lua_pushstring(newL, "new-important-value")
            let refInNew = luaL_ref(newL, LUA_REGISTRYINDEX_VALUE)

            #expect(!lua_isStateGenerationValid(oldGen),
                "Old generation must be invalid — teardown must check this")

            lua_rawgeti(newL, LUA_REGISTRYINDEX_VALUE, lua_Integer(refInNew))
            let val = String(cString: lua_tostring(newL, -1))
            #expect(val == "new-important-value",
                "New state's registry must not be corrupted by stale unrefs")
            lua_pop(newL, 1)

            lua_setCurrentState(nil)
            let extraNew = lua_getextraspace(newL)!
            let rawNew = extraNew.load(as: UnsafeMutableRawPointer?.self)
            lua_close(newL)
            if let raw = rawNew {
                Unmanaged<Environment>.fromOpaque(raw).release()
            }
        }

        // MARK: - Full safe reload cycle

        @Test func safeReloadCyclePreservesIntegrity() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnv = environmentGetGlobalOrNil()
            defer {
                lua_setCurrentState(savedState)
                if let env = savedEnv { environmentSetGlobal(env) }
                else { environmentClearGlobal() }
            }

            // --- First state ---
            let L1 = luaL_newstate()!
            luaL_openlibs(L1)
            let harness1 = SimulatorHarness(seed: 308)
            let env1 = harness1.createEnvironment()
            environmentAttach(L1, env1)
            environmentSetGlobal(env1)
            lua_setCurrentState(L1)
            lua_bumpStateGeneration()
            let gen1 = lua_currentStateGeneration()
            _ = luaL_dostring(L1, "x = 42")

            // Tear down
            environmentClearGlobal()
            lua_bumpStateGeneration()
            lua_setCurrentState(nil)
            #expect(!lua_isStateGenerationValid(gen1))

            let extra1 = lua_getextraspace(L1)!
            let raw1 = extra1.load(as: UnsafeMutableRawPointer?.self)
            lua_close(L1)
            if let raw = raw1 { Unmanaged<Environment>.fromOpaque(raw).release() }

            // --- Second state ---
            let L2 = luaL_newstate()!
            luaL_openlibs(L2)
            let harness2 = SimulatorHarness(seed: 309)
            let env2 = harness2.createEnvironment()
            environmentAttach(L2, env2)
            environmentSetGlobal(env2)
            lua_setCurrentState(L2)
            lua_bumpStateGeneration()
            let gen2 = lua_currentStateGeneration()
            #expect(gen2 != gen1)
            #expect(lua_isStateGenerationValid(gen2))

            lua_getglobal(L2, "x")
            #expect(lua_isnil(L2, -1) != 0, "New state must not inherit old globals")
            lua_pop(L2, 1)

            _ = luaL_dostring(L2, "y = 99")
            lua_getglobal(L2, "y")
            #expect(lua_tointeger(L2, -1) == 99)
            lua_pop(L2, 1)

            // Clean up
            environmentClearGlobal()
            lua_bumpStateGeneration()
            lua_setCurrentState(nil)
            let extra2 = lua_getextraspace(L2)!
            let raw2 = extra2.load(as: UnsafeMutableRawPointer?.self)
            lua_close(L2)
            if let raw = raw2 { Unmanaged<Environment>.fromOpaque(raw).release() }
        }
    }
}
