import AppKit
import AVFoundation
import LuaSkin

// MARK: - Lua C macro replacements
//
// Many Lua C API "functions" are actually C preprocessor macros that Swift cannot
// import.  We re-implement them here as Swift helpers calling the underlying real
// C functions that *are* imported.

// lua_type constants (C #defines, not visible in Swift)
private let LUA_TNONE: Int32      = -1
private let LUA_TNIL: Int32       = 0
private let LUA_TBOOLEAN: Int32   = 1
private let LUA_TNUMBER: Int32    = 3
private let LUA_TSTRING_T: Int32  = 4
private let LUA_TTABLE: Int32     = 5
private let LUA_TFUNCTION: Int32  = 6
private let LUA_TUSERDATA: Int32  = 7
private let LUA_OK: Int32         = 0

// LuaSkin checkArgs bit-flags (C #defines)
private let LS_TBREAK: Int32      = 1 << 0
private let LS_TOPTIONAL: Int32   = 1 << 1
private let LS_TNIL_LS: Int32     = 1 << 2
private let LS_TBOOLEAN_LS: Int32 = 1 << 3
private let LS_TNUMBER_LS: Int32  = 1 << 4
private let LS_TSTRING: Int32     = 1 << 5
private let LS_TTABLE_LS: Int32   = 1 << 6
private let LS_TFUNCTION_LS: Int32 = 1 << 7
private let LS_TUSERDATA_LS: Int32 = 1 << 8
private let LS_TANY: Int32        = 1 << 10

// LUA_REGISTRYINDEX  =  -(LUAI_MAXSTACK) - 1000
// LUAI_MAXSTACK is 1000000 on 64-bit.
private let LUA_REGISTRYINDEX: Int32 = -1000000 - 1000

/// `lua_pop(L, n)` is `lua_settop(L, -(n)-1)`
@inline(__always)
private func lua_pop(_ L: OpaquePointer!, _ n: Int32) {
    lua_settop(L, -(n) - 1)
}

/// `lua_pcall(L, n, r, f)` is `lua_pcallk(L, n, r, f, 0, nil)`
@inline(__always)
@discardableResult
private func lua_pcall(_ L: OpaquePointer!, _ nargs: Int32, _ nresults: Int32, _ errfunc: Int32) -> Int32 {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, nil)
}

/// `lua_isboolean(L, n)` is `lua_type(L, n) == LUA_TBOOLEAN`
@inline(__always)
private func lua_isboolean(_ L: OpaquePointer!, _ n: Int32) -> Bool {
    return lua_type(L, n) == LUA_TBOOLEAN
}

/// `lua_isfunction(L, n)` is `lua_type(L, n) == LUA_TFUNCTION`
@inline(__always)
private func lua_isfunction(_ L: OpaquePointer!, _ n: Int32) -> Bool {
    return lua_type(L, n) == LUA_TFUNCTION
}

/// `lua_isnil(L, n)` is `lua_type(L, n) == LUA_TNIL`
@inline(__always)
private func lua_isnil(_ L: OpaquePointer!, _ n: Int32) -> Bool {
    return lua_type(L, n) == LUA_TNIL
}

/// `lua_tostring(L, i)` is `lua_tolstring(L, i, nil)`
@inline(__always)
private func lua_tostring(_ L: OpaquePointer!, _ idx: Int32) -> UnsafePointer<CChar>? {
    return lua_tolstring(L, idx, nil)
}

/// `luaL_loadfile(L, f)` is `luaL_loadfilex(L, f, nil)`
@inline(__always)
@discardableResult
private func luaL_loadfile(_ L: OpaquePointer!, _ filename: UnsafePointer<CChar>!) -> Int32 {
    return luaL_loadfilex(L, filename, nil)
}

/// `luaL_getmetatable(L, n)` is `lua_getfield(L, LUA_REGISTRYINDEX, n)`
@inline(__always)
@discardableResult
private func luaL_getmetatable(_ L: OpaquePointer!, _ name: UnsafePointer<CChar>!) -> Int32 {
    return lua_getfield(L, LUA_REGISTRYINDEX, name)
}

// MARK: - checkArgs replacement
//
// ObjC variadic methods like [LuaSkin checkArgs:...] are not importable into Swift.
// This Swift helper replicates the core validation logic for the simple cases used here.

/// Maps a Lua type constant to its corresponding LS_T* bitmask.
private func lsTypeForLuaType(_ luaType: Int32) -> Int32 {
    switch luaType {
    case LUA_TNIL:      return LS_TNIL_LS
    case LUA_TBOOLEAN:  return LS_TBOOLEAN_LS
    case LUA_TNUMBER:   return LS_TNUMBER_LS
    case LUA_TSTRING_T: return LS_TSTRING
    case LUA_TTABLE:    return LS_TTABLE_LS
    case LUA_TFUNCTION: return LS_TFUNCTION_LS
    case LUA_TUSERDATA: return LS_TUSERDATA_LS
    default:            return 0
    }
}

/// Swift-callable equivalent of `[LuaSkin checkArgs:..., LS_TBREAK]`.
/// Pass each arg spec (possibly OR'd with LS_TOPTIONAL), terminated by LS_TBREAK.
/// Example: `luaSkinCheckArgs(L, LS_TSTRING, LS_TBOOLEAN_LS | LS_TOPTIONAL, LS_TBREAK)`
private func luaSkinCheckArgs(_ L: OpaquePointer!, _ specs: Int32...) {
    var idx: Int32 = 1
    let numArgs = lua_gettop(L)

    for spec in specs {
        if spec & LS_TBREAK != 0 {
            idx -= 1
            break
        }

        let luaType = lua_type(L, idx)

        // LS_TANY accepts anything present
        if spec & LS_TANY != 0 && luaType != LUA_TNONE {
            idx += 1
            continue
        }

        if luaType == LUA_TNONE {
            if spec & LS_TOPTIONAL != 0 {
                // optional arg not provided, skip
                continue
            }
            luaL_error(L, "ERROR: incorrect type '%s' for argument %d (expected %s)",
                       lua_typename(L, luaType), idx, "argument")
            return
        }

        let lsType = lsTypeForLuaType(luaType)
        if spec & lsType == 0 && spec & LS_TANY == 0 {
            luaL_error(L, "ERROR: incorrect type '%s' for argument %d",
                       lua_typename(L, luaType), idx)
            return
        }

        idx += 1
    }

    if idx != numArgs {
        luaL_error(L, "ERROR: incorrect number of arguments. Expected %d, got %d", idx, numArgs)
    }
}

// MARK: - Static state

private var MJLuaLogDelegate: HSLogger?
private var evalfn: Int32 = 0
private var completionsForWordFn: Int32 = 0
private var oldPanicFunction: lua_CFunction?
private var refTable: LSRefTable = 0
private var loghandler: ((String) -> Void)?

// LuaSkin log level constants (C #defines, not visible in Swift)
private let LS_LOG_ERROR: Int32      = 1
private let LS_LOG_WARN: Int32       = 2
private let LS_LOG_BREADCRUMB: Int32 = 6

/// LuaSkin's `logWarn:`, `logError:`, `logBreadcrumb:` are ObjC variadic methods
/// which Swift cannot call.  We go through the HSLogger delegate directly instead.
private func skinLogWarn(_ skin: LuaSkin, _ message: String) {
    MJLuaLogDelegate?.logForLuaSkin(atLevel: LS_LOG_WARN, withMessage: message)
}
private func skinLogError(_ skin: LuaSkin, _ message: String) {
    MJLuaLogDelegate?.logForLuaSkin(atLevel: LS_LOG_ERROR, withMessage: message)
}
private func skinLogBreadcrumb(_ skin: LuaSkin, _ message: String) {
    MJLuaLogDelegate?.logForLuaSkin(atLevel: LS_LOG_BREADCRUMB, withMessage: message)
}

// MARK: - Log handler setup

/// Accepts an ObjC block `void(^)(NSString*)` and stores it for log output.
/// The block is received as an opaque pointer because `@_cdecl` cannot express
/// ObjC block types directly. We unsafeBitCast it to the correct Swift type.
@_cdecl("MJLuaSetupLogHandler")
func MJLuaSetupLogHandler(_ blk: UnsafeRawPointer) {
    typealias LogBlock = @convention(block) (NSString) -> Void
    let block = unsafeBitCast(blk, to: LogBlock.self)
    loghandler = { str in block(str as NSString) }
}

// MARK: - Lua C callbacks

/// hs.autoLaunch([state]) -> bool
/// Function
/// Set or display the "Launch on Login" status for Hammerspoon.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not Hammerspoon should be launched automatically when you log into your computer.
///
/// Returns:
///  * True if Hammerspoon is currently (or has just been) set to launch on login or False if Hammerspoon is not.
private func core_autolaunch(_ L: OpaquePointer!) -> Int32 {
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
private func core_menuicon(_ L: OpaquePointer!) -> Int32 {
    if lua_isboolean(L, 1) { MJMenuIconSetVisible(lua_toboolean(L, 1) != 0) }
    lua_pushboolean(L, MJMenuIconVisible() ? 1 : 0)
    return 1
}

// hs.dockIcon -- for historical reasons, this is actually handled by the hs.dockicon module, but a wrapper
// in the lua portion of this (setup.lua) provides an interface to this module which follows the syntax
// conventions used here.

/// hs.consoleOnTop([state]) -> bool
/// Function
/// Set or display whether or not the Hammerspoon console is always on top when visible.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not the Hammerspoon console is always on top when visible.
///
/// Returns:
///  * True if the console is currently set (or has just been) to be always on top when visible or False if it is not.
private func core_consoleontop(_ L: OpaquePointer!) -> Int32 {
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
private func core_openabout(_ L: OpaquePointer!) -> Int32 {
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
private func core_openpreferences(_ L: OpaquePointer!) -> Int32 {
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
private func core_closepreferences(_ L: OpaquePointer!) -> Int32 {
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
private func core_openconsole(_ L: OpaquePointer!) -> Int32 {
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
private func core_closeconsole(_ L: OpaquePointer!) -> Int32 {
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
private func core_open(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    luaSkinCheckArgs(L, LS_TSTRING, LS_TBREAK)

    let path = skin.toNSObject(atIndex: 1) as! String
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
private func core_reload(_ L: OpaquePointer!) -> Int32 {
    DispatchQueue.main.async {
        MJLuaReplace()
    }
    return 0
}

/// hs.processInfo
/// Constant
/// A table containing read-only information about the Hammerspoon application instance currently running.
private func push_hammerAppInfo(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    // Fetch the CPU architecture in use
    var arch = "Unknown"
    var uts = utsname()
    if uname(&uts) == 0 {
        arch = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: uts.machine)) {
                String(cString: $0)
            }
        }
    }

    let bundle = Bundle.main
    let info = bundle.infoDictionary ?? [:]

    let appInfo: [String: Any] = [
        "version": info["CFBundleShortVersionString"] as? String ?? "",
        "build": info["CFBundleVersion"] as? String ?? "",
        "resourcePath": bundle.resourcePath ?? "",
        "bundlePath": bundle.bundlePath,
        "executablePath": bundle.executablePath ?? "",
        "frameworksPath": bundle.privateFrameworksPath ?? "",
        "processID": getpid(),
        "bundleID": bundle.bundleIdentifier ?? "",
        "arch": arch,
        "isRosetta": false,
        // NOTE: __DATE__/__TIME__ are compile-time C macros. In Swift we use a runtime
        // timestamp. For a true compile-time stamp, set this via a build-system #define
        // bridged through the ObjC bridging header.
        "buildTime": MJLuaBuildTimestamp(),
        #if DEBUG
        "debugBuild": true,
        #else
        "debugBuild": false,
        #endif
    ]

    skin.pushNSObject(appInfo as NSDictionary)
    return 1
}

/// Returns a build timestamp string. In ObjC this used __DATE__ ", " __TIME__;
/// the build system should inject a real value. This is a fallback.
private func MJLuaBuildTimestamp() -> String {
    // If the ObjC .m is still compiled alongside, its __DATE__/__TIME__ is canonical.
    // This Swift fallback uses a runtime date as a placeholder.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMM dd yyyy, HH:mm:ss"
    return formatter.string(from: Date())
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
private func core_accessibilityState(_ L: OpaquePointer!) -> Int32 {
    let shouldPrompt = lua_toboolean(L, 1) != 0
    let enabled = MJAccessibilityIsEnabled()
    if shouldPrompt { MJAccessibilityOpenPanel() }
    lua_pushboolean(L, enabled ? 1 : 0)
    return 1
}

// SOURCE: https://stackoverflow.com/a/58985069
private func isScreenRecordingEnabled() -> Bool {
    var canRecordScreen = false
    let runningApplication = NSRunningApplication.current
    let ourProcessIdentifier = NSNumber(value: runningApplication.processIdentifier)

    guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }

    for windowInfo in windowList {
        let windowName = windowInfo[kCGWindowName as String] as? String
        guard let processIdentifier = windowInfo[kCGWindowOwnerPID as String] as? NSNumber else {
            continue
        }

        // don't check windows owned by this process
        if processIdentifier != ourProcessIdentifier {
            let pid = pid_t(processIdentifier.intValue)
            guard let windowRunningApplication = NSRunningApplication(processIdentifier: pid) else {
                // ignore processes we don't have access to, such as WindowServer,
                // which manages the windows named "Menubar" and "Backstop Menubar"
                continue
            }

            let windowExecutableName = windowRunningApplication.executableURL?.lastPathComponent
            if windowName != nil {
                if windowExecutableName == "Dock" {
                    // ignore the Dock, which provides the desktop picture
                    continue
                } else {
                    canRecordScreen = true
                    break
                }
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
private func core_screenRecordingState(_ L: OpaquePointer!) -> Int32 {
    let shouldPrompt = lua_toboolean(L, 1) != 0
    let enabled = isScreenRecordingEnabled()
    if shouldPrompt {
        // CGDisplayStreamCreate is obsoleted in macOS 15 SDK but still works at runtime.
        // We use it only to trigger the screen recording permission prompt.
        typealias CGDisplayStreamCreateFunc = @convention(c) (
            CGDirectDisplayID, Int, Int, Int32, CFDictionary?,
            @escaping @convention(block) (CGDisplayStreamFrameStatus, UInt64, IOSurfaceRef?, CGDisplayStreamUpdate?) -> Void
        ) -> Unmanaged<CGDisplayStream>?

        if let sym = dlsym(nil, "CGDisplayStreamCreate") {
            let createStream = unsafeBitCast(sym, to: CGDisplayStreamCreateFunc.self)
            let stream = createStream(
                CGMainDisplayID(), 1, 1,
                Int32(kCVPixelFormatType_32BGRA),
                nil,
                { _, _, _, _ in }
            )
            // Release the stream if it was created
            stream?.release()
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
private func core_microphoneState(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let shouldPrompt = lua_toboolean(L, 1) != 0

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        lua_pushboolean(L, 1)
    case .notDetermined:
        if shouldPrompt {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    skinLogWarn(skin, "Hammerspoon has been declined Microphone access by the user.")
                }
            }
        }
        lua_pushboolean(L, 0)
    case .denied:
        lua_pushboolean(L, 0)
    case .restricted:
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
private func core_cameraState(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let shouldPrompt = lua_toboolean(L, 1) != 0

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        lua_pushboolean(L, 1)
    case .notDetermined:
        if shouldPrompt {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    skinLogWarn(skin, "Hammerspoon has been declined Camera access by the user.")
                }
            }
        }
        lua_pushboolean(L, 0)
    case .denied:
        lua_pushboolean(L, 0)
    case .restricted:
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
private func preferencesDarkMode(_ L: OpaquePointer!) -> Int32 {
    luaSkinCheckArgs(L, LS_TBOOLEAN_LS | LS_TOPTIONAL, LS_TBREAK)

    if lua_isboolean(L, 1) {
        PreferencesDarkModeSetEnabled(lua_toboolean(L, 1) != 0)
        MJPreferencesWindowController.singleton().perform(Selector(("reflectDefaults")))
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
private func core_appleScript(_ L: OpaquePointer!) -> Int32 {
    luaSkinCheckArgs(L, LS_TBOOLEAN_LS | LS_TOPTIONAL, LS_TBREAK)

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
private func core_openConsoleOnDockClick(_ L: OpaquePointer!) -> Int32 {
    luaSkinCheckArgs(L, LS_TBOOLEAN_LS | LS_TOPTIONAL, LS_TBREAK)

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
private func core_focus(_ L: OpaquePointer!) -> Int32 {
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
private func core_getObjectMetatable(_ L: OpaquePointer!) -> Int32 {
    luaSkinCheckArgs(L, LS_TSTRING, LS_TBREAK)
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
private func core_cleanUTF8(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    luaSkinCheckArgs(L, LS_TANY, LS_TBREAK)
    skin.pushNSObject(skin.getValidUTF8(atIndex: 1) as NSString)
    return 1
}

private func core_exit(_ L: OpaquePointer!) -> Int32 {
    NSApplication.shared.terminate(nil)
    return 0
}

private func core_logmessage(_ L: OpaquePointer!) -> Int32 {
    var len: Int = 0
    guard let s = lua_tolstring(L, 1, &len) else { return 0 }
    var str = String(data: Data(bytes: s, count: len), encoding: .utf8)
    if str == nil {
        _ = core_cleanUTF8(L)
        var cleanLen: Int = 0
        if let cleanS = lua_tolstring(L, -1, &cleanLen) {
            str = String(data: Data(bytes: cleanS, count: cleanLen), encoding: .utf8)
        }
    }
    if let str = str {
        loghandler?(str)
    }
    return 0
}

private func core_notify(_ L: OpaquePointer!) -> Int32 {
    var len: Int = 0
    guard let s = lua_tolstring(L, 1, &len) else { return 0 }
    let str = String(data: Data(bytes: s, count: len), encoding: .utf8) ?? ""
    MJUserNotificationManager.shared().sendNotification(str) {
        MJConsoleWindowController.singleton().showWindow(nil)
    }
    return 0
}

// MARK: - Core library registration table

/// Build the luaL_Reg array for registering core Lua functions.
/// Each entry is a `(name, @convention(c) function pointer)` pair.
/// We use `strdup` so the name pointers remain valid for the lifetime of the process.
private var corelib: [luaL_Reg] = {
    typealias LuaCFunc = @convention(c) (OpaquePointer?) -> Int32

    let preferencesDarkMode_c: LuaCFunc = { L in preferencesDarkMode(L) }
    let openConsoleOnDockClick_c: LuaCFunc = { L in core_openConsoleOnDockClick(L) }
    let openConsole_c: LuaCFunc = { L in core_openconsole(L) }
    let closeConsole_c: LuaCFunc = { L in core_closeconsole(L) }
    let consoleOnTop_c: LuaCFunc = { L in core_consoleontop(L) }
    let openAbout_c: LuaCFunc = { L in core_openabout(L) }
    let menuIcon_c: LuaCFunc = { L in core_menuicon(L) }
    let openPreferences_c: LuaCFunc = { L in core_openpreferences(L) }
    let closePreferences_c: LuaCFunc = { L in core_closepreferences(L) }
    let open_c: LuaCFunc = { L in core_open(L) }
    let autoLaunch_c: LuaCFunc = { L in core_autolaunch(L) }
    let allowAppleScript_c: LuaCFunc = { L in core_appleScript(L) }
    let reload_c: LuaCFunc = { L in core_reload(L) }
    let focus_c: LuaCFunc = { L in core_focus(L) }
    let accessibilityState_c: LuaCFunc = { L in core_accessibilityState(L) }
    let screenRecordingState_c: LuaCFunc = { L in core_screenRecordingState(L) }
    let microphoneState_c: LuaCFunc = { L in core_microphoneState(L) }
    let cameraState_c: LuaCFunc = { L in core_cameraState(L) }
    let getObjectMetatable_c: LuaCFunc = { L in core_getObjectMetatable(L) }
    let cleanUTF8_c: LuaCFunc = { L in core_cleanUTF8(L) }
    let exit_c: LuaCFunc = { L in core_exit(L) }
    let logmessage_c: LuaCFunc = { L in core_logmessage(L) }
    let notify_c: LuaCFunc = { L in core_notify(L) }

    return [
        luaL_Reg(name: strdup("preferencesDarkMode"), func: preferencesDarkMode_c),
        luaL_Reg(name: strdup("openConsoleOnDockClick"), func: openConsoleOnDockClick_c),
        luaL_Reg(name: strdup("openConsole"), func: openConsole_c),
        luaL_Reg(name: strdup("closeConsole"), func: closeConsole_c),
        luaL_Reg(name: strdup("consoleOnTop"), func: consoleOnTop_c),
        luaL_Reg(name: strdup("openAbout"), func: openAbout_c),
        luaL_Reg(name: strdup("menuIcon"), func: menuIcon_c),
        luaL_Reg(name: strdup("openPreferences"), func: openPreferences_c),
        luaL_Reg(name: strdup("closePreferences"), func: closePreferences_c),
        luaL_Reg(name: strdup("open"), func: open_c),
        luaL_Reg(name: strdup("autoLaunch"), func: autoLaunch_c),
        luaL_Reg(name: strdup("allowAppleScript"), func: allowAppleScript_c),
        luaL_Reg(name: strdup("reload"), func: reload_c),
        luaL_Reg(name: strdup("focus"), func: focus_c),
        luaL_Reg(name: strdup("accessibilityState"), func: accessibilityState_c),
        luaL_Reg(name: strdup("screenRecordingState"), func: screenRecordingState_c),
        luaL_Reg(name: strdup("microphoneState"), func: microphoneState_c),
        luaL_Reg(name: strdup("cameraState"), func: cameraState_c),
        luaL_Reg(name: strdup("getObjectMetatable"), func: getObjectMetatable_c),
        luaL_Reg(name: strdup("cleanUTF8forConsole"), func: cleanUTF8_c),
        luaL_Reg(name: strdup("_exit"), func: exit_c),
        luaL_Reg(name: strdup("_logmessage"), func: logmessage_c),
        luaL_Reg(name: strdup("_notify"), func: notify_c),
        luaL_Reg(name: nil, func: nil), // sentinel
    ]
}()

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

private let MJLuaAtPanic_c: @convention(c) (OpaquePointer?) -> Int32 = { L in
    NSLog("LUA_AT_PANIC: %@", String(cString: lua_tostring(L, -1) ?? "unknown"))
    if let oldPanic = oldPanicFunction {
        return oldPanic(L)
    }
    return 0
}

/// Create a Lua environment with LuaSkin
@_cdecl("MJLuaAlloc")
func MJLuaAlloc() {
    if MJLuaLogDelegate == nil {
        MJLuaLogDelegate = HSLogger(lua: nil)
    }
    var skin = LuaSkin.shared(withDelegate: MJLuaLogDelegate)
    // on a reload, this won't get created in sharedWithDelegate:, so do it manually here
    if LuaSkin.mainLuaState() == nil {
        skin.createLuaState()
        skin.delegate = MJLuaLogDelegate
        // FIXME: Is this needed?
        // ANS: since a new delegate object is created here, yes because LuaSkin's initWithDelegate
        // isn't called, so the new delegate isn't assigned. Should consider whether or not we
        // really need to create new object but that's for another day...

        // make sure skin.L points to the main state since we just created a new one
        skin = LuaSkin.shared(withState: nil)
    }
    MJLuaLogDelegate?.setLuaState(skin.l)
    oldPanicFunction = lua_atpanic(skin.l, MJLuaAtPanic_c)
}

/// Configure a Lua environment that has already been created by LuaSkin
@_cdecl("MJLuaInit")
func MJLuaInit() {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.l!

    refTable = skin.registerLibrary("core", functions: &corelib, metaFunctions: nil)
    _ = push_hammerAppInfo(L)
    lua_setfield(L, -2, "processInfo")

    lua_setglobal(L, "hs")

    // Register every bundled hs.lib<name> entry point into package.preload before setup.lua runs.
    HSExtensionsRegisterAll(L)

    guard let setupPath = Bundle.main.path(forResource: "setup", ofType: "lua") else {
        NSLog("Unable to find setup.lua in bundle. Terminating")
        showCriticalAlert(
            message: "Hammerspoon installation is corrupted",
            informative: "Please re-install Hammerspoon"
        )
        NSApplication.shared.terminate(nil)
        return
    }

    let loadResult = luaL_loadfile(L, (setupPath as NSString).fileSystemRepresentation)
    if loadResult != 0 {
        NSLog("Unable to load setup.lua from bundle. Terminating")
        showCriticalAlert(
            message: "Hammerspoon installation is corrupted",
            informative: "Please re-install Hammerspoon"
        )
        NSApplication.shared.terminate(nil)
        return
    }

    if let extensionsPath = Bundle.main.path(forResource: "extensions", ofType: nil) {
        lua_pushstring(L, (extensionsPath as NSString).fileSystemRepresentation)
    } else {
        lua_pushstring(L, "")
    }
    lua_pushstring(L, (MJConfigFile as NSString).utf8String)
    lua_pushstring(L, (MJConfigFileFullPath() as NSString).utf8String)
    lua_pushstring(L, (MJConfigDir() as NSString).utf8String)
    if let docsPath = Bundle.main.path(forResource: "docs", ofType: "json") {
        lua_pushstring(L, (docsPath as NSString).fileSystemRepresentation)
    } else {
        lua_pushstring(L, "")
    }
    lua_pushboolean(L, FileManager.default.fileExists(atPath: MJConfigFileFullPath()) ? 1 : 0)
    lua_pushboolean(L, UserDefaults.standard.bool(forKey: "HSAutoLoadExtensions") ? 1 : 0)

    if lua_pcall(L, 7, 2, 0) != LUA_OK {
        let errorMessage = String(cString: lua_tostring(L, -1))
        lua_pop(L, 1)
        NSLog("Error running setup.lua:%@", errorMessage)
        showCriticalAlert(
            message: "Hammerspoon initialization failed",
            informative: errorMessage
        )
    } else {
        if lua_gettop(L) != 2 || lua_type(L, -1) != LUA_TFUNCTION || lua_type(L, -2) != LUA_TFUNCTION {
            let debugPart = String(
                format: "setup.lua returned this: %d:%d:%d",
                lua_gettop(L),
                lua_gettop(L) >= 1 ? lua_type(L, -1) : -10,
                lua_gettop(L) >= 2 ? lua_type(L, -2) : -10
            )

            let errorMessage = """
                setup.lua failed to return the two items it is supposed to.
                This is a severe bug. We would really appreciate your help in getting this fixed \
                - please relaunch Hammerspoon so a crash report can be uploaded, then contact the \
                Hammerspoon developers via GitHub.
                """
            showCriticalAlert(
                message: "Critical startup failure bug",
                informative: errorMessage
            )

            skinLogBreadcrumb(skin, "setup.lua returned incorrectly: \(debugPart)")

            // Fall through this, so we crash, so we can get the crash report
        }
        evalfn = skin.luaRef(refTable)
        completionsForWordFn = skin.luaRef(refTable)
        skinLogBreadcrumb(skin, "setup.lua completed")
    }
}

// MARK: - Callbacks

/// Accessibility State Callback
@_cdecl("callAccessibilityStateCallback")
func callAccessibilityStateCallback() {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.l!
    let stackEntry = lua_gettop(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "accessibilityStateCallback")

    if lua_type(L, -1) == LUA_TNIL {
        lua_pop(L, 1)
    } else {
        skin.protectedCallAndError("hs.callAccessibilityStateCallback", nargs: 0, nresults: 0)
    }

    lua_pop(L, 1)
    assert(stackEntry == lua_gettop(L))
}

/// Text Dropped to Dock Icon Callback
@_cdecl("textDroppedToDockIcon")
func textDroppedToDockIcon(_ pboardString: NSString) {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.l!
    let stackEntry = lua_gettop(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "textDroppedToDockIconCallback")

    if lua_type(L, -1) == LUA_TNIL {
        lua_pop(L, 1)
    } else {
        skin.pushNSObject(pboardString)
        skin.protectedCallAndError("hs.textDroppedToDockIconCallback", nargs: 1, nresults: 0)
    }

    lua_pop(L, 1)
    assert(stackEntry == lua_gettop(L))
}

/// File Dropped to Dock Icon Callback
@_cdecl("fileDroppedToDockIcon")
func fileDroppedToDockIcon(_ filePath: NSString) {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.l!
    let stackEntry = lua_gettop(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "fileDroppedToDockIconCallback")

    if lua_type(L, -1) == LUA_TNIL {
        lua_pop(L, 1)
    } else {
        skin.pushNSObject(filePath)
        skin.protectedCallAndError("hs.fileDroppedToDockIconCallback", nargs: 1, nresults: 0)
    }

    lua_pop(L, 1)
    assert(stackEntry == lua_gettop(L))
}

/// Dock Icon Click Callback
@_cdecl("callDockIconCallback")
func callDockIconCallback() {
    let skin = LuaSkin.shared(withState: nil)
    guard let L = skin.l else {
        // It seems to be possible that NSApplicationDelegate:applicationShouldHandleReopen can be
        // called before a Lua state has been created. We need to bail out immediately or we'll
        // cause a crash.
        return
    }

    let stackEntry = lua_gettop(L)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "dockIconClickCallback")

    if lua_type(L, -1) == LUA_TNIL {
        lua_pop(L, 1)
    } else {
        skin.protectedCallAndError("hs.dockIconClickCallback", nargs: 0, nresults: 0)
    }

    lua_pop(L, 1)
    assert(stackEntry == lua_gettop(L))
}

/// Shutdown Callback
private func callShutdownCallback(_ L: OpaquePointer) {
    let skin = LuaSkin.shared(withState: L)
    let stackEntry = lua_gettop(skin.l)

    lua_getglobal(L, "hs")
    lua_getfield(L, -1, "shutdownCallback")

    if lua_type(L, -1) == LUA_TNIL {
        lua_pop(L, 1)
    } else {
        skin.protectedCallAndError("hs.shutdownCallback", nargs: 0, nresults: 0)
    }

    lua_pop(L, 1)
    assert(stackEntry == lua_gettop(skin.l))
}

/// Deconfigure a Lua environment that will shortly be destroyed by LuaSkin
@_cdecl("MJLuaDeinit")
func MJLuaDeinit() {
    let skin = LuaSkin.shared(withState: nil)
    callShutdownCallback(skin.l)
    MJLuaLogDelegate?.setLuaState(nil)
}

/// Destroy a Lua environment with LuaSkin
@_cdecl("MJLuaDealloc")
func MJLuaDealloc() {
    let skin = LuaSkin.shared(withState: nil)
    skin.destroyLuaState()
}

// MARK: - Public API

@_cdecl("MJLuaRunString")
func MJLuaRunString(_ command: NSString) -> NSString {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.l!
    let stackEntry = lua_gettop(L)

    skin.pushLuaRef(refTable, ref: evalfn)
    if !lua_isfunction(L, -1) {
        NSLog("ERROR: MJLuaRunString doesn't seem to have an evalfn")
        if lua_isstring(L, -1) != 0 {
            NSLog("evalfn appears to be a string: %s", lua_tostring(L, -1) ?? "")
        }
        lua_pop(L, 1)
        assert(stackEntry == lua_gettop(L))
        return "" as NSString
    }
    lua_pushstring(L, (command as String).cString(using: .utf8))
    if !skin.protectedCallAndTraceback(1, nresults: 1) {
        if let errorMsg = lua_tostring(L, -1) {
            skinLogError(skin, String(cString: errorMsg))
        }
    }

    var len: Int = 0
    let s = lua_tolstring(L, -1, &len)
    var str: String?
    if let s = s {
        str = String(data: Data(bytes: s, count: len), encoding: .utf8)
        if str == nil {
            let unsignedS = UnsafeRawPointer(s).assumingMemoryBound(to: UInt8.self)
            str = skin.getValidUTF8(unsignedS, ofLength: len)
        }
    }
    lua_pop(L, 1)

    assert(stackEntry == lua_gettop(L))
    return (str ?? "") as NSString
}

@_cdecl("MJLuaCompletionsForWord")
func MJLuaCompletionsForWord(_ completionWord: NSString) -> NSArray {
    let skin = LuaSkin.shared(withState: nil)
    let stackEntry = lua_gettop(skin.l)

    skin.pushLuaRef(refTable, ref: completionsForWordFn)
    skin.pushNSObject(completionWord)
    if !skin.protectedCallAndError("MJLuaCompletionsForWord", nargs: 1, nresults: 1) {
        assert(stackEntry == lua_gettop(skin.l))
        return [] as NSArray
    }

    let completions = skin.toNSObject(atIndex: -1) as? NSArray ?? [] as NSArray
    lua_pop(skin.l, 1)
    assert(stackEntry == lua_gettop(skin.l))
    return completions
}

/// C-Code helper to return current active LuaState. Useful for callbacks to
/// verify stored LuaState still matches active one if GC fails to clear it.
@_cdecl("MJGetActiveLuaState")
func MJGetActiveLuaState() -> OpaquePointer? {
    let skin = LuaSkin.shared(withState: nil)
    return skin.l
}

@_cdecl("MJFindInitFile")
func MJFindInitFile() -> NSString? {
    let fullPath = MJConfigFileFullPath()
    if FileManager.default.fileExists(atPath: fullPath) {
        return fullPath as NSString
    }
    return nil
}

// MARK: - Helpers

private func showCriticalAlert(message: String, informative: String) {
    let alert = NSAlert()
    alert.addButton(withTitle: "OK")
    alert.messageText = message
    alert.informativeText = informative
    alert.alertStyle = .critical
    alert.runModal()
}
