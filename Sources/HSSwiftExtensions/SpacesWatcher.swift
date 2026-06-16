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

// MARK: - SpaceWatcher Class

private class SpaceWatcher: NSObject, LuaTeardownable {
    var callback: LuaValue?
    var running: Bool = false
    var selfRef: Int32 = LUA_NOREF
    var generation: UInt64 = 0
    var observerToken: (any NotificationObserverToken)?
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            let L = lua_getCurrentState()!
            if let token = observerToken {
                environmentGet(L).notification.removeObserver(token)
                observerToken = nil
            }
            if selfRef != LUA_NOREF {
                luaL_unref(L, LUA_REGISTRYINDEX_VALUE, selfRef)
                selfRef = LUA_NOREF
            }
        }
        callback = nil
    }

    // Call the lua callback function.
    func callbackFired(dict: NSDictionary?, space: Int32) {
        guard !tornDown else { return }
        guard lua_isStateGenerationValid(generation) else {
            teardown()
            return
        }
        if let cb = callback {
            let L = lua_getCurrentState()!

            cb.push(onto: L)
            L.push(lua_Integer(space))
            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                lua_pop(L, 1)
            }
        }
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

                    if watcher.running { return 1 }

                    // Pin self in registry to prevent GC while running
                    lua_pushvalue(L, 1)
                    watcher.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
                    watcher.running = true

                    let spacesService = environmentGet(L).spaces
                    watcher.observerToken = environmentGet(L).notification.addWorkspaceObserver(
                        name: NSWorkspace.activeSpaceDidChangeNotification.rawValue,
                        object: nil
                    ) { [weak watcher] userInfo in
                        guard let watcher = watcher else { return }
                        let spaceID = spacesService.activeSpace() ?? -1
                        let currentSpace = Int32(clamping: spaceID)
                        watcher.callbackFired(dict: userInfo as NSDictionary, space: currentSpace)
                    }

                    return 1
                },
                "stop": .closure { L in
                    let watcher: SpaceWatcher = try L.checkArgument(1)
                    lua_settop(L, 1)

                    if !watcher.running { return 1 }

                    watcher.running = false
                    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, watcher.selfRef)
                    watcher.selfRef = LUA_NOREF
                    if let token = watcher.observerToken {
                        environmentGet(L).notification.removeObserver(token)
                        watcher.observerToken = nil
                    }

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
        lua_createtable(L, 0, 1)

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
    }
}
