import Cocoa
import CLua
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
    var generation: UInt64 = 0
}

private func callback(_ info: UnsafeMutableRawPointer?) {
    guard let info = info else { return }
    let watcher = info.assumingMemoryBound(to: BatteryWatcher.self)

    guard lua_isStateGenerationValid(watcher.pointee.generation) else { return }

    let L = lua_getCurrentState()!

    if watcher.pointee.fn != Int32(LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(watcher.pointee.fn))
        if lua_pcall(L, 0, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }
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
///  * Because the callback function accepts no arguments, tracking of state of changing battery attributes is the responsibility of the user (see https://github.com/jkhoeini/cosmichammer/issues/166 for discussion)
private func battery_watcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let watcherPtr = lua_newuserdata(L, MemoryLayout<BatteryWatcher>.size)!
        .assumingMemoryBound(to: BatteryWatcher.self)
    watcherPtr.pointee = BatteryWatcher()

    lua_pushvalue(L, 1)
    watcherPtr.pointee.fn = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    watcherPtr.pointee.t = IOPSNotificationCreateRunLoopSource(callback, watcherPtr)?.takeRetainedValue()
    watcherPtr.pointee.started = false
    watcherPtr.pointee.generation = lua_currentStateGeneration()
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
private func battery_watcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func battery_watcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)
    lua_settop(L, 1)

    if !watcher.pointee.started { return 1 }

    watcher.pointee.started = false
    CFRunLoopRemoveSource(CFRunLoopGetMain(), watcher.pointee.t, .commonModes)
    return 1
}

private func battery_watcher_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)

    lua_pushcfunction(L, battery_watcher_stop)
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, watcher.pointee.fn)
    watcher.pointee.fn = Int32(LUA_NOREF)
    CFRunLoopSourceInvalidate(watcher.pointee.t)
    // CFRelease not needed in Swift (ARC)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
public func luaopen_hs_libbatterywatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &battery_metalib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(batteryLib.count - 1))
    luaL_setfuncs(L, &batteryLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(meta_gcLib.count - 1))
    luaL_setfuncs(L, &meta_gcLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
