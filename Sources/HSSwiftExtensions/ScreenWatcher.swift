import Foundation
import CLua
import Lua
import Cocoa
import HSDSTCore

/// === hs.screen.watcher ===
///
/// Watch for screen layout changes
/// This could be the addition or removal of a monitor, a screen resolution change, movement of a monitor in the Display preferences pane, etc.
///
/// Note that screen events which happen while your Mac is suspended, may not trigger the watcher in various circumstances (e.g. if you have FileVault enabled and the machine resumes out of hibernation - the screen events will be happening before the drive is unlocked and will not be reported to Cosmic Hammer)
///
/// This module is based primarily on code from the previous incarnation of Mjolnir.

private let USERDATA_TAG = "hs.screen.watcher"
private var activeScreenWatcherCount = 0

private func recordActiveScreenWatcherGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.screen.watcher.active",
        kind: .gauge,
        value: Double(activeScreenWatcherCount),
        attributes: [:],
        unit: "1"
    )
}

// MARK: - MJScreenWatcher

private enum ScreenWatcherMode {
    case layout
    case activeDisplay
    case displayEvents
}

private class MJScreenWatcher: NSObject, LuaTeardownable {
    var callback: LuaValue?
    var mode: ScreenWatcherMode = .layout
    var running: Bool = false
    var selfRef: Int32 = LUA_NOREF
    var generation: UInt64 = 0
    var screenParamsToken: (any NotificationObserverToken)?
    var activeDisplayToken: (any NotificationObserverToken)?
    var displayCallbackID: UInt64?
    weak var notificationRef: (any NotificationProtocol)?
    weak var screenRef: (any ScreenProtocol)?
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            stop(lua_getCurrentState())
        }
        notificationRef = nil
        callback = nil
    }

    func screensChanged(isActiveDisplayChange: Bool) {
        invokeCallback(
            argumentCount: mode == .activeDisplay ? 1 : 0,
            attributes: ["screen.active_display_change": isActiveDisplayChange]
        ) { L in
            if mode == .activeDisplay {
                isActiveDisplayChange ? L.push(true) : lua_pushnil(L)
            }
        }
    }

    func displayChanged(_ event: DisplayReconfigurationEvent) {
        invokeCallback(
            argumentCount: 2,
            attributes: ["display.id": event.displayID, "display.event": event.kind.rawValue]
        ) { L in
            L.push(event.kind.rawValue)
            L.push(lua_Integer(event.displayID))
        }
    }

    private func invokeCallback(
        argumentCount: Int32,
        attributes: [String: Any],
        pushArguments: (LuaState) -> Void
    ) {
        guard !tornDown else { return }
        guard lua_isStateGenerationValid(generation) else {
            teardown()
            return
        }
        guard let callback, let L = lua_getCurrentState() else { return }

        callback.push(onto: L)
        pushArguments(L)
        if luaTelemetryPCall(
            L,
            nargs: argumentCount,
            nresults: 0,
            callbackName: "hs.screen.watcher",
            attributes: attributes
        ) != LUA_OK {
            lua_pop(L, 1)
        }
    }

    func start(_ L: UnsafeMutablePointer<lua_State>) {
        guard !running else { return }

        lua_pushvalue(L, 1)
        selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        running = true

        switch mode {
        case .layout, .activeDisplay:
            let notification = environmentGet(L).notification
            notificationRef = notification
            screenParamsToken = notification.addObserver(
                name: NSApplication.didChangeScreenParametersNotification.rawValue,
                object: nil
            ) { [weak self] _ in
                self?.screensChanged(isActiveDisplayChange: false)
            }
            if mode == .activeDisplay {
                activeDisplayToken = notification.addWorkspaceObserver(
                    name: "NSWorkspaceActiveDisplayDidChangeNotification",
                    object: nil
                ) { [weak self] _ in
                    self?.screensChanged(isActiveDisplayChange: true)
                }
            }
        case .displayEvents:
            let screen = environmentGet(L).screen
            screenRef = screen
            displayCallbackID = screen.addDisplayReconfigurationCallback { [weak self] event in
                guard event.kind == .added || event.kind == .removed ||
                      event.kind == .moved || event.kind == .resized else { return }
                self?.displayChanged(event)
            }
        }

        activeScreenWatcherCount += 1
        recordActiveScreenWatcherGauge(L)
    }

    func stop(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
        guard running else { return }
        running = false
        if let L, selfRef != LUA_NOREF {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, selfRef)
            selfRef = LUA_NOREF
        }
        if let token = screenParamsToken {
            notificationRef?.removeObserver(token)
            screenParamsToken = nil
        }
        if let token = activeDisplayToken {
            notificationRef?.removeObserver(token)
            activeDisplayToken = nil
        }
        if let callbackID = displayCallbackID {
            _ = screenRef?.removeDisplayReconfigurationCallback(id: callbackID)
            displayCallbackID = nil
        }
        screenRef = nil

        activeScreenWatcherCount = max(0, activeScreenWatcherCount - 1)
        recordActiveScreenWatcherGauge(L)
    }
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libscreenwatcher")
public func luaopen_hs_libscreenwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register idiomatic Metatable<MJScreenWatcher> with LuaSwift.
        L.register(Metatable<MJScreenWatcher>(
            fields: [
                "start": .closure { L in
                    let watcher: MJScreenWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    watcher.start(L)
                    return 1
                },
                "stop": .closure { L in
                    let watcher: MJScreenWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    watcher.stop(L)
                    return 1
                },
            ],
            tostring: .closure { L in
                let _: MJScreenWatcher = try L.checkArgument(1)
                let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
                L.push(desc)
                return 1
            }
        ))
        installMetatableBoilerplate(L, for: MJScreenWatcher.self, tag: USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 3)

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
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let cb = L.ref(index: 1)

            let watcher = MJScreenWatcher()
            watcher.callback = cb
            watcher.generation = lua_currentStateGeneration()
            watcher.mode = .layout

            L.push(userdata: watcher)

            return 1
        }
        lua_setfield(L, -2, "new")

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
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let cb = L.ref(index: 1)

            let watcher = MJScreenWatcher()
            watcher.callback = cb
            watcher.generation = lua_currentStateGeneration()
            watcher.mode = .activeDisplay

            L.push(userdata: watcher)

            return 1
        }
        lua_setfield(L, -2, "newWithActiveScreen")

        /// hs.screen.watcher.newWithDisplayEvents(fn) -> watcher
        /// Constructor
        /// Creates a watcher for granular display reconfiguration events.
        ///
        /// Parameters:
        ///  * fn - A function receiving `event` (`"added"`, `"removed"`, `"moved"`, or `"resized"`) and the ephemeral display ID.
        ///
        /// Returns:
        ///  * An `hs.screen.watcher` object
        ///
        /// Notes:
        ///  * CoreGraphics can emit multi-flag before/after bursts. This watcher reports one event per accepted after-change callback; re-query `hs.screen.allScreens()` for current topology.
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let watcher = MJScreenWatcher()
            watcher.callback = L.ref(index: 1)
            watcher.generation = lua_currentStateGeneration()
            watcher.mode = .displayEvents
            L.push(userdata: watcher)
            return 1
        }
        lua_setfield(L, -2, "newWithDisplayEvents")
    }
}
