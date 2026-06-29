import Cocoa
import CLua
import Lua
import IOKit.ps
import HSDSTCore

/// === hs.battery.watcher ===
///
/// Watch for battery/power state changes
///
/// This module is based primarily on code from the previous incarnation of Mjolnir.

// Common Code

private let USERDATA_TAG = "hs.battery.watcher"
private var refTable: Int32 = 0
private var activeBatteryWatcherCount = 0

private func recordActiveBatteryWatcherGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.battery.watcher.active",
        kind: .gauge,
        value: Double(activeBatteryWatcherCount),
        attributes: [:],
        unit: "1"
    )
}

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
        if luaTelemetryPCall(L, nargs: 0, nresults: 0, callbackName: "hs.battery.watcher") != LUA_OK {
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
    activeBatteryWatcherCount += 1
    recordActiveBatteryWatcherGauge(L)
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
    activeBatteryWatcherCount = max(0, activeBatteryWatcherCount - 1)
    recordActiveBatteryWatcherGauge(L)
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

        // __gc: stop watcher, clean up callback, invalidate run loop source, deinit struct
        L.push { (L: LuaState) throws -> CInt in
            let watcher = luaL_checkudata(L, 1, USERDATA_TAG)!
                .assumingMemoryBound(to: BatteryWatcher.self)

            if watcher.pointee.started {
                watcher.pointee.started = false
                CFRunLoopRemoveSource(CFRunLoopGetMain(), watcher.pointee.t, .commonModes)
                activeBatteryWatcherCount = max(0, activeBatteryWatcherCount - 1)
                recordActiveBatteryWatcherGauge(L)
            }

            callbackMap[UnsafeMutableRawPointer(watcher)] = nil
            CFRunLoopSourceInvalidate(watcher.pointee.t)
            // Deinitialize the struct so ARC can release the CFRunLoopSource (and any
            // other ARC-managed fields). Without this, Lua frees the raw memory and
            // ARC never sees the release.
            watcher.deinitialize(count: 1)
            return 0
        }
        lua_setfield(L, -2, "__gc")

        // __tostring
        L.push { (L: LuaState) throws -> CInt in
            let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
            L.push(desc)
            return 1
        }
        lua_setfield(L, -2, "__tostring")

        // __type and __name for lsunit.lua assertIsUserdataOfType
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(battery_watcher_new)
        lua_setfield(L, -2, "new")
    }
}
