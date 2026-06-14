import Foundation
import CLua
import Lua
import Cocoa

/// === hs.screen.watcher ===
///
/// Watch for screen layout changes
/// This could be the addition or removal of a monitor, a screen resolution change, movement of a monitor in the Display preferences pane, etc.
///
/// Note that screen events which happen while your Mac is suspended, may not trigger the watcher in various circumstances (e.g. if you have FileVault enabled and the machine resumes out of hibernation - the screen events will be happening before the drive is unlocked and will not be reported to Cosmic Hammer)
///
/// This module is based primarily on code from the previous incarnation of Mjolnir.

private let USERDATA_TAG = "hs.screen.watcher"

// MARK: - MJScreenWatcher

private class MJScreenWatcher: NSObject, LuaTeardownable {
    var callback: LuaValue?
    var includeActive: Bool = false
    var running: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            NotificationCenter.default.removeObserver(self,
                                                      name: NSApplication.didChangeScreenParametersNotification,
                                                      object: nil)
            if includeActive {
                NSWorkspace.shared.notificationCenter.removeObserver(self,
                                                                     name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                                                                     object: nil)
            }
        }
        callback = nil
    }

    @objc func _screensChanged(_ note: Notification) {
        performSelector(onMainThread: #selector(screensChanged(_:)), with: note, waitUntilDone: true)
    }

    @objc func screensChanged(_ note: Notification) {
        guard !tornDown else { return }
        guard lua_isStateGenerationValid(generation) else {
            teardown()
            return
        }
        guard let cb = callback else { return }

        let L = lua_getCurrentState()!

        let argCount: Int32 = includeActive ? 1 : 0

        cb.push(onto: L)
        if includeActive {
            if note.name.rawValue == "NSWorkspaceActiveDisplayDidChangeNotification" {
                L.push(true)
            } else {
                lua_pushnil(L)
            }
        }
        if lua_pcall(L, argCount, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
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

                    if watcher.running { return 1 }
                    watcher.running = true

                    NotificationCenter.default.addObserver(watcher,
                                                           selector: #selector(MJScreenWatcher._screensChanged(_:)),
                                                           name: NSApplication.didChangeScreenParametersNotification,
                                                           object: nil)

                    if watcher.includeActive {
                        NSWorkspace.shared.notificationCenter.addObserver(watcher,
                                                                          selector: #selector(MJScreenWatcher._screensChanged(_:)),
                                                                          name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                                                                          object: nil)
                    }

                    return 1
                },
                "stop": .closure { L in
                    let watcher: MJScreenWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)

                    if !watcher.running { return 1 }
                    watcher.running = false

                    NotificationCenter.default.removeObserver(watcher,
                                                              name: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil)

                    if watcher.includeActive {
                        NSWorkspace.shared.notificationCenter.removeObserver(watcher,
                                                                             name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                                                                             object: nil)
                    }

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
        lua_createtable(L, 0, 2)

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
            watcher.includeActive = false

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
            watcher.includeActive = true

            L.push(userdata: watcher)

            return 1
        }
        lua_setfield(L, -2, "newWithActiveScreen")
    }
}
