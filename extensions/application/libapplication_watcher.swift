import Foundation
import Cocoa
import LuaSkin

/// === hs.application.watcher ===
///
/// Watch for application launch/terminate events
///
/// This module is based primarily on code from the previous incarnation of Mjolnir by [Markus Engelbrecht](https://github.com/mgee).

/// hs.application.watcher.launching
/// Constant
/// An application is in the process of being launched

/// hs.application.watcher.launched
/// Constant
/// An application has been launched

/// hs.application.watcher.terminated
/// Constant
/// An application has been terminated

/// hs.application.watcher.hidden
/// Constant
/// An application has been hidden

/// hs.application.watcher.unhidden
/// Constant
/// An application has been unhidden

/// hs.application.watcher.activated
/// Constant
/// An application has been activated (i.e. given keyboard/mouse focus)

/// hs.application.watcher.deactivated
/// Constant
/// An application has been deactivated (i.e. lost keyboard/mouse focus)

// MARK: - Common Code

private let USERDATA_TAG = "hs.application.watcher"
private var refTable: LSRefTable = 0

// MARK: - Types

private struct AppWatcherData {
    var running: Bool
    var fn: Int32
    var obj: UnsafeMutableRawPointer?   // Retains the AppWatcher NSObject
}

private enum AppEvent: Int {
    case launching   = 0
    case launched    = 1
    case terminated  = 2
    case hidden      = 3
    case unhidden    = 4
    case activated   = 5
    case deactivated = 6
}

// MARK: - AppWatcher Observer

private class AppWatcher: NSObject {
    unowned(unsafe) var object: UnsafeMutablePointer<AppWatcherData>

    init(object: UnsafeMutablePointer<AppWatcherData>) {
        self.object = object
        super.init()
    }

    // Call the lua callback function and pass the application name and event type.
    func callback(dict: [AnyHashable: Any], event: AppEvent) {
        guard let app = dict["NSWorkspaceApplicationKey"] as? NSRunningApplication else { return }
        guard object.pointee.running else { return }

        let skin = LuaSkin.shared(withState: nil)
        guard let L = skin.L else { return }
        let stackGuardEntry = lua_gettop(L)

        // Depending on the event the name of the NSRunningApplication object may not be available
        // anymore. Fallback to the application name which is provided directly in the notification
        // object.
        var appName = app.localizedName
        if appName == nil {
            appName = dict["NSApplicationName"] as? String
        }

        skin.pushLuaRef(refTable, ref: object.pointee.fn)

        if let name = appName {
            lua_pushstring(L, name)                         // Parameter 1: application name
        } else {
            lua_pushnil(L)
        }

        lua_pushinteger(L, lua_Integer(event.rawValue))     // Parameter 2: the event type

        let application = HSapplication(forNSRunningApplication: app, withState: L)
        skin.pushNSObject(application)

        skin.protectedCallAndError("hs.application.watcher callback", nargs: 3, nresults: 0)
        assert(stackGuardEntry == lua_gettop(L))
    }

    @objc func applicationWillLaunch(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .launching) }
    }

    @objc func applicationLaunched(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .launched) }
    }

    @objc func applicationTerminated(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .terminated) }
    }

    @objc func applicationHidden(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .hidden) }
    }

    @objc func applicationUnhidden(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .unhidden) }
    }

    @objc func applicationActivated(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .activated) }
    }

    @objc func applicationDeactivated(_ notification: Notification) {
        if let userInfo = notification.userInfo { callback(dict: userInfo, event: .deactivated) }
    }
}

// MARK: - Observer Registration

/// Register the AppWatcher as observer for application specific events.
private func registerObserver(_ observer: AppWatcher) {
    // It is crucial to use the shared workspace notification center here.
    // Otherwise we will not receive the events we are interested in.
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(observer, selector: #selector(AppWatcher.applicationWillLaunch(_:)),
                       name: NSWorkspace.willLaunchApplicationNotification, object: nil)
    center.addObserver(observer, selector: #selector(AppWatcher.applicationLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    center.addObserver(observer, selector: #selector(AppWatcher.applicationTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    center.addObserver(observer, selector: #selector(AppWatcher.applicationHidden(_:)),
                       name: NSWorkspace.didHideApplicationNotification, object: nil)
    center.addObserver(observer, selector: #selector(AppWatcher.applicationUnhidden(_:)),
                       name: NSWorkspace.didUnhideApplicationNotification, object: nil)
    center.addObserver(observer, selector: #selector(AppWatcher.applicationActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
    center.addObserver(observer, selector: #selector(AppWatcher.applicationDeactivated(_:)),
                       name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
}

/// Unregister the AppWatcher as observer for all events.
private func unregisterObserver(_ observer: AppWatcher) {
    let center = NSWorkspace.shared.notificationCenter
    center.removeObserver(observer, name: NSWorkspace.willLaunchApplicationNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didHideApplicationNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didUnhideApplicationNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didActivateApplicationNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
}

// MARK: - Lua C Functions

/// hs.application.watcher.new(fn) -> watcher
/// Constructor
/// Creates an application event watcher
///
/// Parameters:
///  * fn - A function that will be called when application events happen. It should accept three parameters:
///   * A string containing the name of the application
///   * An event type (see the constants defined above)
///   * An `hs.application` object representing the application, or nil if the application couldn't be found
///
/// Returns:
///  * An `hs.application.watcher` object
///
/// Notes:
///  * If the function is called with an event type of `hs.application.watcher.terminated` then the application name parameter will be `nil` and the `hs.application` parameter, will only be useful for getting the UNIX process ID (i.e. the PID) of the application
private func app_watcher_new(_ L: OpaquePointer?) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    luaL_checktype(L, 1, LUA_TFUNCTION)

    let ptr = lua_newuserdata(L, MemoryLayout<AppWatcherData>.size)!
    let appWatcher = ptr.bindMemory(to: AppWatcherData.self, capacity: 1)
    appWatcher.initialize(to: AppWatcherData(running: false, fn: 0, obj: nil))

    lua_pushvalue(L, 1)
    appWatcher.pointee.fn = skin.luaRef(refTable)

    let observer = AppWatcher(object: appWatcher)
    appWatcher.pointee.obj = Unmanaged.passRetained(observer).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

/// hs.application.watcher:start()
/// Method
/// Starts the application watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.application.watcher` object
private func app_watcher_start(_ L: OpaquePointer?) -> Int32 {
    guard let ptr = luaL_checkudata(L, 1, USERDATA_TAG) else { return 0 }
    let appWatcher = ptr.bindMemory(to: AppWatcherData.self, capacity: 1)
    lua_settop(L, 1)

    if appWatcher.pointee.running { return 0 }

    appWatcher.pointee.running = true
    let observer = Unmanaged<AppWatcher>.fromOpaque(appWatcher.pointee.obj!).takeUnretainedValue()
    registerObserver(observer)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.application.watcher:stop()
/// Method
/// Stops the application watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.application.watcher` object
private func app_watcher_stop(_ L: OpaquePointer?) -> Int32 {
    guard let ptr = luaL_checkudata(L, 1, USERDATA_TAG) else { return 0 }
    let appWatcher = ptr.bindMemory(to: AppWatcherData.self, capacity: 1)
    lua_settop(L, 1)

    if !appWatcher.pointee.running { return 0 }

    appWatcher.pointee.running = false
    let observer = Unmanaged<AppWatcher>.fromOpaque(appWatcher.pointee.obj!).takeUnretainedValue()
    unregisterObserver(observer)

    lua_pushvalue(L, 1)
    return 1
}

// Perform cleanup if the AppWatcher is not required anymore.
private func app_watcher_gc(_ L: OpaquePointer?) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    guard let ptr = luaL_checkudata(L, 1, USERDATA_TAG) else { return 0 }
    let appWatcher = ptr.bindMemory(to: AppWatcherData.self, capacity: 1)

    _ = app_watcher_stop(L)

    appWatcher.pointee.fn = skin.luaUnref(refTable, ref: appWatcher.pointee.fn)

    if let obj = appWatcher.pointee.obj {
        // Release the retained AppWatcher object
        Unmanaged<AppWatcher>.fromOpaque(obj).release()
        appWatcher.pointee.obj = nil
    }
    return 0
}

private func userdata_tostring(_ L: OpaquePointer?) -> Int32 {
    let description = String(format: "%s: (%p)", USERDATA_TAG, lua_topointer(L, 1)!)
    lua_pushstring(L, description)
    return 1
}

private func meta_gc(_ L: OpaquePointer?) -> Int32 {
    return 0
}

// MARK: - Event Enum Registration

/// Add a single event enum value to the lua table.
private func addEventValue(_ L: OpaquePointer?, value: AppEvent, name: String) {
    lua_pushinteger(L, lua_Integer(value.rawValue))
    lua_setfield(L, -2, name)
}

/// Add the event_t enum to the lua table.
private func addEventEnum(_ L: OpaquePointer?) {
    addEventValue(L, value: .launching,   name: "launching")
    addEventValue(L, value: .launched,    name: "launched")
    addEventValue(L, value: .terminated,  name: "terminated")
    addEventValue(L, value: .hidden,      name: "hidden")
    addEventValue(L, value: .unhidden,    name: "unhidden")
    addEventValue(L, value: .activated,   name: "activated")
    addEventValue(L, value: .deactivated, name: "deactivated")
}

// MARK: - luaL_Reg Tables

// Metatable for created objects when _new invoked
private let metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: app_watcher_start),
    luaL_Reg(name: strdup("stop"),       func: app_watcher_stop),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"),       func: app_watcher_gc),
    luaL_Reg(name: nil,                  func: nil),
]

// Functions for returned object when module loads
private let appLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: app_watcher_new),
    luaL_Reg(name: nil,           func: nil),
]

// Metatable for returned object when module loads
private let metaGcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

// MARK: - Module Entry Point

/// Called when loading the module. All necessary tables need to be registered here.
@_cdecl("luaopen_hs_libapplicationwatcher")
func luaopen_hs_libapplicationwatcher(_ L: OpaquePointer?) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibraryWithObject(
        USERDATA_TAG,
        functions: appLib,
        metaFunctions: metaGcLib,
        objectFunctions: metaLib
    )

    addEventEnum(L)

    return 1
}
