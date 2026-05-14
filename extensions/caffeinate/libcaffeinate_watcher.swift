import Foundation
import Cocoa
import LuaSkin

/// === hs.caffeinate.watcher ===
///
/// Watch for display and system sleep/wake/power events
/// and for fast user switching session events.
///
/// This module is based primarily on code from the previous incarnation of Mjolnir.

/// hs.caffeinate.watcher.systemDidWake
/// Constant
/// The system woke from sleep

/// hs.caffeinate.watcher.systemWillSleep
/// Constant
/// The system is preparing to sleep

/// hs.caffeinate.watcher.systemWillPowerOff
/// Constant
/// The user requested a logout or shutdown

/// hs.caffeinate.watcher.screensDidSleep
/// Constant
/// The displays have gone to sleep

/// hs.caffeinate.watcher.screensDidWake
/// Constant
/// The displays have woken from sleep

/// hs.caffeinate.watcher.sessionDidResignActive
/// Constant
/// The session is no longer active, due to fast user switching

/// hs.caffeinate.watcher.sessionDidBecomeActive
/// Constant
/// The session became active, due to fast user switching

/// hs.caffeinate.watcher.screensaverDidStart
/// Constant
/// The screensaver started

/// hs.caffeinate.watcher.screensaverWillStop
/// Constant
/// The screensaver is about to stop

/// hs.caffeinate.watcher.screensaverDidStop
/// Constant
/// The screensaver stopped

/// hs.caffeinate.watcher.screensDidLock
/// Constant
/// The screen was locked

/// hs.caffeinate.watcher.screensDidUnlock
/// Constant
/// The screen was unlocked

// MARK: - Common Code

private let USERDATA_TAG = "hs.caffeinate.watcher"
private var refTable: LSRefTable = 0

// MARK: - Userdata struct

private struct CaffeinateWatcherData {
    var running: Bool
    var fn: Int32
    var obj: UnsafeMutableRawPointer?  // Retained reference to CaffeinateWatcher
    var lsCanary: LSGCCanary
}

// MARK: - Event enum

private enum CaffeinateEvent: Int {
    case didWake = 0
    case willSleep
    case willPowerOff
    case screensDidSleep
    case screensDidWake
    case sessionDidResignActive
    case sessionDidBecomeActive
    case screensaverDidStart
    case screensaverWillStop
    case screensaverDidStop
    case screensDidLock
    case screensDidUnlock
}

// MARK: - CaffeinateWatcher class

private class CaffeinateWatcher: NSObject {
    var object: UnsafeMutablePointer<CaffeinateWatcherData>

    init(object: UnsafeMutablePointer<CaffeinateWatcherData>) {
        self.object = object
        super.init()
    }

    // Call the lua callback function and pass the event type.
    func callback(dict: [AnyHashable: Any]?, event: CaffeinateEvent) {
        guard object.pointee.fn != LUA_NOREF else { return }

        let skin = LuaSkin.shared(withState: nil)
        skin.checkGCCanary(object.pointee.lsCanary)
        let L = skin.L

        let savedTop = lua_gettop(L)

        skin.pushLuaRef(refTable, ref: object.pointee.fn)
        lua_pushinteger(L, lua_Integer(event.rawValue))

        skin.protectedCallAndError("hs.caffeinate.watcher callback", nargs: 1, nresults: 0)
        assert(savedTop == lua_gettop(L))
    }

    @objc func caffeinateDidWake(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .didWake)
    }

    @objc func caffeinateWillSleep(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .willSleep)
    }

    @objc func caffeinateWillPowerOff(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .willPowerOff)
    }

    @objc func caffeinateScreensDidSleep(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensDidSleep)
    }

    @objc func caffeinateScreensDidWake(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensDidWake)
    }

    @objc func caffeinateSessionDidResignActive(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .sessionDidResignActive)
    }

    @objc func caffeinateSessionDidBecomeActive(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .sessionDidBecomeActive)
    }

    @objc func caffeinateScreensaverDidStart(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensaverDidStart)
    }

    @objc func caffeinateScreensaverWillStop(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensaverWillStop)
    }

    @objc func caffeinateScreensaverDidStop(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensaverDidStop)
    }

    @objc func caffeinateScreensDidLock(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensDidLock)
    }

    @objc func caffeinateScreensDidUnlock(_ notification: Notification) {
        callback(dict: notification.userInfo, event: .screensDidUnlock)
    }
}

// MARK: - Observer registration

private func register_observer(_ observer: CaffeinateWatcher) {
    // It is crucial to use the shared workspace notification center here.
    // Otherwise we will not receive the events we are interested in.
    let center = NSWorkspace.shared.notificationCenter
    let distcenter = DistributedNotificationCenter.default()

    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateDidWake(_:)),
                       name: NSWorkspace.didWakeNotification, object: nil)
    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateWillSleep(_:)),
                       name: NSWorkspace.willSleepNotification, object: nil)
    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateWillPowerOff(_:)),
                       name: NSWorkspace.willPowerOffNotification, object: nil)

    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensDidSleep(_:)),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensDidWake(_:)),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateSessionDidResignActive(_:)),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    center.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateSessionDidBecomeActive(_:)),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

    distcenter.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensaverDidStart(_:)),
                           name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
    distcenter.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensaverWillStop(_:)),
                           name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil)
    distcenter.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensaverDidStop(_:)),
                           name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
    distcenter.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensDidLock(_:)),
                           name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    distcenter.addObserver(observer, selector: #selector(CaffeinateWatcher.caffeinateScreensDidUnlock(_:)),
                           name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
}

private func unregister_observer(_ observer: CaffeinateWatcher) {
    let center = NSWorkspace.shared.notificationCenter
    let distcenter = DistributedNotificationCenter.default()

    center.removeObserver(observer, name: NSWorkspace.didWakeNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.willSleepNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.willPowerOffNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.screensDidSleepNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.screensDidWakeNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    distcenter.removeObserver(observer, name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
    distcenter.removeObserver(observer, name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil)
    distcenter.removeObserver(observer, name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
    distcenter.removeObserver(observer, name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    distcenter.removeObserver(observer, name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
}

// MARK: - Lua callbacks

/// hs.caffeinate.watcher.new(fn) -> watcher
/// Constructor
/// Creates a watcher object for system and display sleep/wake/power events
///
/// Parameters:
///  * fn - A function that will be called when system/display events happen. It should accept one parameter:
///   * An event type (see the constants defined above)
///
/// Returns:
///  * An `hs.caffeinate.watcher` object
private func caffeinate_watcher_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    let watcherPtr = lua_newuserdata(L, MemoryLayout<CaffeinateWatcherData>.size)!
        .assumingMemoryBound(to: CaffeinateWatcherData.self)
    memset(watcherPtr, 0, MemoryLayout<CaffeinateWatcherData>.size)

    lua_pushvalue(L, 1)
    watcherPtr.pointee.fn = skin.luaRef(refTable)
    watcherPtr.pointee.running = false

    let watcher = CaffeinateWatcher(object: watcherPtr)
    watcherPtr.pointee.obj = Unmanaged.passRetained(watcher).toOpaque()
    watcherPtr.pointee.lsCanary = skin.createGCCanary()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

/// hs.caffeinate.watcher:start()
/// Method
/// Starts the sleep/wake watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.caffeinate.watcher` object
private func caffeinate_watcher_start(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let watcherPtr = lua_touserdata(L, 1)!.assumingMemoryBound(to: CaffeinateWatcherData.self)
    lua_settop(L, 1)

    guard !watcherPtr.pointee.running else { return 1 }

    watcherPtr.pointee.running = true
    let watcher = Unmanaged<CaffeinateWatcher>.fromOpaque(watcherPtr.pointee.obj!).takeUnretainedValue()
    register_observer(watcher)
    return 1
}

/// hs.caffeinate.watcher:stop()
/// Method
/// Stops the sleep/wake watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.caffeinate.watcher` object
private func caffeinate_watcher_stop(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let watcherPtr = lua_touserdata(L, 1)!.assumingMemoryBound(to: CaffeinateWatcherData.self)
    lua_settop(L, 1)

    guard watcherPtr.pointee.running else { return 1 }

    watcherPtr.pointee.running = false
    let watcher = Unmanaged<CaffeinateWatcher>.fromOpaque(watcherPtr.pointee.obj!).takeUnretainedValue()
    unregister_observer(watcher)
    return 1
}

// Perform cleanup if the CaffeinateWatcher is not required anymore.
private func caffeinate_watcher_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: CaffeinateWatcherData.self)

    _ = caffeinate_watcher_stop(L)

    watcherPtr.pointee.fn = skin.luaUnref(refTable, ref: watcherPtr.pointee.fn)
    skin.destroyGCCanary(&watcherPtr.pointee.lsCanary)

    // Release the retained CaffeinateWatcher
    if let obj = watcherPtr.pointee.obj {
        Unmanaged<CaffeinateWatcher>.fromOpaque(obj).release()
        watcherPtr.pointee.obj = nil
    }

    return 0
}

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let desc = String(format: "%s: (%p)", USERDATA_TAG, lua_topointer(L, 1)!)
    lua_pushstring(L, desc)
    return 1
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    return 0
}

// MARK: - Event enum registration

private func add_event_value(_ L: OpaquePointer!, _ value: CaffeinateEvent, _ name: String) {
    lua_pushinteger(L, lua_Integer(value.rawValue))
    lua_setfield(L, -2, name)
}

private func add_event_enum(_ L: OpaquePointer!) {
    add_event_value(L, .didWake, "systemDidWake")
    add_event_value(L, .willSleep, "systemWillSleep")
    add_event_value(L, .willPowerOff, "systemWillPowerOff")
    add_event_value(L, .screensDidSleep, "screensDidSleep")
    add_event_value(L, .screensDidWake, "screensDidWake")
    add_event_value(L, .sessionDidResignActive, "sessionDidResignActive")
    add_event_value(L, .sessionDidBecomeActive, "sessionDidBecomeActive")
    add_event_value(L, .screensaverDidStart, "screensaverDidStart")
    add_event_value(L, .screensaverWillStop, "screensaverWillStop")
    add_event_value(L, .screensaverDidStop, "screensaverDidStop")
    add_event_value(L, .screensDidLock, "screensDidLock")
    add_event_value(L, .screensDidUnlock, "screensDidUnlock")
}

// MARK: - Module registration

// Metatable for created objects when _new invoked
private let metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"), func: caffeinate_watcher_start),
    luaL_Reg(name: strdup("stop"), func: caffeinate_watcher_stop),
    luaL_Reg(name: strdup("__gc"), func: caffeinate_watcher_gc),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let caffeinateLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: caffeinate_watcher_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private let metaGcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// Called when loading the module. All necessary tables need to be registered here.
@_cdecl("luaopen_hs_libcaffeinatewatcher")
public func luaopen_hs_libcaffeinatewatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG, functions: caffeinateLib, metaFunctions: metaGcLib, objectFunctions: metaLib)

    add_event_enum(skin.L)

    return 1
}
