import Foundation
import CLua
import Lua
import Cocoa

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
private var refTable: Int32 = 0

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

private class CaffeinateWatcher: NSObject, LuaTeardownable {
    var callback: LuaValue?
    var running: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            unregister_observer(self)
        }
        callback = nil
    }

    // Call the lua callback function and pass the event type.
    func callbackFired(dict: [AnyHashable: Any]?, event: CaffeinateEvent) {
        guard !tornDown else { return }
        guard let cb = callback else { return }
        guard lua_isStateGenerationValid(generation) else {
            teardown()
            return
        }

        let L = lua_getCurrentState()!

        cb.push(onto: L)
        L.push(lua_Integer(event.rawValue))

        if lua_pcall(L, 1, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }

    @objc func caffeinateDidWake(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .didWake)
    }

    @objc func caffeinateWillSleep(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .willSleep)
    }

    @objc func caffeinateWillPowerOff(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .willPowerOff)
    }

    @objc func caffeinateScreensDidSleep(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensDidSleep)
    }

    @objc func caffeinateScreensDidWake(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensDidWake)
    }

    @objc func caffeinateSessionDidResignActive(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .sessionDidResignActive)
    }

    @objc func caffeinateSessionDidBecomeActive(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .sessionDidBecomeActive)
    }

    @objc func caffeinateScreensaverDidStart(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensaverDidStart)
    }

    @objc func caffeinateScreensaverWillStop(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensaverWillStop)
    }

    @objc func caffeinateScreensaverDidStop(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensaverDidStop)
    }

    @objc func caffeinateScreensDidLock(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensDidLock)
    }

    @objc func caffeinateScreensDidUnlock(_ notification: Notification) {
        callbackFired(dict: notification.userInfo, event: .screensDidUnlock)
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

// MARK: - Event enum registration

private func add_event_value(_ L: UnsafeMutablePointer<lua_State>!, _ value: CaffeinateEvent, _ name: String) {
    L.push(lua_Integer(value.rawValue))
    lua_setfield(L, -2, name)
}

private func add_event_enum(_ L: UnsafeMutablePointer<lua_State>!) {
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

// Called when loading the module. All necessary tables need to be registered here.
@_cdecl("luaopen_hs_libcaffeinatewatcher")
public func luaopen_hs_libcaffeinatewatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register idiomatic Metatable<CaffeinateWatcher> with LuaSwift.
        L.register(Metatable<CaffeinateWatcher>(
            fields: [
                "start": .closure { L in
                    let watcher: CaffeinateWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    if !watcher.running {
                        watcher.running = true
                        register_observer(watcher)
                    }
                    return 1
                },
                "stop": .closure { L in
                    let watcher: CaffeinateWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    if watcher.running {
                        watcher.running = false
                        unregister_observer(watcher)
                    }
                    return 1
                },
            ],
            tostring: .closure { L in
                let _: CaffeinateWatcher = try L.checkArgument(1)
                let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
                L.push(desc)
                return 1
            }
        ))
        installMetatableBoilerplate(L, for: CaffeinateWatcher.self, tag: USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 1)

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
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let cb = L.ref(index: 1)

            let watcher = CaffeinateWatcher()
            watcher.callback = cb
            watcher.generation = lua_currentStateGeneration()

            L.push(userdata: watcher)

            return 1
        }
        lua_setfield(L, -2, "new")

        add_event_enum(L)

        // Module-level metatable (Lua wrapper accesses via getmetatable)
        lua_createtable(L, 0, 1)
        lua_pushcclosure(L, { (_: LuaState!) -> CInt in 0 }, 0)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
