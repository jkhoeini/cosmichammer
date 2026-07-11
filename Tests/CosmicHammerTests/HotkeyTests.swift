import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Hotkey {
        init() throws { try loadLuaModule("test_hotkey") }

        @Test func testAssignable() { runLuaTest() }
        @Test func testGetHotkeys() { runLuaTest() }
        @Test(.requiresRealOS) func testGetSystemAssigned() { runLuaTest() }

        @Test(.requiresRealOS) func testBasicHotkey() {
            runTwoPartLuaTest(timeout: 2)
        }

        @Test(.requiresRealOS) func testRepeatingHotkey() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test(.requiresRealOS) func testHotkeyStates() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testHotkeyActiveGauge() {
            withModuleLoaded(luaopen_hs_libhotkey) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    hk = mod._new({}, 12, function() end)
                    hk:enable()
                    hk:enable()
                    hk:disable()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.hotkey.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
        @Test func testHotkeyReregistersAfterReload() {
            globalEnvLock.lock()
            defer { globalEnvLock.unlock() }

            let savedState = lua_getCurrentState()
            let savedEnvironment = environmentGetGlobalOrNil()
            let harness = SimulatorHarness(seed: 43)

            defer {
                if lua_getCurrentState() != savedState {
                    MJLuaDealloc()
                }
                lua_setCurrentState(savedState)
                if let savedEnvironment {
                    environmentSetGlobal(savedEnvironment)
                } else {
                    environmentClearGlobal()
                }
            }

            func makeState() -> UnsafeMutablePointer<lua_State> {
                let L = luaL_newstate()!
                luaL_openlibs(L)
                let environment = harness.createEnvironment()
                environmentAttach(L, environment)
                environmentSetGlobal(environment)
                lua_setCurrentState(L)
                lua_bumpStateGeneration()
                _ = luaopen_hs_libhotkey(L)
                lua_setglobal(L, "mod")
                return L
            }

            let firstState = makeState()
            #expect(luaEval(firstState, """
                hotkey = mod._new({"cmd"}, 12, function() end)
                assert(hotkey:enable() ~= nil)
            """))

            MJLuaDealloc()

            let reloadedState = makeState()
            #expect(luaEval(reloadedState, """
                reloadPressed = 0
                hotkey = mod._new({"cmd"}, 12, function() reloadPressed = reloadPressed + 1 end)
                reloadEnabled = hotkey:enable() ~= nil
            """))
            lua_getglobal(reloadedState, "reloadEnabled")
            let reloadEnabled = lua_toboolean(reloadedState, -1) != 0
            lua_pop(reloadedState, 1)

            #expect(reloadEnabled, "Reloaded config must be able to register the same hotkey")

            let input = environmentGet(reloadedState).input
            let keyDown = input.createKeyboardEvent(keyCode: 12, keyDown: true, flags: 0x100000)
            #expect(input.postEvent(keyDown, tapLocation: 0))
            lua_getglobal(reloadedState, "reloadPressed")
            let reloadPressed = lua_tointeger(reloadedState, -1)
            lua_pop(reloadedState, 1)
            #expect(reloadPressed == 1, "Reloaded hotkey callback must receive matching key events")
        }

    }
}
