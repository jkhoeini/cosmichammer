//
//  MJLua.swift
//  Hammerspoon
//
//  Ported from MJLua.m by Mohammad Sadegh Khoeini.
//  Copyright © 2026 Hammerspoon. All rights reserved.
//

import Cocoa
import LuaSkin
import AVFoundation

// MARK: - Module-level state (formerly static C variables)

private var MJLuaLogDelegate: (any LuaSkinDelegate)?
private var evalfn: Int32 = 0
private var completionsForWordFn: Int32 = 0
private var oldPanicFunction: lua_CFunction?
private var refTable: LSRefTable = 0
private var loghandler: (@convention(block) (NSString) -> Void)?

// MARK: - String constants (from variables.h)

private let HSAutoLoadExtensions = "HSAutoLoadExtensions"

// MARK: - Import HSExtensionsRegisterAll from the HSExtensions (ObjC) target

@_silgen_name("HSExtensionsRegisterAll")
private func HSExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>?)

// MARK: - Log handler setup

@_cdecl("MJLuaSetupLogHandler")
func MJLuaSetupLogHandler(_ blk: @escaping @convention(block) (NSString) -> Void) {
    loghandler = blk
}

// MARK: - Core Lua functions (each maps to an entry in the corelib luaL_Reg array)

/// hs.autoLaunch([state]) -> bool
/// Function
/// Set or display the "Launch on Login" status for Hammerspoon.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not Hammerspoon should be launched automatically when you log into your computer.
///
/// Returns:
///  * True if Hammerspoon is currently (or has just been) set to launch on login or False if Hammerspoon is not.
private func core_autolaunch(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_isboolean(L, 1) { MJAutoLaunchSet(lua_toboolean(L, 1) != 0) }
    lua_pushboolean(L, MJAutoLaunchGet() ? 1 : 0)
    return 1
}

/// hs.menuIcon([state]) -> bool
/// Function
/// Set or display whether or not the Hammerspoon menu icon is visible.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not the Hammerspoon menu icon should be visible.
///
/// Returns:
///  * True if the icon is currently set (or has just been) to be visible or False if it is not.
private func core_menuicon(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_isboolean(L, 1) { MJMenuIconSetVisible(lua_toboolean(L, 1) != 0) }
    lua_pushboolean(L, MJMenuIconVisible() ? 1 : 0)
    return 1
}

/// hs.consoleOnTop([state]) -> bool
/// Function
/// Set or display whether or not the Hammerspoon console is always on top when visible.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not the Hammerspoon console is always on top when visible.
///
/// Returns:
///  * True if the console is currently set (or has just been) to be always on top when visible or False if it is not.
private func core_consoleontop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_isboolean(L, 1) { MJConsoleWindowSetAlwaysOnTop(lua_toboolean(L, 1) != 0) }
    lua_pushboolean(L, MJConsoleWindowAlwaysOnTop() ? 1 : 0)
    return 1
}

/// hs.openAbout()
/// Function
/// Displays the OS X About panel for Hammerspoon; implicitly focuses Hammerspoon.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func core_openabout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    NSApplication.shared.activate()
    NSApplication.shared.orderFrontStandardAboutPanel(nil)
    return 0
}

/// hs.openPreferences()
/// Function
/// Displays the Hammerspoon Preferences panel; implicitly focuses Hammerspoon.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func core_openpreferences(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    NSApplication.shared.activate()
    MJPreferencesWindowController.singleton().showWindow(nil)
    return 0
}

/// hs.closePreferences()
/// Function
/// Closes the Hammerspoon Preferences window
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func core_closepreferences(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    MJPreferencesWindowController.singleton().window?.orderOut(nil)
    return 0
}

/// hs.openConsole([bringToFront])
/// Function
/// Opens the Hammerspoon Console window and optionally focuses it.
///
/// Parameters:
///  * bringToFront - if true (default), the console will be focused as well as opened.
///
/// Returns:
///  * None
private func core_openconsole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if !(lua_isboolean(L, 1) && lua_toboolean(L, 1) == 0) {
        NSApplication.shared.activate()
    }
    MJConsoleWindowController.singleton().showWindow(nil)
    return 0
}

/// hs.closeConsole()
/// Function
/// Closes the Hammerspoon Console window
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func core_closeconsole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    MJConsoleWindowController.singleton().window?.orderOut(nil)
    return 0
}

/// hs.open(filePath)
/// Function
/// Opens a file as if it were opened with /usr/bin/open
///
/// Parameters:
///  * filePath - A string containing the path to a file/bundle to open
///
/// Returns:
///  * A boolean, true if the file was opened successfully, otherwise false
private func core_open(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let path = skin.toNSObject(at: 1) as! String
    let pathURL = URL(fileURLWithPath: path)
    let result = NSWorkspace.shared.open(pathURL)

    lua_pushboolean(L, result ? 1 : 0)
    return 1
}

/// hs.reload()
/// Function
/// Reloads your init-file in a fresh Lua environment.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func core_reload(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    DispatchQueue.main.async {
        MJLuaReplace()
    }
    return 0
}

/// hs.processInfo
/// Constant
/// A table containing read-only information about the Hammerspoon application instance currently running.
private func push_hammerAppInfo(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    // Fetch the CPU architecture in use
    var arch = "Unknown"
    var utsname = utsname()
    if uname(&utsname) == 0 {
        arch = withUnsafePointer(to: &utsname.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    let bundle = Bundle.main
    let infoDictionary = bundle.infoDictionary ?? [:]

    #if DEBUG
    let isDebugBuild = true
    #else
    let isDebugBuild = false
    #endif

    let appInfo: [String: Any] = [
        "version": infoDictionary["CFBundleShortVersionString"] as? String ?? "",
        "build": infoDictionary["CFBundleVersion"] as? String ?? "",
        "resourcePath": String(cString: (bundle.resourcePath! as NSString).fileSystemRepresentation),
        "bundlePath": String(cString: (bundle.bundlePath as NSString).fileSystemRepresentation),
        "executablePath": String(cString: (bundle.executablePath! as NSString).fileSystemRepresentation),
        "frameworksPath": String(cString: (bundle.privateFrameworksPath! as NSString).fileSystemRepresentation),
        "processID": getpid(),
        "bundleID": bundle.bundleIdentifier ?? "",
        "arch": arch,
        "isRosetta": false,
        "buildTime": {
            if let execPath = Bundle.main.executablePath,
               let attrs = try? FileManager.default.attributesOfItem(atPath: execPath),
               let modDate = attrs[.modificationDate] as? Date {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM dd yyyy, HH:mm:ss"
                return fmt.string(from: modDate)
            }
            return "Unknown"
        }(),
        "debugBuild": isDebugBuild,
    ]

    skin.pushNSObject(appInfo as NSDictionary)
    return 1
}

/// hs.accessibilityState(shouldPrompt) -> isEnabled
/// Function
/// Checks the Accessibility Permissions for Hammerspoon, and optionally allows you to prompt for permissions.
///
/// Parameters:
///  * shouldPrompt - an optional boolean value indicating if the dialog box asking if the System Preferences application should be opened should be presented when Accessibility is not currently enabled for Hammerspoon.  Defaults to false.
///
/// Returns:
///  * True or False indicating whether or not Accessibility is enabled for Hammerspoon.
///
/// Notes:
///  * Since this check is done automatically when Hammerspoon loads, it is probably of limited use except for skipping things that are known to fail when Accessibility is not enabled.  Evettaps which try to capture keyUp and keyDown events, for example, will fail until Accessibility is enabled and the Hammerspoon application is relaunched.
private func core_accessibilityState(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let shouldprompt = lua_toboolean(L, 1) != 0
    let enabled = MJAccessibilityIsEnabled()
    if shouldprompt { MJAccessibilityOpenPanel() }
    lua_pushboolean(L, enabled ? 1 : 0)
    return 1
}

// SOURCE: https://stackoverflow.com/a/58985069
private func isScreenRecordingEnabled() -> Bool {
    var canRecordScreen = false
    let runningApplication = NSRunningApplication.current
    let ourProcessIdentifier = runningApplication.processIdentifier

    guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }

    for windowInfo in windowList {
        guard let processIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            continue
        }

        // don't check windows owned by this process
        if processIdentifier != ourProcessIdentifier {
            guard let windowRunningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
                // ignore processes we don't have access to, such as WindowServer
                continue
            }

            let windowName = windowInfo[kCGWindowName as String] as? String
            if let windowName = windowName {
                let windowExecutableName = windowRunningApplication.executableURL?.lastPathComponent
                if windowExecutableName == "Dock" {
                    // ignore the Dock, which provides the desktop picture
                    continue
                }
                canRecordScreen = true
                break
            }
        }
    }

    return canRecordScreen
}

/// hs.screenRecordingState(shouldPrompt) -> isEnabled
/// Function
/// Checks the Screen Recording Permissions for Hammerspoon, and optionally allows you to prompt for permissions.
///
/// Parameters:
///  * shouldPrompt - an optional boolean value indicating if the dialog box asking if the System Preferences application should be opened should be presented when Screen Recording is not currently enabled for Hammerspoon.  Defaults to false.
///
/// Returns:
///  * True or False indicating whether or not Screen Recording is enabled for Hammerspoon.
///
/// Notes:
///  * If you trigger the prompt and the user denies it, you cannot bring up the prompt again - the user must manually enable it in System Preferences.
private func core_screenRecordingState(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let shouldprompt = lua_toboolean(L, 1) != 0
    let enabled = isScreenRecordingEnabled()
    if shouldprompt {
        // CGDisplayStreamCreate is obsoleted in macOS 15 SDK but still works at runtime.
        // We use it only to trigger the screen recording permission prompt.
        typealias CGDisplayStreamCreateFunc = @convention(c) (
            CGDirectDisplayID, Int, Int, Int32, CFDictionary?,
            @convention(block) (Int32, UInt64, IOSurfaceRef?, CGDisplayStreamUpdate?) -> Void
        ) -> CGDisplayStream?

        if let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGDisplayStreamCreate") {
            let createStream = unsafeBitCast(sym, to: CGDisplayStreamCreateFunc.self)
            let stream = createStream(
                CGMainDisplayID(), 1, 1,
                Int32(kCVPixelFormatType_32BGRA), nil,
                { _, _, _, _ in }
            )
            // stream is autoreleased / ARC-managed
            _ = stream
        }
    }
    lua_pushboolean(L, enabled ? 1 : 0)
    return 1
}

/// hs.microphoneState(shouldPrompt) -> boolean
/// Function
/// Checks the Microphone Permissions for Hammerspoon, and optionally allows you to prompt for permissions.
///
/// Parameters:
///  * shouldPrompt - an optional boolean value indicating if we should request microphone access. Defaults to false.
///
/// Returns:
///  * `true` or `false` indicating whether or not Microphone access is enabled for Hammerspoon.
///
/// Notes:
///  * Will always return `true` on macOS 10.13 or earlier.
private func core_microphoneState(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let shouldprompt = lua_toboolean(L, 1) != 0

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        lua_pushboolean(L, 1)
    case .notDetermined:
        if shouldprompt {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    skin.logWarn("Hammerspoon has been declined Microphone access by the user.")
                }
            }
        }
        lua_pushboolean(L, 0)
    case .denied, .restricted:
        lua_pushboolean(L, 0)
    @unknown default:
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.cameraState(shouldPrompt) -> boolean
/// Function
/// Checks the Camera Permissions for Hammerspoon, and optionally allows you to prompt for permissions.
///
/// Parameters:
///  * shouldPrompt - an optional boolean value indicating if we should request camera access. Defaults to false.
///
/// Returns:
///  * `true` or `false` indicating whether or not Camera access is enabled for Hammerspoon.
///
/// Notes:
///  * Will always return `true` on macOS 10.13 or earlier.
private func core_cameraState(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let shouldprompt = lua_toboolean(L, 1) != 0

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        lua_pushboolean(L, 1)
    case .notDetermined:
        if shouldprompt {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    skin.logWarn("Hammerspoon has been declined Camera access by the user.")
                }
            }
        }
        lua_pushboolean(L, 0)
    case .denied, .restricted:
        lua_pushboolean(L, 0)
    @unknown default:
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.preferencesDarkMode([state]) -> bool
/// Function
/// Set or display whether or not the Preferences panel should display in dark mode.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not the Preferences panel should display in dark mode.
///
/// Returns:
///  * A boolean, true if dark mode is enabled otherwise false.
private func preferencesDarkMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    if lua_isboolean(L, 1) {
        PreferencesDarkModeSetEnabled(lua_toboolean(L, 1) != 0)
        MJPreferencesWindowController.singleton().reflectDefaults()
    }

    lua_pushboolean(L, PreferencesDarkModeEnabled() ? 1 : 0)
    return 1
}

/// hs.allowAppleScript([state]) -> bool
/// Function
/// Set or display whether or not external Hammerspoon AppleScript commands are allowed.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not external Hammerspoon's AppleScript commands are allowed.
///
/// Returns:
///  * A boolean, `true` if Hammerspoon's AppleScript commands are (or has just been) allowed, otherwise `false`.
///
/// Notes:
///  * AppleScript access is disallowed by default.
///  * However due to the way AppleScript support works, Hammerspoon will always allow AppleScript commands that are part of the "Standard Suite", such as `name`, `quit`, `version`, etc. However, Hammerspoon will only allow commands from the "Hammerspoon Suite" if `hs.allowAppleScript()` is set to `true`.
///  * For a full list of AppleScript Commands:
///      - Open `/Applications/Utilities/Script Editor.app`
///      - Click `File > Open Dictionary...`
///      - Select Hammerspoon from the list of Applications
///      - This will now open a Dictionary containing all of the available Hammerspoon AppleScript commands.
///  * Note that strings within the Lua code you pass from AppleScript can be delimited by `[[` and `]]` rather than normal quotes
///  * Example:
///    ```lua
///    tell application "Hammerspoon"
///      execute lua code "hs.alert([[Hello from AppleScript]])"
///    end tell```
private func core_appleScript(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    if lua_isboolean(L, 1) {
        HSAppleScriptSetEnabled(lua_toboolean(L, 1) != 0)
    }

    lua_pushboolean(L, HSAppleScriptEnabled() ? 1 : 0)
    return 1
}

/// hs.openConsoleOnDockClick([state]) -> bool
/// Function
/// Set or display whether or not the Console window will open when the Hammerspoon dock icon is clicked
///
/// Parameters:
///  * state - An optional boolean, true if the console window should open, false if not
///
/// Returns:
///  * A boolean, true if the console window will open when the dock icon
///
/// Notes:
///  * This only refers to dock icon clicks while Hammerspoon is already running. The console window is not opened by launching the app
private func core_openConsoleOnDockClick(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    if lua_isboolean(L, 1) {
        HSOpenConsoleOnDockClickSetEnabled(lua_toboolean(L, 1) != 0)
    }

    lua_pushboolean(L, HSOpenConsoleOnDockClickEnabled() ? 1 : 0)
    return 1
}

/// hs.focus()
/// Function
/// Makes Hammerspoon the foreground app.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func core_focus(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    NSApplication.shared.activate()
    return 0
}

/// hs.getObjectMetatable(name) -> table or nil
/// Function
/// Fetches the Lua metatable for objects produced by an extension
///
/// Parameters:
///  * name - A string containing the name of a module to fetch object metadata for (e.g. `"hs.screen"`)
///
/// Returns:
///  * The extension's object metatable, or nil if an error occurred
private func core_getObjectMetatable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    luaL_getmetatable(L, lua_tostring(L, 1))
    return 1
}

/// hs.cleanUTF8forConsole(inString) -> outString
/// Function
/// Returns a copy of the incoming string that can be displayed in the Hammerspoon console.  Invalid UTF8 sequences are converted to the Unicode Replacement Character and NULL (0x00) is converted to the Unicode Empty Set character.
///
/// Parameters:
///  * inString - the string to be cleaned up
///
/// Returns:
///  * outString - the cleaned up version of the input string.
///
/// Notes:
///  * This function is applied automatically to all output which appears in the Hammerspoon console, but not to the output provided by the `hs` command line tool.
///  * This function does not modify the original string - to actually replace it, assign the result of this function to the original string.
///  * This function is a more specifically targeted version of the `hs.utf8.fixUTF8(...)` function.
private func core_cleanUTF8(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TANY, LS_TBREAK)
    skin.pushNSObject(skin.getValidUTF8(at: 1))
    return 1
}

private func core_exit(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    NSApplication.shared.terminate(nil)
    return 0
}

private func core_logmessage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var len: Int = 0
    let s = lua_tolstring(L, 1, &len)
    var str: String?
    if let s = s {
        str = String(data: Data(bytes: s, count: len), encoding: .utf8)
    }
    if str == nil {
        core_cleanUTF8(L)
        let s2 = lua_tolstring(L, -1, &len)
        if let s2 = s2 {
            str = String(data: Data(bytes: s2, count: len), encoding: .utf8)
        }
    }
    loghandler?(NSString(string: str ?? ""))
    return 0
}

private func core_notify(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var len: Int = 0
    let s = lua_tolstring(L, 1, &len)
    var str = ""
    if let s = s {
        str = String(data: Data(bytes: s, count: len), encoding: .utf8) ?? ""
    }
    MJUserNotificationManager.sharedManager.sendNotification(str) {
        MJConsoleWindowController.singleton().showWindow(nil)
    }
    return 0
}

// MARK: - Core library registration table

private var corelib: [luaL_Reg] = [
    luaL_Reg(name: strdup("preferencesDarkMode"), func: preferencesDarkMode),
    luaL_Reg(name: strdup("openConsoleOnDockClick"), func: core_openConsoleOnDockClick),
    luaL_Reg(name: strdup("openConsole"), func: core_openconsole),
    luaL_Reg(name: strdup("closeConsole"), func: core_closeconsole),
    luaL_Reg(name: strdup("consoleOnTop"), func: core_consoleontop),
    luaL_Reg(name: strdup("openAbout"), func: core_openabout),
    luaL_Reg(name: strdup("menuIcon"), func: core_menuicon),
    luaL_Reg(name: strdup("openPreferences"), func: core_openpreferences),
    luaL_Reg(name: strdup("closePreferences"), func: core_closepreferences),
    luaL_Reg(name: strdup("open"), func: core_open),
    luaL_Reg(name: strdup("autoLaunch"), func: core_autolaunch),
    luaL_Reg(name: strdup("allowAppleScript"), func: core_appleScript),
    luaL_Reg(name: strdup("reload"), func: core_reload),
    luaL_Reg(name: strdup("focus"), func: core_focus),
    luaL_Reg(name: strdup("accessibilityState"), func: core_accessibilityState),
    luaL_Reg(name: strdup("screenRecordingState"), func: core_screenRecordingState),
    luaL_Reg(name: strdup("microphoneState"), func: core_microphoneState),
    luaL_Reg(name: strdup("cameraState"), func: core_cameraState),
    luaL_Reg(name: strdup("getObjectMetatable"), func: core_getObjectMetatable),
    luaL_Reg(name: strdup("cleanUTF8forConsole"), func: core_cleanUTF8),
    luaL_Reg(name: strdup("_exit"), func: core_exit),
    luaL_Reg(name: strdup("_logmessage"), func: core_logmessage),
    luaL_Reg(name: strdup("_notify"), func: core_notify),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Lua environment lifecycle, high level

/// Create and configure a Lua environment
@_cdecl("MJLuaCreate")
func MJLuaCreate() {
    MJLuaAlloc()
    MJLuaInit()
    NSLog("Created Lua instance")
}

/// Deconfigure and destroy a Lua environment
@_cdecl("MJLuaDestroy")
func MJLuaDestroy() {
    NSLog("Destroying Lua instance")
    MJLuaDeinit()
    MJLuaDealloc()
}

/// Deconfigure and destroy a Lua environment and create its replacement
@_cdecl("MJLuaReplace")
func MJLuaReplace() {
    MJLuaDeinit()
    MJLuaDealloc()
    MJConsoleWindowController.singleton().initializeConsoleColorsAndFont()

    MJLuaAlloc()
    MJLuaInit()
}

// MARK: - Lua environment lifecycle, low level

private func MJLuaAtPanic(_ L: UnsafeMutablePointer<lua_State>?) -> Int32 {
    NSLog("LUA_AT_PANIC: %s", lua_tostring(L, -1) ?? "<nil>")
    if let oldPanicFunction = oldPanicFunction {
        return oldPanicFunction(L)
    }
    return 0
}

/// Create a Lua environment with LuaSkin
@_cdecl("MJLuaAlloc")
func MJLuaAlloc() {
    if MJLuaLogDelegate == nil {
        MJLuaLogDelegate = (HSLoggerCreateWithLua(nil) as! any LuaSkinDelegate)
    }
    var skin = LuaSkin.shared(withDelegate: MJLuaLogDelegate) as! LuaSkin
    // on a reload, this won't get created in sharedWithDelegate:, so do it manually here
    if LuaSkin.mainLuaState == nil {
        skin.createLuaState()
        skin.delegate = MJLuaLogDelegate
        // make sure skin.L points to the main state since we just created a new one
        skin = LuaSkin.shared(with: nil) as! LuaSkin
    }
    HSLoggerSetLuaState(MJLuaLogDelegate as AnyObject, skin.l)
    oldPanicFunction = lua_atpanic(skin.l, MJLuaAtPanic)
}

/// Configure a Lua environment that has already been created by LuaSkin
@_cdecl("MJLuaInit")
func MJLuaInit() {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!

    refTable = skin.registerLibrary("core", functions: &corelib, metaFunctions: nil)
    push_hammerAppInfo(L)
    lua_setfield(L, -2, "processInfo")

    lua_setglobal(L, "hs")

    // Register every bundled hs.lib<name> entry point into package.preload before setup.lua runs.
    HSExtensionsRegisterAll(L)

    let setupPath = Bundle.main.path(forResource: "setup", ofType: "lua")
    let loadresult: Int32 = (setupPath as NSString?)?.fileSystemRepresentation.withMemoryRebound(to: CChar.self, capacity: 1) { fsRep in
        luaL_loadfilex(L, fsRep, nil)
    } ?? LUA_ERRFILE
    if loadresult != 0 {
        NSLog("Unable to load setup.lua from bundle. Terminating")
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        alert.messageText = "Hammerspoon installation is corrupted"
        alert.informativeText = "Please re-install Hammerspoon"
        alert.alertStyle = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    let extensionsPath = Bundle.main.path(forResource: "extensions", ofType: nil)
    lua_pushstring(L, (extensionsPath as NSString?)?.fileSystemRepresentation)
    lua_pushstring(L, (MJConfigFileGet() as String).cString(using: .utf8))
    lua_pushstring(L, (MJConfigFileFullPath() as String).cString(using: .utf8))
    lua_pushstring(L, (MJConfigDir() as String).cString(using: .utf8))
    let docsPath = Bundle.main.path(forResource: "docs", ofType: "json")
    lua_pushstring(L, (docsPath as NSString?)?.fileSystemRepresentation)
    lua_pushboolean(L, FileManager.default.fileExists(atPath: MJConfigFileFullPath() as String) ? 1 : 0)
    lua_pushboolean(L, UserDefaults.standard.bool(forKey: HSAutoLoadExtensions) ? 1 : 0)

    if lua_pcall(L, 7, 2, 0) != LUA_OK {
        let errorMessage: String
        if let cStr = lua_tostring(L, -1) {
            errorMessage = String(cString: cStr)
        } else {
            errorMessage = "(unknown error)"
        }
        lua_pop(L, 1) // Pop the error message off the stack
        NSLog("Error running setup.lua:%@", errorMessage)
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        alert.messageText = "Hammerspoon initialization failed"
        alert.informativeText = errorMessage
        alert.alertStyle = .critical
        alert.runModal()
    } else {
        if lua_gettop(L) != 2 || lua_type(L, -1) != LUA_TFUNCTION || lua_type(L, -2) != LUA_TFUNCTION {
            let debugPart = "setup.lua returned this: \(lua_gettop(L)):\(lua_gettop(L) >= 1 ? lua_type(L, -1) : -10):\(lua_gettop(L) >= 2 ? lua_type(L, -2) : -10)"

            let errorMessage = "setup.lua failed to return the two items it is supposed to.\nThis is a severe bug. We would really appreciate your help in getting this fixed - please relaunch Hammerspoon so a crash report can be uploaded, then contact the Hammerspoon developers via GitHub."
            let alert = NSAlert()
            alert.addButton(withTitle: "OK")
            alert.messageText = "Critical startup failure bug"
            alert.informativeText = errorMessage
            alert.alertStyle = .critical
            alert.runModal()

            skin.logBreadcrumb("setup.lua returned incorrectly: \(debugPart)")

            // Fall through this, so we crash, so we can get the crash report
        }
        evalfn = Int32(skin.luaRef(refTable))
        completionsForWordFn = Int32(skin.luaRef(refTable))
        skin.logBreadcrumb("setup.lua completed")
    }
}

// MARK: - Callbacks

/// Accessibility State Callback
@_cdecl("callAccessibilityStateCallback")
func callAccessibilityStateCallback() {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!
    _lua_stackguard_entry(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "accessibilityStateCallback")

    if lua_type(L, -1) == LUA_TNIL {
        // There is no callback set, so just pop the callback and carry on
        lua_pop(L, 1)
    } else {
        skin.protectedCallAndError("hs.callAccessibilityStateCallback", nargs: 0, nresults: 0)
    }

    // Pop the hs global off the stack
    lua_pop(L, 1)
    _lua_stackguard_exit(L)
}

/// Text Dropped to Dock Icon Callback
@_cdecl("textDroppedToDockIcon")
func textDroppedToDockIcon(_ pboardString: NSString) {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!
    _lua_stackguard_entry(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "textDroppedToDockIconCallback")

    if lua_type(L, -1) == LUA_TNIL {
        // There is no callback set, so just pop the callback and carry on
        lua_pop(L, 1)
    } else {
        skin.pushNSObject(pboardString)
        skin.protectedCallAndError("hs.textDroppedToDockIconCallback", nargs: 1, nresults: 0)
    }

    // Pop the hs global off the stack
    lua_pop(L, 1)
    _lua_stackguard_exit(L)
}

/// File Dropped to Dock Icon Callback
@_cdecl("fileDroppedToDockIcon")
func fileDroppedToDockIcon(_ filePath: NSString) {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!
    _lua_stackguard_entry(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "fileDroppedToDockIconCallback")

    if lua_type(L, -1) == LUA_TNIL {
        // There is no callback set, so just pop the callback and carry on
        lua_pop(L, 1)
    } else {
        skin.pushNSObject(filePath)
        skin.protectedCallAndError("hs.fileDroppedToDockIconCallback", nargs: 1, nresults: 0)
    }

    // Pop the hs global off the stack
    lua_pop(L, 1)
    _lua_stackguard_exit(L)
}

/// Dock Icon Click Callback
@_cdecl("callDockIconCallback")
func callDockIconCallback() {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l

    guard let L = L else {
        // It seems to be possible that NSApplicationDelegate:applicationShouldHandleReopen
        // can be called before a Lua state has been created. We need to bail out immediately
        // or we'll cause a crash.
        return
    }

    _lua_stackguard_entry(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "dockIconClickCallback")

    if lua_type(L, -1) == LUA_TNIL {
        // There is no callback set, so just pop the callback and carry on
        lua_pop(L, 1)
    } else {
        skin.protectedCallAndError("hs.dockIconClickCallback", nargs: 0, nresults: 0)
    }

    // Pop the hs global off the stack
    lua_pop(L, 1)
    _lua_stackguard_exit(L)
}

/// Shutdown Callback
private func callShutdownCallback(_ L: UnsafeMutablePointer<lua_State>!) {
    let skin = LuaSkin.skin(with: L)
    _lua_stackguard_entry(skin.l)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "shutdownCallback")

    if lua_type(L, -1) == LUA_TNIL {
        // There is no callback set, so just pop the callback and carry on
        lua_pop(L, 1)
    } else {
        skin.protectedCallAndError("hs.shutdownCallback", nargs: 0, nresults: 0)
    }

    // Pop the hs global off the stack
    lua_pop(L, 1)
    _lua_stackguard_exit(skin.l)
}

/// Deconfigure a Lua environment that will shortly be destroyed by LuaSkin
@_cdecl("MJLuaDeinit")
func MJLuaDeinit() {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin

    callShutdownCallback(skin.l)

    HSLoggerSetLuaState(MJLuaLogDelegate as AnyObject, nil)
}

/// Destroy a Lua environment with LuaSkin
@_cdecl("MJLuaDealloc")
func MJLuaDealloc() {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    skin.destroyLuaState()
}

// MARK: - Run string / completions / get active state

@_cdecl("MJLuaRunString")
func MJLuaRunString(_ command: NSString) -> NSString {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!
    _lua_stackguard_entry(L)

    skin.pushLuaRef(refTable, ref: evalfn)
    if !lua_isfunction(L, -1) {
        NSLog("ERROR: MJLuaRunString doesn't seem to have an evalfn")
        if lua_isstring(L, -1) {
            NSLog("evalfn appears to be a string: %s", lua_tostring(L, -1) ?? "")
        }
        // Whatever evalfn was, it wasn't a function, so pop it
        lua_pop(L, 1)
        _lua_stackguard_exit(L)
        return ""
    }
    lua_pushstring(L, (command as String).cString(using: .utf8))
    if skin.protectedCallAndTraceback(1, nresults: 1) == false {
        if let errorMsg = lua_tostring(L, -1) {
            skin.logError(String(cString: errorMsg))
        }
    }

    var len: Int = 0
    let s = lua_tolstring(L, -1, &len)
    var str: NSString
    if let s = s, let converted = String(data: Data(bytes: s, count: len), encoding: .utf8) {
        str = converted as NSString
    } else if let s = s {
        str = skin.getValidUTF8(s, ofLength: len) as NSString
    } else {
        str = ""
    }
    lua_pop(L, 1)

    _lua_stackguard_exit(L)
    return str
}

@_cdecl("MJLuaCompletionsForWord")
func MJLuaCompletionsForWord(_ completionWord: NSString) -> NSArray {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    _lua_stackguard_entry(skin.l)

    skin.pushLuaRef(refTable, ref: completionsForWordFn)
    skin.pushNSObject(completionWord)
    if skin.protectedCallAndError("MJLuaCompletionsForWord", nargs: 1, nresults: 1) == false {
        _lua_stackguard_exit(skin.l)
        return []
    }

    let completions = skin.toNSObject(at: -1) as? NSArray ?? []
    lua_pop(skin.l, 1)
    _lua_stackguard_exit(skin.l)
    return completions
}

/// C-Code helper to return current active LuaState. Useful for callbacks to
/// verify stored LuaState still matches active one if GC fails to clear it.
@_cdecl("MJGetActiveLuaState")
func MJGetActiveLuaState() -> UnsafeMutablePointer<lua_State>? {
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    return skin.l
}
