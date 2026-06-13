import Cocoa
import CLua
import Lua
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

/// Module-level map from userdata pointer to LuaValue callback.
/// We cannot store a LuaValue (class) inside a struct that lives in
/// lua_newuserdata raw memory, so we keep the association here.
private var callbackMap: [UnsafeMutableRawPointer: LuaValue] = [:]

private struct BatteryWatcher {
    var t: CFRunLoopSource!
    var started: Bool = false
    var generation: UInt64 = 0
}

private func callback(_ info: UnsafeMutableRawPointer?) {
    guard let info = info else { return }
    let watcher = info.assumingMemoryBound(to: BatteryWatcher.self)

    guard lua_isStateGenerationValid(watcher.pointee.generation) else { return }

    let L = lua_getCurrentState()!

    if let cb = callbackMap[info] {
        cb.push(onto: L)
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
private func battery_watcher_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let watcherPtr = lua_newuserdata(L, MemoryLayout<BatteryWatcher>.size)!
        .assumingMemoryBound(to: BatteryWatcher.self)
    watcherPtr.pointee = BatteryWatcher()

    callbackMap[UnsafeMutableRawPointer(watcherPtr)] = L.ref(index: 1)

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
private func battery_watcher_start(_ L: LuaState) throws -> CInt {
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
private func battery_watcher_stop(_ L: LuaState) throws -> CInt {
    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)
    lua_settop(L, 1)

    if !watcher.pointee.started { return 1 }

    watcher.pointee.started = false
    CFRunLoopRemoveSource(CFRunLoopGetMain(), watcher.pointee.t, .commonModes)
    return 1
}

private func battery_watcher_gc(_ L: LuaState) throws -> CInt {
    let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: BatteryWatcher.self)

    _ = try battery_watcher_stop(L)

    callbackMap[UnsafeMutableRawPointer(watcher)] = nil
    CFRunLoopSourceInvalidate(watcher.pointee.t)
    // Deinitialize the struct so ARC can release the CFRunLoopSource (and any
    // other ARC-managed fields). Without this, Lua frees the raw memory and
    // ARC never sees the release.
    watcher.deinitialize(count: 1)
    return 0
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    return 0
}

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let ptr = lua_topointer(L, 1)
    lua_pushstring(L, "\(USERDATA_TAG): (\(String(describing: ptr)))")
    return 1
}

@_cdecl("luaopen_hs_libbatterywatcher")
public func luaopen_hs_libbatterywatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(battery_watcher_start)
        lua_setfield(L, -2, "start")
        L.push(battery_watcher_stop)
        lua_setfield(L, -2, "stop")
        L.push(battery_watcher_gc)
        lua_setfield(L, -2, "__gc")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(battery_watcher_new)
        lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
