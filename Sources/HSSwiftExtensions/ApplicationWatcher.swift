import Cocoa
import CLua
import Lua

// MARK: - Module constants

private let USERDATA_TAG = "hs.application.watcher"

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

private class AppWatcher: NSObject, LuaTeardownable {
    var running: Bool = false
    var callbackRef: LuaValue?
    var generation: UInt64 = 0
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            unregisterObserver()
        }
        callbackRef = nil
    }

    func callback(_ dict: [AnyHashable: Any], event: AppWatcherEvent) {
        guard let app = dict["NSWorkspaceApplicationKey" as NSString] as? NSRunningApplication else { return }
        guard running else { return }
        guard lua_isStateGenerationValid(generation) else { return }

        let L = lua_getCurrentState()!

        // Depending on the event the name of the NSRunningApplication may not be available anymore.
        // Fallback to the application name provided directly in the notification dict.
        var appName = app.localizedName
        if appName == nil {
            appName = dict["NSApplicationName" as NSString] as? String
        }

        guard let cb = callbackRef else { return }
        cb.push(onto: L)

        if let name = appName {
            L.push(name)
        } else {
            lua_pushnil(L)
        }

        L.push(lua_Integer(event.rawValue))

        if let application = HSapplication(nsRunningApplication: app, withState: L) {
            // Push HSapplication userdata directly
            application.selfRefCount += 1
            let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            valuePtr.pointee = Unmanaged.passRetained(application as NSObject).toOpaque()
            luaL_getmetatable(L, "hs.application")
            lua_setmetatable(L, -2)
        } else {
            lua_pushnil(L)
        }

        if lua_pcall(L, 3, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
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
        L.push(lua_Integer(value.rawValue))
        lua_setfield(L, -2, name)
    }
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libapplicationwatcher")
public func luaopen_hs_libapplicationwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        L.register(Metatable<AppWatcher>(
            fields: [
                "start": .closure { L in
                    let watcher: AppWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    if !watcher.running {
                        watcher.running = true
                        watcher.registerObserver()
                    }
                    return 1
                },
                "stop": .closure { L in
                    let watcher: AppWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    if watcher.running {
                        watcher.running = false
                        watcher.unregisterObserver()
                    }
                    return 1
                },
            ],
            tostring: .closure { L in
                let _: AppWatcher = try L.checkArgument(1)
                let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
                L.push(desc)
                return 1
            }
        ))
        installMetatableBoilerplate(L, for: AppWatcher.self, tag: USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 8)

        L.push({ (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let watcher = AppWatcher()
            watcher.callbackRef = L.ref(index: 1)
            watcher.generation = lua_currentStateGeneration()

            L.push(userdata: watcher)
            return 1
        })
        lua_setfield(L, -2, "new")

        add_event_enum(L)
    }
}
