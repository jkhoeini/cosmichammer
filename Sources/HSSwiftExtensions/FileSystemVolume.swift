import Foundation
import CLua
import Lua
import Cocoa
import HSDSTCore

/// === hs.fs.volume ===
///
/// Interact with OS X filesystem volumes
///
/// This is distinct from hs.fs in that hs.fs deals with UNIX filesystem operations, while hs.fs.volume interacts with the higher level OS X concept of volumes

/// hs.fs.volume.didMount
/// Constant
/// A volume was mounted

/// hs.fs.volume.didUnmount
/// Constant
/// A volume was unmounted

/// hs.fs.volume.willUnmount
/// Constant
/// A volume is about to be unmounted

/// hs.fs.volume.didRename
/// Constant
/// A volume changed either its name or mountpoint (or more likely, both)

// MARK: - Constants

private let USERDATA_TAG = "hs.fs.volume"

// MARK: - Event type enum

private enum VolumeEvent: Int {
    case didMount = 0
    case didUnmount
    case willUnmount
    case didRename
}

// MARK: - VolumeWatcher class

private class VolumeWatcher: NSObject {
    var callback: LuaValue?
    var running: Bool = false
    var generation: UInt64 = 0
    var observerTokens: [any NotificationObserverToken] = []
    weak var notificationRef: (any NotificationProtocol)?
    private var tornDown = false

    /// Idempotent teardown: stop observers, drop the Lua callback reference,
    /// mark as torn down.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            for token in observerTokens {
                notificationRef?.removeObserver(token)
            }
            observerTokens.removeAll()
        }
        notificationRef = nil
        callback = nil
    }

    // Call the lua callback function and pass the event type and info dict.
    func handleVolume(_ dict: [String: Any], withEvent event: VolumeEvent) {
        if !lua_isStateGenerationValid(generation) {
            teardown()
            return
        }

        let L = lua_getCurrentState()!

        guard let cb = callback else { return }

        cb.push(onto: L)
        L.push(lua_Integer(event.rawValue))

        var tableArg = [String: Any]()

        switch event {
        case .didMount, .didUnmount, .willUnmount:
            if let devicePath = dict["NSDevicePath"] {
                tableArg["path"] = devicePath
            }
        case .didRename:
            if let url = dict[NSWorkspace.volumeURLUserInfoKey] {
                tableArg["path"] = url
            }
            if let name = dict[NSWorkspace.localizedVolumeNameUserInfoKey] {
                tableArg["name"] = name
            }
            if let oldURL = dict[NSWorkspace.oldVolumeURLUserInfoKey] {
                tableArg["oldPath"] = oldURL
            }
            if let oldName = dict[NSWorkspace.oldLocalizedVolumeNameUserInfoKey] {
                tableArg["oldName"] = oldName
            }
        }

        lua_pushany(L, tableArg)
        if lua_pcall(L, 2, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }
}

// MARK: - Observer registration

private func register_observer(_ observer: VolumeWatcher, _ L: UnsafeMutablePointer<lua_State>!) {
    let notif = environmentGet(L).notification

    let events: [(String, VolumeEvent)] = [
        (NSWorkspace.didMountNotification.rawValue, .didMount),
        (NSWorkspace.didUnmountNotification.rawValue, .didUnmount),
        (NSWorkspace.willUnmountNotification.rawValue, .willUnmount),
        (NSWorkspace.didRenameVolumeNotification.rawValue, .didRename),
    ]

    for (name, event) in events {
        let token = notif.addWorkspaceObserver(name: name, object: nil) { [weak observer] userInfo in
            observer?.handleVolume(userInfo, withEvent: event)
        }
        observer.observerTokens.append(token)
    }
    observer.notificationRef = notif
}

private func unregister_observer(_ observer: VolumeWatcher, _ L: UnsafeMutablePointer<lua_State>!) {
    let notif = environmentGet(L).notification
    for token in observer.observerTokens {
        notif.removeObserver(token)
    }
    observer.observerTokens.removeAll()
}

// MARK: - Module functions

/// hs.fs.volume.eject(path) -> boolean,string
/// Function
/// Unmounts and ejects a volume
///
/// Parameters:
///  * path - An absolute path to the volume you wish to eject
///
/// Returns:
///  * A boolean, true if the volume was ejected, otherwise false
///  * A string, empty if the volume was ejected, otherwise it will contain the error message
private func volume_eject(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let path = String(cString: lua_tostring(L, 1)!)

    let workspace = NSWorkspace.shared
    var resultText = ""

    do {
        try workspace.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
        L.push(true)
    } catch {
        L.push(false)
        resultText = error.localizedDescription
    }

    L.push(resultText)
    return 2
}

/// hs.fs.volume.new(fn) -> watcher
/// Constructor
/// Creates a watcher object for volume events
///
/// Parameters:
///  * fn - A function that will be called when volume events happen. It should accept two parameters:
///   * An event type (see the constants defined above)
///   * A table that will contain relevant information
///
/// Returns:
///  * An `hs.fs.volume` object
private func volume_watcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let cb = L.ref(index: 1)

    let watcher = VolumeWatcher()
    watcher.callback = cb
    watcher.generation = lua_currentStateGeneration()

    L.push(userdata: watcher)

    return 1
}

// MARK: - Event enum helpers

private func add_event_value(_ L: UnsafeMutablePointer<lua_State>!, _ value: VolumeEvent, _ name: String) {
    L.push(lua_Integer(value.rawValue))
    lua_setfield(L, -2, name)
}

private func add_event_enum(_ L: UnsafeMutablePointer<lua_State>!) {
    add_event_value(L, .didMount, "didMount")
    add_event_value(L, .didUnmount, "didUnmount")
    add_event_value(L, .willUnmount, "willUnmount")
    add_event_value(L, .didRename, "didRename")
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libfsvolume")
public func luaopen_hs_libfsvolume(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<VolumeWatcher> with LuaSwift.
    L.register(Metatable<VolumeWatcher>(
        fields: [
            "start": .closure { L in
                let watcher: VolumeWatcher = try L.checkArgument(1)
                lua_settop(L, 1)
                if !watcher.running {
                    watcher.running = true
                    register_observer(watcher, L)
                }
                return 1
            },
            "stop": .closure { L in
                let watcher: VolumeWatcher = try L.checkArgument(1)
                lua_settop(L, 1)
                if watcher.running {
                    watcher.running = false
                    unregister_observer(watcher, L)
                }
                return 1
            },
        ],
        tostring: .closure { L in
            let _: VolumeWatcher = try L.checkArgument(1)
            let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
            L.push(desc)
            return 1
        }
    ))

    // Replace __gc with our explicit teardown + deinitialize
    L.pushMetatable(for: VolumeWatcher.self)

    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let watcher: VolumeWatcher = L.touserdata(1) {
            watcher.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.fs.volume") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 6)
    L.push(volume_watcher_new)
    lua_setfield(L, -2, "new")
    L.push(volume_eject)
    lua_setfield(L, -2, "eject")

    add_event_enum(L)

    return 1
}
