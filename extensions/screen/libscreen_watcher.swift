import Foundation
import Cocoa
import LuaSkin

/// === hs.screen.watcher ===
///
/// Watch for screen layout changes
/// This could be the addition or removal of a monitor, a screen resolution change, movement of a monitor in the Display preferences pane, etc.
///
/// Note that screen events which happen while your Mac is suspended, may not trigger the watcher in various circumstances (e.g. if you have FileVault enabled and the machine resumes out of hibernation - the screen events will be happening before the drive is unlocked and will not be reported to Hammerspoon)
///
/// This module is based primarily on code from the previous incarnation of Mjolnir.

private let USERDATA_TAG = "hs.screen.watcher"
private var refTable: LSRefTable = 0

// MARK: - MJScreenWatcher

private class MJScreenWatcher: NSObject {
    var fn: Int32 = LUA_NOREF
    var includeActive: Bool = false

    @objc func _screensChanged(_ note: Notification) {
        performSelector(onMainThread: #selector(screensChanged(_:)), with: note, waitUntilDone: true)
    }

    @objc func screensChanged(_ note: Notification) {
        guard fn != LUA_NOREF else { return }

        let skin = LuaSkin.skin(with: nil)
        let L = skin.l
        _lua_stackguard_entry(L)

        let argCount: Int32 = includeActive ? 1 : 0

        skin.pushLuaRef(refTable, ref: Int32(fn))
        if includeActive {
            if note.name.rawValue == "NSWorkspaceActiveDisplayDidChangeNotification" {
                lua_pushboolean(L, 1)
            } else {
                lua_pushnil(L)
            }
        }
        skin.protectedCallAndError("hs.screen.watcher callback", nargs: argCount, nresults: 0)
        _lua_stackguard_exit(L)
    }
}

// MARK: - screenwatcher_t struct

private struct ScreenWatcherData {
    var running: Bool
    var fn: Int32
    var obj: UnsafeMutableRawPointer?
}

// MARK: - Lua callbacks

/// hs.screen.watcher.new(fn) -> watcher
/// Constructor
/// Creates a new screen-watcher.
///
/// Parameters:
///  * The function to be called when a change in the screen layout occurs.  This function should take no arguments.
///
/// Returns:
///  * An `hs.screen.watcher` object
///
/// Notes:
///  * A screen layout change usually involves a change that is made from the Displays Preferences Panel or when a monitor is attached or removed. It can also be caused by a change in the Dock size or presence.
private func screen_watcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    luaL_checktype(L, 1, LUA_TFUNCTION)

    let ptr = lua_newuserdata(L, MemoryLayout<ScreenWatcherData>.size)!
    let watcher = ptr.assumingMemoryBound(to: ScreenWatcherData.self)
    memset(ptr, 0, MemoryLayout<ScreenWatcherData>.size)

    lua_pushvalue(L, 1)
    let fnRef = skin.luaRef(refTable)

    let object = MJScreenWatcher()
    object.fn = Int32(fnRef)
    object.includeActive = false

    watcher.pointee.fn = Int32(fnRef)
    watcher.pointee.obj = Unmanaged.passRetained(object).toOpaque()
    watcher.pointee.running = false

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.screen.watcher.newWithActiveScreen(fn) -> watcher
/// Constructor
/// Creates a new screen-watcher that is also called when the active screen changes.
///
/// Parameters:
///  * The function to be called when a change in the screen layout or active screen occurs.  This function can optionally take one argument, a boolean which will indicate if the change was due to a screen layout change (nil) or because the active screen changed (true).
///
/// Returns:
///  * An `hs.screen.watcher` object
///
/// Notes:
///  * A screen layout change usually involves a change that is made from the Displays Preferences Panel or when a monitor is attached or removed. It can also be caused by a change in the Dock size or presence.
///    * `nil` was chosen instead of `false` for the argument type when this type of change occurs to more closely match the previous behavior of having no argument passed to the callback function.
///  * An active screen change indicates that the focused or main screen has changed when the user has "Displays have separate spaces" checked in the Mission Control Preferences Panel (the focused display is the display which has the active window and active menubar).
///    * Detecting a change in the active display relies on watching for the `NSWorkspaceActiveDisplayDidChangeNotification` message which is not documented by Apple.  While this message has been around at least since OS X 10.9, because it is undocumented, we cannot be positive that Apple won't remove it in a future OS X update.  Because this watcher works by listening for posted messages, should Apple remove this notification, your callback function will no longer receive messages about this change -- it won't crash or change behavior in any other way.  This documentation will be updated if this status changes.
///  * Plugging in or unplugging a monitor can cause both a screen layout callback and an active screen change callback.
private func screen_watcher_new_with_active_screen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    lua_pushcfunction(L, screen_watcher_new)
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)

    let ptr = luaL_checkudata(L, -1, USERDATA_TAG)!.assumingMemoryBound(to: ScreenWatcherData.self)
    let object = Unmanaged<MJScreenWatcher>.fromOpaque(ptr.pointee.obj!).takeUnretainedValue()
    object.includeActive = true

    return 1
}

/// hs.screen.watcher:start() -> watcher
/// Method
/// Starts the screen watcher, making it so fn is called each time the screen arrangement changes
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.screen.watcher` object
private func screen_watcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: ScreenWatcherData.self)
    lua_settop(L, 1)

    if ptr.pointee.running { return 1 }
    ptr.pointee.running = true

    let object = Unmanaged<MJScreenWatcher>.fromOpaque(ptr.pointee.obj!).takeUnretainedValue()

    NotificationCenter.default.addObserver(object,
                                           selector: #selector(MJScreenWatcher._screensChanged(_:)),
                                           name: NSApplication.didChangeScreenParametersNotification,
                                           object: nil)

    if object.includeActive {
        NSWorkspace.shared.notificationCenter.addObserver(object,
                                                          selector: #selector(MJScreenWatcher._screensChanged(_:)),
                                                          name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                                                          object: nil)
    }

    return 1
}

/// hs.screen.watcher:stop() -> watcher
/// Method
/// Stops the screen watcher's fn from getting called until started again
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.screen.watcher` object
private func screen_watcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: ScreenWatcherData.self)
    lua_settop(L, 1)

    if !ptr.pointee.running { return 1 }
    ptr.pointee.running = false

    let object = Unmanaged<MJScreenWatcher>.fromOpaque(ptr.pointee.obj!).takeUnretainedValue()

    NotificationCenter.default.removeObserver(object,
                                              name: NSApplication.didChangeScreenParametersNotification,
                                              object: nil)

    if object.includeActive {
        NSWorkspace.shared.notificationCenter.removeObserver(object,
                                                             name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                                                             object: nil)
    }

    return 1
}

private func screen_watcher_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: ScreenWatcherData.self)

    lua_pushcfunction(L, screen_watcher_stop)
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)

    skin.luaUnref(refTable, ref: ptr.pointee.fn)

    if let obj = ptr.pointee.obj {
        let _ = Unmanaged<MJScreenWatcher>.fromOpaque(obj).takeRetainedValue()
        ptr.pointee.obj = nil
    }

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let str = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, str)
    return 1
}

// MARK: - luaL_Reg tables

private var screen_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"), func: screen_watcher_start),
    luaL_Reg(name: strdup("stop"), func: screen_watcher_stop),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: screen_watcher_gc),
    luaL_Reg(name: nil, func: nil),
]

private var screenLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: screen_watcher_new),
    luaL_Reg(name: strdup("newWithActiveScreen"), func: screen_watcher_new_with_active_screen),
    luaL_Reg(name: nil, func: nil),
]

private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libscreenwatcher")
public func luaopen_hs_libscreenwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG, functions: &screenLib, metaFunctions: &meta_gcLib, objectFunctions: &screen_metalib)

    return 1
}
