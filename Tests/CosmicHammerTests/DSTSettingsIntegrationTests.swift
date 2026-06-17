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

    // MARK: - Observer protocol tests

    @Test func testObserverFiresOnSet() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            var fired: [String] = []

            let id = settings.addObserver(forKey: "testKey") { key in
                fired.append(key)
            }

            settings.set("hello", forKey: "testKey")
            #expect(fired == ["testKey"])

            settings.set("world", forKey: "testKey")
            #expect(fired == ["testKey", "testKey"])

            settings.removeObserver(id: id)
            settings.set("gone", forKey: "testKey")
            #expect(fired.count == 2, "Observer should not fire after removal")
        }
    }

    @Test func testObserverFiresOnRemoveObject() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            var fired = false

            settings.set("value", forKey: "removeMe")
            let id = settings.addObserver(forKey: "removeMe") { _ in
                fired = true
            }

            settings.removeObject(forKey: "removeMe")
            #expect(fired == true)

            settings.removeObserver(id: id)
        }
    }

    @Test func testObserverOnlyFiresForMatchingKey() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            var firedKeys: [String] = []

            let id = settings.addObserver(forKey: "keyA") { key in
                firedKeys.append(key)
            }

            settings.set("x", forKey: "keyB")
            #expect(firedKeys.isEmpty, "Observer for keyA should not fire when keyB changes")

            settings.set("y", forKey: "keyA")
            #expect(firedKeys == ["keyA"])

            settings.removeObserver(id: id)
        }
    }

    @Test func testMultipleObserversSameKey() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            var countA = 0
            var countB = 0

            let idA = settings.addObserver(forKey: "shared") { _ in countA += 1 }
            let idB = settings.addObserver(forKey: "shared") { _ in countB += 1 }

            settings.set(42, forKey: "shared")
            #expect(countA == 1)
            #expect(countB == 1)

            settings.removeObserver(id: idA)
            settings.set(99, forKey: "shared")
            #expect(countA == 1, "Removed observer A should not fire")
            #expect(countB == 2)

            settings.removeObserver(id: idB)
        }
    }

    @Test func testSetNilFiresObserver() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings
            var fired = false

            settings.set("initial", forKey: "nilTest")
            let id = settings.addObserver(forKey: "nilTest") { _ in
                fired = true
            }

            settings.set(nil, forKey: "nilTest")
            #expect(fired == true, "Setting nil should fire observer")

            settings.removeObserver(id: id)
        }
    }

    @Test func testObserverIDsAreUnique() {
        withLuaState { L in
            let settings = environmentGet(L).settings as! SimulatedSettings

            let id1 = settings.addObserver(forKey: "a") { _ in }
            let id2 = settings.addObserver(forKey: "b") { _ in }
            let id3 = settings.addObserver(forKey: "a") { _ in }

            #expect(id1 != id2)
            #expect(id2 != id3)
            #expect(id1 != id3)

            settings.removeObserver(id: id1)
            settings.removeObserver(id: id2)
            settings.removeObserver(id: id3)
        }
    }
}
