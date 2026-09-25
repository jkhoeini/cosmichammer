import Foundation
import CLua
import Lua
import Cocoa
import HSDSTCore

/// === hs.spaces.watcher ===
///
/// Watches for the current Space being changed
/// NOTE: This extension determines the number of a Space, using OS X APIs that have been deprecated since 10.8 and will likely be removed in a future release. You should not depend on Space numbers being around forever!

private let USERDATA_TAG = "hs.spaces.watcher"
private var activeSpacesWatcherCount = 0

private func recordActiveSpacesWatcherGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.spaces.watcher.active",
        kind: .gauge,
        value: Double(activeSpacesWatcherCount),
        attributes: [:],
        unit: "1"
    )
}

// MARK: - SpaceWatcher Class

private enum SpaceWatcherMode {
    case active
    case lifecycle
}

private class SpaceWatcher: NSObject, LuaTeardownable {
    var callback: LuaValue?
    var mode: SpaceWatcherMode = .active
    var running: Bool = false
    var selfRef: Int32 = LUA_NOREF
    var generation: UInt64 = 0
    var observerToken: (any NotificationObserverToken)?
    var lifecycleCallbackID: UInt64?
    weak var spacesRef: (any SpacesProtocol)?
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            stop(lua_getCurrentState())
        }
        callback = nil
    }

    func callbackFired(space: Int) {
        invokeCallback(argumentCount: 1, attributes: ["space.id": space]) { L in
            L.push(lua_Integer(space))
        }
    }

    func lifecycleCallbackFired(_ event: SpaceLifecycleEvent) {
        invokeCallback(
            argumentCount: 2,
            attributes: ["space.id": event.spaceID, "space.event": event.kind.rawValue]
        ) { L in
            L.push(event.kind.rawValue)
            L.push(lua_Integer(event.spaceID))
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
            callbackName: "hs.spaces.watcher",
            attributes: attributes
        ) != LUA_OK {
            lua_pop(L, 1)
        }
    }

    func start(_ L: UnsafeMutablePointer<lua_State>) {
        guard !running else { return }

        // Pin self in registry to prevent GC while running.
        lua_pushvalue(L, 1)
        selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        running = true

        let spacesService = environmentGet(L).spaces
        spacesRef = spacesService
        switch mode {
        case .active:
            observerToken = environmentGet(L).notification.addWorkspaceObserver(
                name: NSWorkspace.activeSpaceDidChangeNotification.rawValue,
                object: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.callbackFired(space: spacesService.activeSpace() ?? -1)
            }
        case .lifecycle:
            lifecycleCallbackID = spacesService.addSpaceLifecycleCallback { [weak self] event in
                self?.lifecycleCallbackFired(event)
            }
        }

        activeSpacesWatcherCount += 1
        recordActiveSpacesWatcherGauge(L)
    }

    func stop(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
        guard running else { return }
        running = false

        if let L, selfRef != LUA_NOREF {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, selfRef)
            selfRef = LUA_NOREF
        }
        if let token = observerToken {
            if let L {
                environmentGet(L).notification.removeObserver(token)
            } else {
                environmentGetGlobalOrNil()?.notification.removeObserver(token)
            }
            observerToken = nil
        }
        if let callbackID = lifecycleCallbackID {
            _ = spacesRef?.removeSpaceLifecycleCallback(id: callbackID)
            lifecycleCallbackID = nil
        }
        spacesRef = nil


        activeSpacesWatcherCount = max(0, activeSpacesWatcherCount - 1)
        recordActiveSpacesWatcherGauge(L)
    }
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libspaces_watcher")
public func luaopen_hs_libspaces_watcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register idiomatic Metatable<SpaceWatcher> with LuaSwift.
        L.register(Metatable<SpaceWatcher>(
            fields: [
                "start": .closure { L in
                    let watcher: SpaceWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    watcher.start(L)
                    return 1
                },
                "stop": .closure { L in
                    let watcher: SpaceWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)
                    watcher.stop(L)
                    return 1
                },
            ],
            tostring: .closure { L in
                let _: SpaceWatcher = try L.checkArgument(1)
                let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
                L.push(desc)
                return 1
            }
        ))
        installMetatableBoilerplate(L, for: SpaceWatcher.self, tag: USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 2)

        /// hs.spaces.watcher.new(handler) -> watcher
        /// Constructor
        /// Creates a new watcher for Space change events
        ///
        /// Parameters:
        ///  * handler - A function to be called when the active Space changes. It should accept one argument, which will be the number of the new Space (or -1 if the number cannot be determined)
        ///
        /// Returns:
        ///  * An `hs.spaces.watcher` object
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let cb = L.ref(index: 1)

            let watcher = SpaceWatcher()
            watcher.callback = cb
            watcher.generation = lua_currentStateGeneration()

            L.push(userdata: watcher)

            return 1
        }
        lua_setfield(L, -2, "new")

        /// hs.spaces.watcher.newWithLifecycle(handler) -> watcher
        /// Constructor
        /// Creates a watcher for Space creation and destruction events.
        ///
        /// Parameters:
        ///  * handler - A function receiving `event` (`"created"` or `"destroyed"`) and the ephemeral numeric Space ID.
        ///
        /// Returns:
        ///  * An `hs.spaces.watcher` object
        ///
        /// Notes:
        ///  * This experimental API uses private SkyLight notifications plus topology-diff fallback. Re-query `hs.spaces.allSpaces()` for current topology.
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            let watcher = SpaceWatcher()
            watcher.callback = L.ref(index: 1)
            watcher.generation = lua_currentStateGeneration()
            watcher.mode = .lifecycle
            L.push(userdata: watcher)
            return 1
        }
        lua_setfield(L, -2, "newWithLifecycle")
    }
}
