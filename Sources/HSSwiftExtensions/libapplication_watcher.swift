import Cocoa
import LuaSkin

// MARK: - Module constants

private let USERDATA_TAG = "hs.application.watcher"
private var refTable: LSRefTable = LUA_NOREF

// Event type enum matching the ObjC original
private enum AppWatcherEvent: Int {
    case launching   = 0
    case launched    = 1
    case terminated  = 2
    case hidden      = 3
    case unhidden    = 4
    case activated   = 5
    case deactivated = 6
}

// MARK: - AppWatcher class

private class AppWatcher: NSObject {
    var running: Bool = false
    var callbackRef: Int32 = LUA_NOREF

    func callback(_ dict: [AnyHashable: Any], event: AppWatcherEvent) {
        guard let app = dict["NSWorkspaceApplicationKey" as NSString] as? NSRunningApplication else { return }
        guard running else { return }

        let skin = LuaSkin.skin(with: nil)
        guard let L = skin.l else { return }

        // Depending on the event the name of the NSRunningApplication may not be available anymore.
        // Fallback to the application name provided directly in the notification dict.
        var appName = app.localizedName
        if appName == nil {
            appName = dict["NSApplicationName" as NSString] as? String
        }

        skin.pushLuaRef(refTable, ref: callbackRef)

        if let name = appName {
            lua_pushstring(L, name)
        } else {
            lua_pushnil(L)
        }

        lua_pushinteger(L, lua_Integer(event.rawValue))

        // Create HSapplication via NSClassFromString + perform selector
        if let appClass = HSuicore.applicationClass {
            let application = (appClass as AnyObject).perform(
                Selector(("applicationForNSRunningApplication:withState:")),
                with: app,
                with: L
            )?.takeUnretainedValue()
            skin.pushNSObject(application)
        } else {
            lua_pushnil(L)
        }

        skin.protectedCallAndError("hs.application.watcher callback", nargs: 3, nresults: 0)
    }

    func registerObserver() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationWillLaunch(_:)),
                           name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationHidden(_:)),
                           name: NSWorkspace.didHideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationUnhidden(_:)),
                           name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDeactivated(_:)),
                           name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
    }

    func unregisterObserver() {
        let center = NSWorkspace.shared.notificationCenter
        center.removeObserver(self, name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didHideApplicationNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
    }

    @objc private func applicationWillLaunch(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .launching)
    }
    @objc private func applicationLaunched(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .launched)
    }
    @objc private func applicationTerminated(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .terminated)
    }
    @objc private func applicationHidden(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .hidden)
    }
    @objc private func applicationUnhidden(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .unhidden)
    }
    @objc private func applicationActivated(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .activated)
    }
    @objc private func applicationDeactivated(_ notification: Notification) {
        callback((notification.userInfo ?? [:]) as [AnyHashable: Any], event: .deactivated)
    }
}

// MARK: - Helper to extract watcher from userdata

private func getWatcher(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AppWatcher? {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(rawPtr).takeUnretainedValue() as? AppWatcher
}

// MARK: - Lua functions

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
private func app_watcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let watcher = AppWatcher()

    lua_pushvalue(L, 1)
    watcher.callbackRef = skin.luaRef(refTable)
    watcher.running = false

    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(watcher as AnyObject).toOpaque()

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
private func app_watcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let watcher = getWatcher(L, at: 1) else { return 0 }
    lua_settop(L, 1)

    if watcher.running { return 1 }

    watcher.running = true
    watcher.registerObserver()

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
private func app_watcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let watcher = getWatcher(L, at: 1) else { return 0 }
    lua_settop(L, 1)

    if !watcher.running { return 1 }

    watcher.running = false
    watcher.unregisterObserver()

    lua_pushvalue(L, 1)
    return 1
}

private func app_watcher_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let watcher = Unmanaged<AnyObject>.fromOpaque(rawPtr).takeRetainedValue() as! AppWatcher
        watcher.running = false
        watcher.unregisterObserver()
        watcher.callbackRef = skin.luaUnref(refTable, ref: watcher.callbackRef)
        ptr.pointee = nil
    }
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, desc)
    return 1
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

// MARK: - Event enum registration

private func add_event_enum(_ L: UnsafeMutablePointer<lua_State>!) {
    let events: [(String, AppWatcherEvent)] = [
        ("launching",   .launching),
        ("launched",    .launched),
        ("terminated",  .terminated),
        ("hidden",      .hidden),
        ("unhidden",    .unhidden),
        ("activated",   .activated),
        ("deactivated", .deactivated),
    ]
    for (name, value) in events {
        lua_pushinteger(L, lua_Integer(value.rawValue))
        lua_setfield(L, -2, name)
    }
}

// MARK: - Registration tables

private let appLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: app_watcher_new),
    luaL_Reg(name: nil, func: nil),
]

private let metaGcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

private let metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: app_watcher_start),
    luaL_Reg(name: strdup("stop"),       func: app_watcher_stop),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"),       func: app_watcher_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libapplicationwatcher")
public func luaopen_hs_libapplicationwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: appLib,
                                    metaFunctions: metaGcLib,
                                    objectFunctions: metaLib)
    add_event_enum(L)
    return 1
}
