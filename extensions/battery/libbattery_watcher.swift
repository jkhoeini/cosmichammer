import Cocoa
import LuaSkin
import IOKit.ps

/// === hs.battery.watcher ===
///
/// Watch for battery/power state changes
///
/// This module is based primarily on code from the previous incarnation of Mjolnir.

// Common Code

private let USERDATA_TAG = "hs.battery.watcher"
private var refTable: Int32 = 0

// Not so common code

private struct BatteryWatcher {
    var t: CFRunLoopSource!
    var fn: Int32 = Int32(LUA_NOREF)
    var started: Bool = false
    var lsCanary: LSGCCanary = 0
}

private func callback(_ info: UnsafeMutableRawPointer?) {
    let skin = LuaSkin.shared(withState: nil)

    guard let info = info else { return }
    let watcher = info.assumingMemoryBound(to: BatteryWatcher.self)

    if !skin.checkGCCanary(watcher.pointee.lsCanary) {
        return
    }

    _lua_stackguard_entry(skin.L)

    if watcher.pointee.fn != Int32(LUA_NOREF) {
        skin.pushLuaRef(refTable, ref: watcher.pointee.fn)
        skin.protectedCallAndError("hs.battery.watcher callback", nargs: 0, nresults: 0)
    }
    _lua_stackguard_exit(skin.L)
}

/// hs.battery.watcher.new(fn) -> watcher
/// Constructor
/// Creates a battery watcher
///
/// Parameters:
///  * A function that will be called when the battery state changes. The function should accept no arguments.
///
/// Returns:
///  * An `hs.battery.watcher` object
///
/// Notes:
///  * Because the callback function accepts no arguments, tracking of state of changing battery attributes is the responsibility of the user (see https://github.com/Hammerspoon/hammerspoon/issues/166 for discussion)
private func battery_watcher_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    luaL_checktype(L, 1, LUA_TFUNCTION)

    let watcherPtr = lua_newuserdata(L, MemoryLayout<BatteryWatcher>.size)!
        .assumingMemoryBound(to: BatteryWatcher.self)
    watcherPtr.pointee = BatteryWatcher()

    lua_pushvalue(L, 1)
    watcherPtr.pointee.fn = skin.luaRef(refTable)

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    watcherPtr.pointee.t = IOPSNotificationCreateRunLoopSource(callback, watcherPtr)?.takeRetainedValue()
    watcherPtr.pointee.started = false
    watcherPtr.pointee.lsCanary = skin.createGCCanary()
    return 1
}

/// hs.battery.watcher:start() -> self
/// Method
/// Starts the battery watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.battery.watcher` object
private func battery_watcher_start(_ L: OpaquePointer!) -> Int32 {
    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)

    lua_settop(L, 1)

    if watcher.pointee.started { return 1 }

    watcher.pointee.started = true

    CFRunLoopAddSource(CFRunLoopGetMain(), watcher.pointee.t, .commonModes)
    return 1
}

/// hs.battery.watcher:stop() -> self
/// Method
/// Stops the battery watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.battery.watcher` object
private func battery_watcher_stop(_ L: OpaquePointer!) -> Int32 {
    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)
    lua_settop(L, 1)

    if !watcher.pointee.started { return 1 }

    watcher.pointee.started = false
    CFRunLoopRemoveSource(CFRunLoopGetMain(), watcher.pointee.t, .commonModes)
    return 1
}

private func battery_watcher_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)

    lua_pushcfunction(L, battery_watcher_stop)
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)

    watcher.pointee.fn = skin.luaUnref(refTable, ref: watcher.pointee.fn)
    skin.destroyGCCanary(&watcher.pointee.lsCanary)
    CFRunLoopSourceInvalidate(watcher.pointee.t)
    CFRelease(watcher.pointee.t)
    return 0
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let ptr = lua_topointer(L, 1)
    lua_pushstring(L, "\(USERDATA_TAG): (\(String(describing: ptr)))")
    return 1
}

// Metatable for created objects when _new invoked
private var battery_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: battery_watcher_start),
    luaL_Reg(name: strdup("stop"),       func: battery_watcher_stop),
    luaL_Reg(name: strdup("__gc"),       func: battery_watcher_gc),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var batteryLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: battery_watcher_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libbatterywatcher")
public func luaopen_hs_libbatterywatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &batteryLib,
                                    metaFunctions: &meta_gcLib,
                                    objectFunctions: &battery_metalib)
    return 1
}
