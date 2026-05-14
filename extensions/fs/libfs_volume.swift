import Foundation
import Cocoa
import LuaSkin

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
private var refTable: LSRefTable = 0

// MARK: - Event type enum

private enum VolumeEvent: Int {
    case didMount = 0
    case didUnmount
    case willUnmount
    case didRename
}

// MARK: - Userdata struct

private struct VolumeWatcher_t {
    var running: Bool
    var fn: Int32
    var obj: UnsafeMutableRawPointer? // Retained VolumeWatcher
}

// MARK: - VolumeWatcher class

private class VolumeWatcher: NSObject {
    var object: UnsafeMutablePointer<VolumeWatcher_t>

    init(object: UnsafeMutablePointer<VolumeWatcher_t>) {
        self.object = object
        super.init()
    }

    // Call the lua callback function and pass the event type and info dict.
    func callback(_ dict: [AnyHashable: Any], withEvent event: VolumeEvent) {
        let skin = LuaSkin.shared(withState: nil)
        let L = skin.l
        _lua_stackguard_entry(L)

        skin.pushLuaRef(refTable, ref: object.pointee.fn)
        lua_pushinteger(L, lua_Integer(event.rawValue))

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
            if let name = dict[NSWorkspace.volumeLocalizedNameUserInfoKey] {
                tableArg["name"] = name
            }
            if let oldURL = dict[NSWorkspace.volumeOldURLUserInfoKey] {
                tableArg["oldPath"] = oldURL
            }
            if let oldName = dict[NSWorkspace.volumeOldLocalizedNameUserInfoKey] {
                tableArg["oldName"] = oldName
            }
        }

        skin.pushNSObject(tableArg as NSDictionary)
        skin.protectedCallAndError("hs.fs.volume callback", nargs: 2, nresults: 0)
        _lua_stackguard_exit(L)
    }

    @objc func volumeDidMount(_ notification: Notification) {
        callback(notification.userInfo ?? [:], withEvent: .didMount)
    }

    @objc func volumeDidUnmount(_ notification: Notification) {
        callback(notification.userInfo ?? [:], withEvent: .didUnmount)
    }

    @objc func volumeWillUnmount(_ notification: Notification) {
        callback(notification.userInfo ?? [:], withEvent: .willUnmount)
    }

    @objc func volumeDidRename(_ notification: Notification) {
        callback(notification.userInfo ?? [:], withEvent: .didRename)
    }
}

// MARK: - Observer registration

private func register_observer(_ observer: VolumeWatcher) {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(observer,
                       selector: #selector(VolumeWatcher.volumeDidMount(_:)),
                       name: NSWorkspace.didMountNotification,
                       object: nil)
    center.addObserver(observer,
                       selector: #selector(VolumeWatcher.volumeDidUnmount(_:)),
                       name: NSWorkspace.didUnmountNotification,
                       object: nil)
    center.addObserver(observer,
                       selector: #selector(VolumeWatcher.volumeWillUnmount(_:)),
                       name: NSWorkspace.willUnmountNotification,
                       object: nil)
    center.addObserver(observer,
                       selector: #selector(VolumeWatcher.volumeDidRename(_:)),
                       name: NSWorkspace.didRenameVolumeNotification,
                       object: nil)
}

private func unregister_observer(_ observer: VolumeWatcher) {
    let center = NSWorkspace.shared.notificationCenter
    center.removeObserver(observer, name: NSWorkspace.didMountNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didUnmountNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.willUnmountNotification, object: nil)
    center.removeObserver(observer, name: NSWorkspace.didRenameVolumeNotification, object: nil)
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
private func volume_eject(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let workspace = NSWorkspace.shared
    var resultText: NSString = ""

    do {
        try workspace.unmountAndEjectDevice(at: URL(fileURLWithPath: skin.toNSObject(atIndex: 1) as! String))
        lua_pushboolean(L, 1)
    } catch {
        lua_pushboolean(L, 0)
        resultText = error.localizedDescription as NSString
    }

    skin.pushNSObject(resultText)
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
private func volume_watcher_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    let watcher = lua_newuserdata(L, MemoryLayout<VolumeWatcher_t>.size)!
        .assumingMemoryBound(to: VolumeWatcher_t.self)
    memset(watcher, 0, MemoryLayout<VolumeWatcher_t>.size)

    lua_pushvalue(L, 1)
    watcher.pointee.fn = skin.luaRef(refTable)
    watcher.pointee.running = false
    let watcherObj = VolumeWatcher(object: watcher)
    watcher.pointee.obj = Unmanaged.passRetained(watcherObj).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

/// hs.fs.volume:start()
/// Method
/// Starts the volume watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.fs.volume` object
private func volume_watcher_start(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let watcher = lua_touserdata(L, 1)!.assumingMemoryBound(to: VolumeWatcher_t.self)
    lua_settop(L, 1)

    if watcher.pointee.running {
        return 1
    }

    watcher.pointee.running = true
    let observer = Unmanaged<VolumeWatcher>.fromOpaque(watcher.pointee.obj!).takeUnretainedValue()
    register_observer(observer)
    return 1
}

/// hs.fs.volume:stop()
/// Method
/// Stops the volume watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.fs.volume` object
private func volume_watcher_stop(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let watcher = lua_touserdata(L, 1)!.assumingMemoryBound(to: VolumeWatcher_t.self)
    lua_settop(L, 1)

    if !watcher.pointee.running {
        return 1
    }

    watcher.pointee.running = false
    let observer = Unmanaged<VolumeWatcher>.fromOpaque(watcher.pointee.obj!).takeUnretainedValue()
    unregister_observer(observer)
    return 1
}

// Perform cleanup if the VolumeWatcher is not required anymore.
private func volume_watcher_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: VolumeWatcher_t.self)

    volume_watcher_stop(L)

    watcher.pointee.fn = skin.luaUnref(refTable, ref: watcher.pointee.fn)

    if let obj = watcher.pointee.obj {
        let _ = Unmanaged<VolumeWatcher>.fromOpaque(obj).takeRetainedValue()
        watcher.pointee.obj = nil
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

// MARK: - Event enum helpers

private func add_event_value(_ L: OpaquePointer!, _ value: VolumeEvent, _ name: String) {
    lua_pushinteger(L, lua_Integer(value.rawValue))
    lua_setfield(L, -2, name)
}

private func add_event_enum(_ L: OpaquePointer!) {
    add_event_value(L, .didMount, "didMount")
    add_event_value(L, .didUnmount, "didUnmount")
    add_event_value(L, .willUnmount, "willUnmount")
    add_event_value(L, .didRename, "didRename")
}

// MARK: - Lua registration tables

// Metatable for created objects when _new invoked
private let metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: volume_watcher_start),
    luaL_Reg(name: strdup("stop"),       func: volume_watcher_stop),
    luaL_Reg(name: strdup("__gc"),       func: volume_watcher_gc),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let appLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),   func: volume_watcher_new),
    luaL_Reg(name: strdup("eject"), func: volume_eject),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private let metaGcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libfsvolume")
public func luaopen_hs_libfsvolume(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: appLib,
                                    metaFunctions: metaGcLib,
                                    objectFunctions: metaLib)

    add_event_enum(skin.l)

    return 1
}
