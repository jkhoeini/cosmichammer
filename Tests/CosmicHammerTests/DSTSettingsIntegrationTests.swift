import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@Suite("DST Settings Integration", .serialized)
struct DSTSettingsIntegrationTests {

    @Test func testDockIconVisibleViaSimulator() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            settings.set(true, forKey: "MJShowDockIconKey")
            #expect(MJDockIconVisible() == true)
            settings.set(false, forKey: "MJShowDockIconKey")
            #expect(MJDockIconVisible() == false)
        }
    }

    @Test func testDockIconConsoleClickViaSimulator() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            settings.set(true, forKey: "HSOpenConsoleOnDockClickKey")
            #expect(HSOpenConsoleOnDockClickEnabled() == true)
            settings.set(false, forKey: "HSOpenConsoleOnDockClickKey")
            #expect(HSOpenConsoleOnDockClickEnabled() == false)
        }
    }

    @Test func testMenuIconVisibleViaSimulator() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            settings.set(true, forKey: "MJShowMenuIconKey")
            #expect(MJMenuIconVisible() == true)
            settings.set(false, forKey: "MJShowMenuIconKey")
            #expect(MJMenuIconVisible() == false)
        }
    }

    @Test func testConsoleDarkModeViaSimulator() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            settings.set(true, forKey: "HSConsoleDarkModeKey")
            #expect(ConsoleDarkModeEnabled() == true)
            settings.set(false, forKey: "HSConsoleDarkModeKey")
            #expect(ConsoleDarkModeEnabled() == false)
        }
    }

    @Test func testConsoleAlwaysOnTopViaSimulator() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            settings.set(true, forKey: "MJKeepConsoleOnTopKey")
            #expect(MJConsoleWindowAlwaysOnTop() == true)
            settings.set(false, forKey: "MJKeepConsoleOnTopKey")
            #expect(MJConsoleWindowAlwaysOnTop() == false)
        }
    }

    @Test func testAppleScriptEnabledViaSimulator() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            settings.set(true, forKey: "HSAppleScriptEnabledKey")
            #expect(HSAppleScriptEnabled() == true)
            settings.set(false, forKey: "HSAppleScriptEnabledKey")
            #expect(HSAppleScriptEnabled() == false)
        }
    }

    @Test func testFallbackToUserDefaultsWhenNoGlobalEnv() {
        // When no global environment is set, @_cdecl functions should
        // fall back to UserDefaults without crashing.
        // Acquire the global env lock to ensure no other test's withLuaState
        // interferes with the global environment during this test.
        globalEnvLock.lock()
        defer { globalEnvLock.unlock() }

        // Explicitly clear the global env in case a prior test (e.g. bootstrapLuaForTesting)
        // left it set. This makes the test resilient to non-deterministic ordering.
        environmentClearGlobal()

        // Verify the global env is nil (no withLuaState active)
        #expect(environmentGetGlobalOrNil() == nil)

        // Call the @_cdecl function -- it must not crash when no global env is set.
        // The return value depends on whatever is in UserDefaults, which we don't
        // control; the key assertion is that it doesn't crash.
        _ = HSOpenConsoleOnDockClickEnabled()
        _ = MJDockIconVisible()
        _ = MJMenuIconVisible()
        _ = ConsoleDarkModeEnabled()
        _ = MJConsoleWindowAlwaysOnTop()
        _ = HSAppleScriptEnabled()
    }

    @Test func testSettingsSetterViaSimulator() {
        // Test setters that do NOT trigger AppKit UI operations
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings

            // HSOpenConsoleOnDockClickSetEnabled has no UI side effects
            HSOpenConsoleOnDockClickSetEnabled(true)
            #expect(settings.bool(forKey: "HSOpenConsoleOnDockClickKey") == true)
            HSOpenConsoleOnDockClickSetEnabled(false)
            #expect(settings.bool(forKey: "HSOpenConsoleOnDockClickKey") == false)

            // ConsoleDarkModeSetEnabled has no UI side effects
            ConsoleDarkModeSetEnabled(true)
            #expect(settings.bool(forKey: "HSConsoleDarkModeKey") == true)
            ConsoleDarkModeSetEnabled(false)
            #expect(settings.bool(forKey: "HSConsoleDarkModeKey") == false)

            // HSAppleScriptSetEnabled has no UI side effects
            HSAppleScriptSetEnabled(true)
            #expect(settings.bool(forKey: "HSAppleScriptEnabledKey") == true)
            HSAppleScriptSetEnabled(false)
            #expect(settings.bool(forKey: "HSAppleScriptEnabledKey") == false)
        }
    }
}
