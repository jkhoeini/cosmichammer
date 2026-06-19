import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@MainActor var testHarness: SimulatorHarness?

@_silgen_name("MJLuaAlloc")
func MJLuaAlloc()

@_silgen_name("HSExtensionsRegisterAll")
private func HSExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>?)

private let repoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CosmicHammerTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root
}()

/// Minimal getObjectMetatable for the test environment.
private let test_getObjectMetatable: lua_CFunction = { L in
    luaL_checktype(L, 1, LUA_TSTRING)
    let name = lua_tostring(L, 1)
    luaL_getmetatable(L, name)
    if lua_istable(L, -1) != 0 {
        lua_getfield(L, -1, "__type")
        if lua_isnil(L, -1) != 0, let name = name {
            lua_pop(L, 1)
            lua_pushstring(L, name)
            lua_setfield(L, -2, "__type")
        } else {
            lua_pop(L, 1)
        }
    }
    return 1
}

@MainActor private var luaBootstrapped = false

private func appBundleURL(forResourceRoot resourceRoot: URL) -> URL? {
    guard resourceRoot.lastPathComponent == "Resources" else { return nil }
    let contents = resourceRoot.deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents" else { return nil }
    let bundle = contents.deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}

private func doLuaString(_ L: UnsafeMutablePointer<lua_State>, _ s: String) -> Int32 {
    let load = luaL_loadstring(L, s)
    if load != 0 { return load }
    return lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil)
}

@MainActor
func luaRunString(_ code: String) -> String? {
    bootstrapLuaForTesting()
    globalEnvLock.lock()
    defer {
        environmentClearGlobal()
        globalEnvLock.unlock()
    }
    let L = lua_getCurrentState()!
    let env = environmentGet(L)
    environmentSetGlobal(env)
    let top = lua_gettop(L)

    let firstResult = top + 1
    var result: String?

    func readResult(_ idx: Int32) -> String? {
        switch lua_type(L, idx) {
        case LUA_TSTRING, LUA_TNUMBER:
            var len: Int = 0
            if let s = lua_tolstring(L, idx, &len), len > 0 {
                return String(cString: s)
            }
            return ""
        case LUA_TBOOLEAN:
            return lua_toboolean(L, idx) != 0 ? "true" : "false"
        case LUA_TNIL:
            return nil
        default:
            let s = String(cString: luaL_tolstring(L, idx, nil))
            lua_settop(L, lua_gettop(L) - 1)
            return s
        }
    }

    if doLuaString(L, "return " + code) == LUA_OK {
        if lua_gettop(L) >= firstResult {
            result = readResult(firstResult)
        }
    } else {
        lua_settop(L, top)
        if doLuaString(L, code) == LUA_OK {
            if lua_gettop(L) >= firstResult {
                result = readResult(firstResult)
            }
        } else {
            result = readResult(-1)
        }
    }

    lua_settop(L, top)
    return result
}

@MainActor
func bootstrapLuaForTesting() {
    guard !luaBootstrapped else { return }
    luaBootstrapped = true

    let defaultTestResources = repoRoot.appendingPathComponent("build/test/Cosmic Hammer.app/Contents/Resources")
    let legacyAppResources = repoRoot.appendingPathComponent("build/Cosmic Hammer.app/Contents/Resources")
    let envResources = ProcessInfo.processInfo.environment["COSMIC_HAMMER_TEST_RESOURCES"].map {
        URL(fileURLWithPath: $0)
    }
    let resourceCandidates = [envResources, defaultTestResources, legacyAppResources].compactMap { $0 }
    guard let appResources = resourceCandidates.first(where: {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("extensions").path)
    }) else {
        let paths = resourceCandidates.map(\.path).joined(separator: ", ")
        fatalError("Lua test resources not found; checked \(paths). Run `just test-resources` or `just test` first.")
    }

    let extensionsPath = appResources.appendingPathComponent("extensions").path
    let docsPath = appResources.appendingPathComponent("docs.json").path
    let testResources = repoRoot.appendingPathComponent("Tests/CosmicHammerTests").path
    let testConfigDir = repoRoot.appendingPathComponent(".build/test-config").path
    let appBundle = appBundleURL(forResourceRoot: appResources)
        ?? repoRoot.appendingPathComponent("build/test/Cosmic Hammer.app")
    let frameworksPath = appBundle.appendingPathComponent("Contents/Frameworks").path
    let executablePath = repoRoot.appendingPathComponent(".build/debug/CosmicHammer").path

    for requiredPath in [
        docsPath,
        appResources.appendingPathComponent("setup.lua").path,
        appResources.appendingPathComponent("lua.json").path,
        appResources.appendingPathComponent("timeout3").path,
        appResources.appendingPathComponent("extensions/hs/_boot.lua").path,
        appResources.appendingPathComponent("extensions/hs/_coresetup.lua").path,
        appResources.appendingPathComponent("extensions/hs/_loader_metadata.lua").path,
        appResources.appendingPathComponent("extensions/hs/hsdocs/init.lua").path,
    ] {
        guard FileManager.default.fileExists(atPath: requiredPath) else {
            fatalError("Lua test resource missing at \(requiredPath). Run `just test-resources` or `just test` first.")
        }
    }
    try? FileManager.default.createDirectory(
        atPath: testConfigDir,
        withIntermediateDirectories: true
    )

    MJLuaAlloc()

    let L = lua_getCurrentState()!

    // Replace the production Environment with a simulated one for deterministic tests.
    environmentDetach(L)
    let harness = SimulatorHarness(seed: 42)
    testHarness = harness
    let simEnv = harness.createEnvironment()
    environmentAttach(L, simEnv)
    environmentSetGlobal(simEnv)

    // Seed the SimulatedAudio with data sources so audiodevice data-source tests pass.
    if let audioSim = simEnv.audio as? SimulatedAudio {
        // Output device (id 1) has an output data source (mimics "Internal Speakers")
        audioSim.dataSources[1] = [
            .output: [AudioDataSourceInfo(id: 101, name: "Internal Speakers", deviceID: 1)]
        ]
        audioSim.currentDataSourceIDs[1] = [.output: 101]

        // Input device (id 2) has an input data source (mimics "Internal Microphone")
        audioSim.dataSources[2] = [
            .input: [AudioDataSourceInfo(id: 201, name: "Internal Microphone", deviceID: 2)]
        ]
        audioSim.currentDataSourceIDs[2] = [.input: 201]
    }

    // Seed the SimulatedApplication with the current process and commonly-needed bundle info.
    if let appSim = simEnv.application as? SimulatedApplication {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        appSim.addApp(ApplicationInfo(
            pid: currentPID,
            bundleID: "org.cosmic-hammer.CosmicHammer",
            name: "Cosmic Hammer",
            path: Bundle.main.bundlePath,
            isFrontmost: true,
            isRunning: true,
            kind: 1,
            isResponsive: true
        ))
        appSim.frontmostPID = currentPID

        // Add a Dock process (background-only, no menus) so tests see >1 running app.
        // Use large fake PIDs that won't collide with real OS processes.
        appSim.addApp(ApplicationInfo(
            pid: 99901, bundleID: "com.apple.dock",
            name: "Dock", path: "/System/Library/CoreServices/Dock.app",
            isRunning: true, kind: -1, isResponsive: true
        ))
        // Add Finder as a second regular app.
        appSim.addApp(ApplicationInfo(
            pid: 99902, bundleID: "com.apple.finder",
            name: "Finder", path: "/System/Library/CoreServices/Finder.app",
            isRunning: true, kind: 1, isResponsive: true
        ))

        // Seed bundle registry for Safari (used by many tests)
        appSim.registerBundle(
            bundleID: "com.apple.Safari", name: "Safari",
            path: "/Applications/Safari.app",
            info: ["CFBundleExecutable": "Safari", "CFBundleName": "Safari",
                   "CFBundleIdentifier": "com.apple.Safari"],
            localizations: ["en", "fr", "de", "ja", "es", "it", "pt", "nl", "sv", "da", "fi", "nb", "ko", "zh_CN", "zh_TW", "ru", "pl", "tr", "uk", "ar", "hr", "cs", "el", "he", "ro", "sk", "th", "id", "ms", "en_AU", "en_GB", "ca", "hu", "vi"],
            preferredLocalizations: ["en"]
        )

        // Seed UTI handlers
        appSim.utiHandlers["public.jpeg"] = "com.apple.Preview"
        appSim.utiHandlers["public.png"] = "com.apple.Preview"

        // Set up menus for the current app (Cosmic Hammer)
        appSim.setMenus(forPID: currentPID, [
            AppMenuItemInfo(title: "Cosmic Hammer", role: "AXMenuBarItem", children: [
                AppMenuItemInfo(title: "About Cosmic Hammer"),
                AppMenuItemInfo(title: "Preferences..."),
                AppMenuItemInfo(title: "Quit Cosmic Hammer", cmdChar: "q", cmdModifiers: ["cmd"]),
            ]),
            AppMenuItemInfo(title: "Edit", role: "AXMenuBarItem", children: [
                AppMenuItemInfo(title: "Undo", cmdChar: "z", cmdModifiers: ["cmd"]),
                AppMenuItemInfo(title: "Redo", cmdChar: "z", cmdModifiers: ["cmd", "shift"]),
                AppMenuItemInfo(title: "Cut", cmdChar: "x", cmdModifiers: ["cmd"]),
                AppMenuItemInfo(title: "Copy", cmdChar: "c", cmdModifiers: ["cmd"]),
                AppMenuItemInfo(title: "Paste", cmdChar: "v", cmdModifiers: ["cmd"]),
                AppMenuItemInfo(title: "Select All", cmdChar: "a", cmdModifiers: ["cmd"]),
            ]),
        ])
    }

    // Seed the SimulatedProcess with scripted results for task tests.
    if let procSim = simEnv.process as? SimulatedProcess {
        // /usr/bin/false exits with code 1
        procSim.scriptedResults["/usr/bin/false"] = ProcessResult(
            exitCode: 1, stdout: Data(), stderr: Data()
        )
    }

    // Create the "hs" global table with essential core functions
    var corelib: [luaL_Reg] = [
        luaL_Reg(name: strdup("getObjectMetatable"), func: test_getObjectMetatable),
        luaL_Reg(name: nil, func: nil),
    ]
    lua_createtable(L, 0, Int32(corelib.count - 1))
    luaL_setfuncs(L, &corelib, 0)
    lua_setglobal(L, "hs")

    // Register simulated window creation functions on the hs table.
    // These must be set BEFORE preBootLua which used to override them with noop.
    let sim_openConsole: lua_CFunction = { L in
        guard let L = L else { return 0 }
        let env = environmentGet(L)
        let pid = ProcessInfo.processInfo.processIdentifier
        // Only create if not already open; always focus it
        if let existing = env.window.allWindows().first(where: { $0.title == "Cosmic Hammer Console" && $0.pid == pid }) {
            _ = env.window.focus(windowID: existing.id)
        } else {
            _ = env.window.createWindow(
                title: "Cosmic Hammer Console", pid: pid,
                role: "AXWindow", subrole: "AXStandardWindow",
                frame: (100, 100, 800, 600)
            )
        }
        return 0
    }
    let sim_closeConsole: lua_CFunction = { L in
        guard let L = L else { return 0 }
        let env = environmentGet(L)
        let pid = ProcessInfo.processInfo.processIdentifier
        if let w = env.window.allWindows().first(where: { $0.title == "Cosmic Hammer Console" && $0.pid == pid }) {
            _ = env.window.close(windowID: w.id)
        }
        return 0
    }
    let sim_openPreferences: lua_CFunction = { L in
        guard let L = L else { return 0 }
        let env = environmentGet(L)
        let pid = ProcessInfo.processInfo.processIdentifier
        if let existing = env.window.allWindows().first(where: { $0.title == "Cosmic Hammer Preferences" && $0.pid == pid }) {
            _ = env.window.focus(windowID: existing.id)
        } else {
            _ = env.window.createWindow(
                title: "Cosmic Hammer Preferences", pid: pid,
                role: "AXWindow", subrole: "AXStandardWindow",
                frame: (200, 200, 600, 400)
            )
        }
        return 0
    }
    let sim_closePreferences: lua_CFunction = { L in
        guard let L = L else { return 0 }
        let env = environmentGet(L)
        let pid = ProcessInfo.processInfo.processIdentifier
        if let w = env.window.allWindows().first(where: { $0.title == "Cosmic Hammer Preferences" && $0.pid == pid }) {
            _ = env.window.close(windowID: w.id)
        }
        return 0
    }

    lua_getglobal(L, "hs")
    lua_pushcfunction(L, sim_openConsole)
    lua_setfield(L, -2, "openConsole")
    lua_pushcfunction(L, sim_closeConsole)
    lua_setfield(L, -2, "closeConsole")
    lua_pushcfunction(L, sim_openPreferences)
    lua_setfield(L, -2, "openPreferences")
    lua_pushcfunction(L, sim_closePreferences)
    lua_setfield(L, -2, "closePreferences")
    lua_pop(L, 1) // pop hs table

    installLuaSkinCompatibilityGlobals(L)
    HSExtensionsRegisterAll(L)

    // Register a C function that reads simulated clock time, so Lua can
    // override os.time/os.date BEFORE any modules capture them at load time.
    let simEpochTime: lua_CFunction = { L in
        let env = environmentGet(L)
        lua_pushnumber(L, lua_Number(env.clock.secondsSinceEpoch()))
        return 1
    }
    lua_pushcfunction(L, simEpochTime)
    lua_setglobal(L, "_simulated_epoch_time")

    let setupPath = appResources.appendingPathComponent("setup.lua").path
    let srcExtensions = repoRoot.appendingPathComponent("extensions").path
    let srcExtEsc = srcExtensions.replacingOccurrences(of: "'", with: "\\'")
    let testEsc = testResources.replacingOccurrences(of: "'", with: "\\'")
    let resourceEsc = appResources.path.replacingOccurrences(of: "'", with: "\\'")
    let bundleEsc = appBundle.path.replacingOccurrences(of: "'", with: "\\'")
    let executableEsc = executablePath.replacingOccurrences(of: "'", with: "\\'")
    let frameworksEsc = frameworksPath.replacingOccurrences(of: "'", with: "\\'")
    let processID = ProcessInfo.processInfo.processIdentifier
    let preBootLua = """
    local noop = function() end
    hs._logmessage = noop
    hs.processInfo = {
        bundleID = 'org.hammerspoon.Hammerspoon',
        bundlePath = '\(bundleEsc)',
        executablePath = '\(executableEsc)',
        frameworksPath = '\(frameworksEsc)',
        processID = \(processID),
        resourcePath = '\(resourceEsc)',
        version = 'test',
    }
    hs._exit = function() end
    os.exit = hs._exit
    hs.accessibilityState = function() return true end
    hs.cleanUTF8forConsole = function(value) return value end
    hs.focus = noop
    -- hs.openConsole, hs.closeConsole, hs.openPreferences, hs.closePreferences
    -- are registered as C functions above (sim_openConsole etc.)
    hs._notify = noop
    local toggles = { autoLaunch = false, consoleOnTop = false, dockIcon = true, menuIcon = true }
    hs.autoLaunch = function(value)
        if value ~= nil then toggles.autoLaunch = not not value end
        return toggles.autoLaunch
    end
    hs.consoleOnTop = function(value)
        if value ~= nil then toggles.consoleOnTop = not not value end
        return toggles.consoleOnTop
    end
    hs.dockIcon = function(value)
        if value ~= nil then toggles.dockIcon = not not value end
        return toggles.dockIcon
    end
    hs.menuIcon = function(value)
        if value ~= nil then toggles.menuIcon = not not value end
        return toggles.menuIcon
    end
    hs.reload = function()
        if type(hs.shutdownCallback) == 'function' then hs.shutdownCallback() end
    end

    package.preload['hs.notify'] = function()
        return { register = noop, show = noop }
    end

    -- Override os.time/os.date BEFORE setup.lua loads any modules that
    -- capture these functions into locals (e.g. timer.lua line 12).
    local _real_os_time = os.time
    local _real_os_date = os.date
    os.time = function(t)
        if t then return _real_os_time(t) end
        return math.floor(_simulated_epoch_time())
    end
    os.date = function(fmt, t)
        if t then return _real_os_date(fmt, t) end
        return _real_os_date(fmt, math.floor(_simulated_epoch_time()))
    end
    """
    let preBootResult = doLuaString(L, preBootLua)
    if preBootResult != LUA_OK {
        var len: Int = 0
        let err = lua_tolstring(L, -1, &len).flatMap { String(cString: $0) } ?? "unknown"
        fatalError("Lua pre-boot test setup error: \(err)")
    }
    lua_settop(L, 0)

    do {
        _ = try LuaBoot.runSetup(
            L,
            setupPath: setupPath,
            context: LuaBoot.Context(
                extensionsPath: extensionsPath,
                configFileDisplayPath: testConfigDir + "/init.lua",
                configFilePath: testConfigDir + "/init.lua",
                configDir: testConfigDir,
                dataDir: testConfigDir + "/data",
                docsJSONPath: docsPath,
                hasInitFile: false,
                autoloadExtensions: true
            )
        )
    } catch {
        fatalError("Lua boot test setup error: \(error)")
    }
    lua_settop(L, 0)

    let postBootLua = """
    package.path = '\(testEsc)/?.lua;' .. package.path

    local lfs = require('hs.fs')
    for entry in lfs.dir('\(srcExtEsc)') do
        if entry ~= '.' and entry ~= '..' then
            local path = '\(srcExtEsc)/' .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == 'directory' then
                package.path = path .. '/?.lua;' .. package.path
            end
        end
    end

    require('lsunit')
    """
    let result = doLuaString(L, postBootLua)
    if result != LUA_OK {
        var len: Int = 0
        let err = lua_tolstring(L, -1, &len).flatMap { String(cString: $0) } ?? "unknown"
        NSLog("Lua post-boot test setup error: %@", err)
        lua_settop(L, lua_gettop(L) - 1)
    }
    lua_settop(L, 0)

    // Clear the global environment after bootstrap completes.
    // luaRunString() will re-set it under globalEnvLock for each call.
    environmentClearGlobal()
}
