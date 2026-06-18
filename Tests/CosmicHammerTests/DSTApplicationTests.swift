import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

// MARK: - Pure Swift simulator tests

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class DSTApplication {

        // MARK: - Application lookup

        @Test func testFrontmostApplication() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            // No apps initially
            #expect(sim.frontmostApplication() == nil)

            // Add an app and make it frontmost
            sim.addApp(ApplicationInfo(pid: 100, bundleID: "com.test.App", name: "TestApp",
                                       path: "/Applications/TestApp.app",
                                       isFrontmost: true, isRunning: true, kind: 1))

            let front = sim.frontmostApplication()
            #expect(front != nil)
            #expect(front?.pid == 100)
            #expect(front?.name == "TestApp")
            #expect(front?.bundleID == "com.test.App")
            #expect(front?.isFrontmost == true)
        }

        @Test func testApplicationForPID() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            #expect(sim.applicationForPID(1) == nil)

            sim.addApp(ApplicationInfo(pid: 42, bundleID: "com.test.App", name: "TestApp",
                                       isRunning: true))

            let app = sim.applicationForPID(42)
            #expect(app != nil)
            #expect(app?.pid == 42)
            #expect(app?.bundleID == "com.test.App")

            #expect(sim.applicationForPID(99) == nil)
        }

        @Test func testApplicationsForBundleID() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, bundleID: "com.test.App", name: "App1"))
            sim.addApp(ApplicationInfo(pid: 101, bundleID: "com.test.App", name: "App2"))
            sim.addApp(ApplicationInfo(pid: 102, bundleID: "com.other.App", name: "Other"))

            let apps = sim.applicationsForBundleID("com.test.App")
            #expect(apps.count == 2)
            #expect(apps.allSatisfy { $0.bundleID == "com.test.App" })
        }

        @Test func testRunningApplications() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            #expect(sim.runningApplications().isEmpty)

            sim.addApp(ApplicationInfo(pid: 100, name: "App1"))
            sim.addApp(ApplicationInfo(pid: 101, name: "App2"))

            let apps = sim.runningApplications()
            #expect(apps.count == 2)
        }

        // MARK: - Bundle info

        @Test func testBundleInfo() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.registerBundle(bundleID: "com.apple.Safari", name: "Safari",
                               path: "/Applications/Safari.app",
                               info: ["CFBundleExecutable": "Safari"],
                               localizations: ["en", "fr", "de"],
                               preferredLocalizations: ["en"])

            #expect(sim.nameForBundleID("com.apple.Safari") == "Safari")
            #expect(sim.pathForBundleID("com.apple.Safari") == "/Applications/Safari.app")

            let info = sim.infoForBundleID("com.apple.Safari")
            #expect(info?["CFBundleExecutable"] as? String == "Safari")

            let pathInfo = sim.infoForBundlePath("/Applications/Safari.app")
            #expect(pathInfo != nil)

            #expect(sim.localizationsForBundleID("com.apple.Safari") == ["en", "fr", "de"])
            #expect(sim.preferredLocalizationsForBundleID("com.apple.Safari") == ["en"])

            #expect(sim.nameForBundleID("com.nonexistent") == nil)
            #expect(sim.infoForBundleID("some.nonsense") == nil)
            #expect(sim.infoForBundlePath("/C/Windows/System32/lol.exe") == nil)
        }

        // MARK: - UTI

        @Test func testDefaultAppForUTI() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.utiHandlers["public.jpeg"] = "com.apple.Preview"

            #expect(sim.defaultAppForUTI("public.jpeg") == "com.apple.Preview")
            #expect(sim.defaultAppForUTI("public.unknown") == nil)
        }

        // MARK: - App lifecycle

        @Test func testLaunchAndKill() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            // Register bundle so launch by name finds it
            sim.registerBundle(bundleID: "com.test.App", name: "TestApp",
                               path: "/Applications/TestApp.app")

            // Launch
            #expect(sim.launchOrFocus("TestApp") == true)
            #expect(sim.launchedApps.count == 1)

            // Find the launched app
            let apps = sim.runningApplications()
            #expect(apps.count == 1)
            let app = apps[0]
            #expect(app.name == "TestApp")
            #expect(app.isRunning == true)

            // Kill it
            sim.kill(pid: app.pid)
            #expect(sim.isRunning(pid: app.pid) == false)
            #expect(sim.killedPIDs.contains(app.pid))
        }

        @Test func testForceKill() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, name: "App", isRunning: true))

            sim.kill9(pid: 100)
            #expect(sim.isRunning(pid: 100) == false)
            #expect(sim.forceKilledPIDs.contains(100))
        }

        @Test func testHideUnhide() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, name: "App", isHidden: false, isRunning: true))

            #expect(sim.isHidden(pid: 100) == false)

            #expect(sim.hide(pid: 100) == true)
            #expect(sim.isHidden(pid: 100) == true)
            #expect(sim.hiddenPIDs.contains(100))

            #expect(sim.unhide(pid: 100) == true)
            #expect(sim.isHidden(pid: 100) == false)
            #expect(sim.unhiddenPIDs.contains(100))
        }

        @Test func testActivateAndFrontmost() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, name: "App1", isRunning: true))
            sim.addApp(ApplicationInfo(pid: 101, name: "App2", isRunning: true))

            #expect(sim.activate(pid: 100, allWindows: false) == true)
            #expect(sim.isFrontmost(pid: 100) == true)
            #expect(sim.isFrontmost(pid: 101) == false)

            #expect(sim.activate(pid: 101, allWindows: true) == true)
            #expect(sim.isFrontmost(pid: 101) == true)
            #expect(sim.isFrontmost(pid: 100) == false)
        }

        @Test func testLaunchOrFocusByBundleID() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.registerBundle(bundleID: "com.test.App", name: "TestApp",
                               path: "/Applications/TestApp.app")

            #expect(sim.launchOrFocusByBundleID("com.test.App") == true)
            #expect(sim.launchedApps.count == 1)

            // Second call should focus, not launch a new instance
            #expect(sim.launchOrFocusByBundleID("com.test.App") == true)
            #expect(sim.launchedApps.count == 2)
            #expect(sim.runningApplications().count == 1) // Still just one running
        }

        // MARK: - Menus

        @Test func testMenuQueries() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, bundleID: "com.test.App", name: "TestApp",
                                       isFrontmost: true, isRunning: true))

            // Set up menus
            sim.setMenus(forPID: 100, [
                AppMenuItemInfo(title: "TestApp", role: "AXMenuBarItem", children: [
                    AppMenuItemInfo(title: "About TestApp"),
                    AppMenuItemInfo(title: "Quit TestApp", cmdChar: "q", cmdModifiers: ["cmd"]),
                ]),
                AppMenuItemInfo(title: "Edit", role: "AXMenuBarItem", children: [
                    AppMenuItemInfo(title: "Cut", cmdChar: "x", cmdModifiers: ["cmd"]),
                    AppMenuItemInfo(title: "Copy", cmdChar: "c", cmdModifiers: ["cmd"]),
                    AppMenuItemInfo(title: "Select All", cmdChar: "a", cmdModifiers: ["cmd"]),
                ]),
            ])

            // getMenuItems
            let menus = sim.getMenuItems(pid: 100)
            #expect(menus != nil)
            #expect(menus!.count == 2)
            #expect(menus![0]["AXTitle"] as? String == "TestApp")

            // findMenuItemByPath
            let cutItem = sim.findMenuItemByPath(pid: 100, path: ["Edit", "Cut"])
            #expect(cutItem != nil)
            #expect(cutItem?.enabled == true)

            // findMenuItemByName
            let copyItem = sim.findMenuItemByName(pid: 100, name: "Copy", isRegex: false)
            #expect(copyItem != nil)

            // Non-existent path
            #expect(sim.findMenuItemByPath(pid: 100, path: ["Foo", "Bar"]) == nil)
            #expect(sim.findMenuItemByName(pid: 100, name: "Foo", isRegex: false) == nil)

            // selectMenuItem
            #expect(sim.selectMenuItemByPath(pid: 100, path: ["Edit", "Select All"]) == true)
            #expect(sim.selectedMenuItems.count == 1)

            #expect(sim.selectMenuItemByName(pid: 100, name: "Select All", isRegex: false) == true)
            #expect(sim.selectedMenuItems.count == 2)

            // Non-existent select
            #expect(sim.selectMenuItemByPath(pid: 100, path: ["Edit", "No Such Menu Item"]) == false)
            #expect(sim.selectMenuItemByName(pid: 100, name: "Some Nonsense", isRegex: false) == false)
        }

        @Test func testMenusOnDock() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            // Dock has no menus
            sim.addApp(ApplicationInfo(pid: 50, name: "Dock", isRunning: true, kind: 0))
            #expect(sim.getMenuItems(pid: 50) == nil)
        }

        // MARK: - Windows

        @Test func testAppWindows() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, name: "TestApp", isRunning: true))

            // No windows initially
            #expect(sim.allWindows(pid: 100).isEmpty)
            #expect(sim.mainWindow(pid: 100) == nil)
            #expect(sim.focusedWindow(pid: 100) == nil)

            // Add a window
            sim.addWindow(forPID: 100, AXWindowInfo(id: 1, title: "Document",
                                                     frame: (100, 100, 800, 600), pid: 100))

            let wins = sim.allWindows(pid: 100)
            #expect(wins.count == 1)
            #expect(wins[0].title == "Document")

            let main = sim.mainWindow(pid: 100)
            #expect(main?.id == 1)

            let focused = sim.focusedWindow(pid: 100)
            #expect(focused?.id == 1)
        }

        // MARK: - Basic attributes

        @Test func testBasicAttributes() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, bundleID: "com.test.App", name: "TestApp",
                                       path: "/Applications/TestApp.app",
                                       isHidden: false, isFrontmost: true,
                                       isRunning: true, kind: 1, isResponsive: true))

            #expect(sim.title(pid: 100) == "TestApp")
            #expect(sim.bundleID(pid: 100) == "com.test.App")
            #expect(sim.path(pid: 100) == "/Applications/TestApp.app")
            #expect(sim.kind(pid: 100) == 1)
            #expect(sim.isResponsive(pid: 100) == true)
            #expect(sim.isRunning(pid: 100) == true)
        }

        // MARK: - Lua integration tests

        @Test func testAttributesFromBundleIDViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                // Set up simulated state matching what testAttributesFromBundleID expects
                sim.registerBundle(bundleID: "com.apple.Safari", name: "Safari",
                                   path: "/Applications/Safari.app",
                                   info: ["CFBundleExecutable": "Safari"])
                sim.addApp(ApplicationInfo(pid: 200, bundleID: "com.apple.Safari",
                                           name: "Safari", path: "/Applications/Safari.app",
                                           isRunning: true))

                // Load the application module
                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                // Test nameForBundleID
                #expect(luaEvalString(L, "return hsapp.nameForBundleID('com.apple.Safari')") == "Safari")

                // Test pathForBundleID
                #expect(luaEvalString(L, "return hsapp.pathForBundleID('com.apple.Safari')") == "/Applications/Safari.app")

                // Test infoForBundleID
                #expect(luaEvalBool(L, """
                    local info = hsapp.infoForBundleID('com.apple.Safari')
                    return info ~= nil and info['CFBundleExecutable'] == 'Safari'
                """) == true)

                // Test nil for nonexistent
                #expect(luaEvalBool(L, "return hsapp.infoForBundleID('some.nonsense') == nil") == true)
                #expect(luaEvalBool(L, "return hsapp.infoForBundlePath('/C/Windows/System32/lol.exe') == nil") == true)
            }
        }

        @Test func testBasicAttributesViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 42, bundleID: "org.cosmic-hammer.CosmicHammer",
                                           name: "Cosmic Hammer", path: "/Applications/Cosmic Hammer.app",
                                           isRunning: true, kind: 1, isResponsive: true))

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                // Test applicationForPID nil for invalid PID
                #expect(luaEvalBool(L, "return hsapp.applicationForPID(1) == nil") == true)

                // Test applicationForPID for valid PID
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app ~= nil
                """) == true)

                // Test bundleID
                #expect(luaEvalString(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:bundleID()
                """) == "org.cosmic-hammer.CosmicHammer")

                // Test name/title
                #expect(luaEvalString(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:name()
                """) == "Cosmic Hammer")

                // Test pid
                #expect(luaEvalInt(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:pid()
                """) == 42)

                // Test isUnresponsive (should be false for a responsive app)
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:isUnresponsive()
                """) == false)
            }
        }

        @Test func testMenusViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 42, bundleID: "org.cosmic-hammer.CosmicHammer",
                                           name: "Cosmic Hammer", isFrontmost: true,
                                           isRunning: true))

                sim.setMenus(forPID: 42, [
                    AppMenuItemInfo(title: "Cosmic Hammer", role: "AXMenuBarItem", children: [
                        AppMenuItemInfo(title: "About Cosmic Hammer"),
                    ]),
                    AppMenuItemInfo(title: "Edit", role: "AXMenuBarItem", children: [
                        AppMenuItemInfo(title: "Cut", cmdChar: "x"),
                        AppMenuItemInfo(title: "Select All", cmdChar: "a"),
                    ]),
                ])

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                // getMenuItems returns table
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    local menus = app:getMenuItems()
                    return type(menus) == 'table' and menus[1]['AXTitle'] == 'Cosmic Hammer'
                """) == true)

                // findMenuItem by path
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    local item = app:findMenuItem({'Edit', 'Cut'})
                    return type(item) == 'table' and type(item['enabled']) == 'boolean'
                """) == true)

                // findMenuItem by name
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    local item = app:findMenuItem('Cut')
                    return type(item) == 'table'
                """) == true)

                // findMenuItem returns nil for nonexistent
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:findMenuItem({'Foo', 'Bar'}) == nil
                """) == true)

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:findMenuItem('Foo') == nil
                """) == true)

                // selectMenuItem
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:selectMenuItem({'Edit', 'Select All'}) == true
                """) == true)

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:selectMenuItem('Select All') == true
                """) == true)

                // selectMenuItem nil for nonexistent
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:selectMenuItem({'Edit', 'No Such Menu Item'}) == nil
                """) == true)

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(42)
                    return app:selectMenuItem('Some Nonsense') == nil
                """) == true)
            }
        }

        @Test func testMenusOnDockViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 50, name: "Dock", isRunning: true, kind: 0))
                // Dock has no menus set

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(50)
                    local menus = app:getMenuItems()
                    return menus == nil
                """) == true)
            }
        }

        @Test func testHidingViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 100, name: "Stickies",
                                           isHidden: false, isRunning: true))

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                // Not hidden initially
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:isHidden()
                """) == false)

                // Hide
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:hide()
                """) == true)

                // Check hidden
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:isHidden()
                """) == true)

                // Unhide
                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:unhide()
                """) == true)

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:isHidden()
                """) == false)
            }
        }

        @Test func testKillingViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 100, name: "Audio MIDI Setup", isRunning: true))

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:isRunning()
                """) == true)

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    app:kill()
                    return app:isRunning()
                """) == false)
            }
        }

        @Test func testForceKillingViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 100, name: "Calculator", isRunning: true))

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    return app:isRunning()
                """) == true)

                #expect(luaEvalBool(L, """
                    local app = hsapp.applicationForPID(100)
                    app:kill9()
                    return app:isRunning()
                """) == false)
            }
        }

        @Test func testRunningApplicationsViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.addApp(ApplicationInfo(pid: 100, name: "App1", isRunning: true))
                sim.addApp(ApplicationInfo(pid: 101, name: "App2", isRunning: true))

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                #expect(luaEvalBool(L, """
                    local apps = hsapp.runningApplications()
                    return type(apps) == 'table' and #apps >= 2
                """) == true)
            }
        }

        @Test func testUTIViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.utiHandlers["public.jpeg"] = "com.apple.Preview"

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                #expect(luaEvalString(L, "return hsapp.defaultAppForUTI('public.jpeg')") == "com.apple.Preview")
            }
        }

        @Test func testLocalizationFunctionsViaLua() {
            withLuaState { L in
                let sim = environmentGet(L).application as! SimulatedApplication

                sim.registerBundle(bundleID: "com.apple.Safari", name: "Safari",
                                   path: "/Applications/Safari.app",
                                   localizations: ["en", "fr"],
                                   preferredLocalizations: ["en"])

                let result = luaopen_hs_libapplication_new(L)
                assert(result == 1)
                lua_setglobal(L, "hsapp")

                #expect(luaEvalBool(L, """
                    local locs = hsapp.localizationsForBundleID('com.apple.Safari')
                    return type(locs) == 'table'
                """) == true)

                #expect(luaEvalBool(L, """
                    local locs = hsapp.preferredLocalizationsForBundleID('com.apple.Safari')
                    return type(locs) == 'table'
                """) == true)

                #expect(luaEvalBool(L, """
                    local locs = hsapp.localizationsForBundlePath('/Applications/Safari.app')
                    return type(locs) == 'table'
                """) == true)

                #expect(luaEvalBool(L, """
                    local locs = hsapp.preferredLocalizationsForBundlePath('/Applications/Safari.app')
                    return type(locs) == 'table'
                """) == true)
            }
        }

        // MARK: - Fault injection

        @Test func testAccessibilityPermissionDenied() {
            let faults = FaultConfig.withPermissionDenied(accessibility: true)
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let sim = env.application as! SimulatedApplication

            sim.addApp(ApplicationInfo(pid: 100, name: "TestApp", isRunning: true))
            sim.addWindow(forPID: 100, AXWindowInfo(id: 1, title: "Win", pid: 100))
            sim.setMenus(forPID: 100, [
                AppMenuItemInfo(title: "Edit", role: "AXMenuBarItem", children: [
                    AppMenuItemInfo(title: "Cut"),
                ]),
            ])

            // Windows should be empty with AX denied
            #expect(sim.allWindows(pid: 100).isEmpty)
            #expect(sim.mainWindow(pid: 100) == nil)
            #expect(sim.focusedWindow(pid: 100) == nil)

            // Menus should be nil with AX denied
            #expect(sim.getMenuItems(pid: 100) == nil)
            #expect(sim.findMenuItemByPath(pid: 100, path: ["Edit", "Cut"]) == nil)
            #expect(sim.selectMenuItemByPath(pid: 100, path: ["Edit", "Cut"]) == false)
        }

        @Test func testAppLaunchFailure() {
            var faults = FaultConfig()
            faults.appLaunchFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let sim = env.application as! SimulatedApplication

            #expect(sim.launchOrFocus("TestApp") == false)
            #expect(sim.launchOrFocusByBundleID("com.test.App") == false)
            #expect(sim.runningApplications().isEmpty)
        }

        // MARK: - Determinism

        @Test func testDeterminism() {
            func runScenario() -> [String] {
                let harness = SimulatorHarness(seed: 42)
                let env = harness.createEnvironment()
                let sim = env.application as! SimulatedApplication

                sim.registerBundle(bundleID: "com.test.App", name: "TestApp",
                                   path: "/Applications/TestApp.app")

                _ = sim.launchOrFocus("TestApp")
                let apps = sim.runningApplications()
                _ = sim.frontmostApplication()
                sim.hide(pid: apps[0].pid)
                sim.unhide(pid: apps[0].pid)
                sim.kill(pid: apps[0].pid)

                return [
                    "apps=\(apps.count)",
                    "hidden=\(sim.hiddenPIDs)",
                    "unhidden=\(sim.unhiddenPIDs)",
                    "killed=\(sim.killedPIDs)",
                ]
            }

            let run1 = runScenario()
            let run2 = runScenario()
            #expect(run1 == run2, "Simulator must be deterministic across runs with same seed")
        }
    }
}
