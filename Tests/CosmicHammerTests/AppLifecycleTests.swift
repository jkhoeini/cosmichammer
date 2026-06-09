import Cocoa
import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class AppLifecycleTests {
        @Test func defaultRegistrationDocumentsStartupDefaults() {
            let suiteName = "cosmic-hammer-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            AppLifecycle.registerDefaultDefaults(defaults)

            #expect(defaults.bool(forKey: "MJShowMenuIconKey") == true)
            #expect(defaults.bool(forKey: "MJShowDockIconKey") == false)
            #expect(defaults.bool(forKey: "HSAutoLoadExtensions") == true)
            #expect(defaults.bool(forKey: "HSOpenConsoleOnDockClickKey") == true)
        }

        @Test func storedConfigFileIsAppliedBeforeDirectoryDerivation() throws {
            let suiteName = "cosmic-hammer-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let previousConfig = MJConfigFileGet()
            defer {
                MJConfigFileSet(previousConfig)
                defaults.removePersistentDomain(forName: suiteName)
            }

            defaults.set("/tmp/cosmic-custom/init.lua", forKey: "MJConfigFile")
            AppLifecycle.applyStoredConfigFile(defaults)

            #expect(MJConfigFileFullPath() as String == "/tmp/cosmic-custom/init.lua")
            #expect(AppLifecycle.currentDirectories().configDir == "/tmp/cosmic-custom")
        }

        @Test func prepareConfigDirectoriesThrowsWhenConfigPathIsBlockedByFile() throws {
            let root = try temporaryDirectory()
            let blocker = root.appendingPathComponent("blocked-config")
            FileManager.default.createFile(atPath: blocker.path, contents: Data(), attributes: nil)

            let previousConfig = MJConfigFileGet()
            defer {
                MJConfigFileSet(previousConfig)
                try? FileManager.default.removeItem(at: root)
            }

            MJConfigFileSet(blocker.appendingPathComponent("init.lua").path as NSString)

            #expect(throws: Error.self) {
                try AppLifecycle.prepareConfigDirectories()
            }
        }

        @Test func menuIconVisibleTrueReusesExistingStatusItem() {
            let hadValue = UserDefaults.standard.object(forKey: "MJShowMenuIconKey") != nil
            let oldValue = UserDefaults.standard.bool(forKey: "MJShowMenuIconKey")
            defer {
                MJMenuIconResetForTesting()
                if hadValue {
                    UserDefaults.standard.set(oldValue, forKey: "MJShowMenuIconKey")
                } else {
                    UserDefaults.standard.removeObject(forKey: "MJShowMenuIconKey")
                }
            }

            MJMenuIconResetForTesting()
            UserDefaults.standard.set(true, forKey: "MJShowMenuIconKey")
            MJMenuIconSetup(NSMenu(title: "Test Menu"))

            let first = MJMenuIconStatusItemIdentityForTesting()
            #expect(first != nil)

            MJMenuIconSetVisible(true)
            #expect(MJMenuIconStatusItemIdentityForTesting() == first)

            MJMenuIconSetVisible(false)
            #expect(MJMenuIconStatusItemIdentityForTesting() == nil)
        }

        @Test func dockAndAccessibilityCallbacksIgnoreMissingLuaState() {
            let previousState = lua_getCurrentState()
            lua_setCurrentState(nil)
            defer { lua_setCurrentState(previousState) }

            callAccessibilityStateCallback()
            textDroppedToDockIcon("text" as NSString)
            fileDroppedToDockIcon("/tmp/file" as NSString)
            callDockIconCallback()
        }

        @Test func consoleEntryPointsIgnoreMissingLuaState() {
            let previousState = lua_getCurrentState()
            lua_setCurrentState(nil)
            defer { lua_setCurrentState(previousState) }

            #expect(MJLuaRunString("return 1") as String == "")
            #expect(MJLuaCompletionsForWord("").count == 0)
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cosmic-hammer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
