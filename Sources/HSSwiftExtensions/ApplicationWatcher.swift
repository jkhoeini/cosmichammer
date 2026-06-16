import Cocoa
import CLua
import Lua
import HSDSTCore

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
    private var observerTokens: [any NotificationObserverToken] = []
    private weak var notificationRef: (any NotificationProtocol)?

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            unregisterObservers()
        }
        callbackRef = nil
    }

    func callback(_ dict: [String: Any], event: AppWatcherEvent) {
        guard let app = dict["NSWorkspaceApplicationKey"] as? NSRunningApplication else { return }
        guard running else { return }
        guard lua_isStateGenerationValid(generation) else { return }

        let L = lua_getCurrentState()!

        // Depending on the event the name of the NSRunningApplication may not be available anymore.
        // Fallback to the application name provided directly in the notification dict.
        var appName = app.localizedName
        if appName == nil {
            appName = dict["NSApplicationName"] as? String
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

    func registerObservers(_ L: UnsafeMutablePointer<lua_State>!) {
        let notification = environmentGet(L).notification
        notificationRef = notification

        let events: [(String, AppWatcherEvent)] = [
            (NSWorkspace.willLaunchApplicationNotification.rawValue, .launching),
            (NSWorkspace.didLaunchApplicationNotification.rawValue, .launched),
            (NSWorkspace.didTerminateApplicationNotification.rawValue, .terminated),
            (NSWorkspace.didHideApplicationNotification.rawValue, .hidden),
            (NSWorkspace.didUnhideApplicationNotification.rawValue, .unhidden),
            (NSWorkspace.didActivateApplicationNotification.rawValue, .activated),
            (NSWorkspace.didDeactivateApplicationNotification.rawValue, .deactivated),
        ]

        for (name, event) in events {
            let token = notification.addWorkspaceObserver(name: name, object: nil) { [weak self] userInfo in
                self?.callback(userInfo, event: event)
            }
            observerTokens.append(token)
        }
    }

    func unregisterObservers() {
        for token in observerTokens {
            notificationRef?.removeObserver(token)
        }
        observerTokens.removeAll()
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
                        watcher.registerObservers(L)
                    }
                    return 1
                },
                "stop": .closure { L in
                    let watcher: AppWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    if watcher.running {
                        watcher.running = false
                        watcher.unregisterObservers()
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
