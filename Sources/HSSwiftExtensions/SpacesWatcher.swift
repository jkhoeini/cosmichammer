import Foundation
import CLua
import Lua
import Cocoa
import CoreGraphics

/// === hs.spaces.watcher ===
///
/// Watches for the current Space being changed
/// NOTE: This extension determines the number of a Space, using OS X APIs that have been deprecated since 10.8 and will likely be removed in a future release. You should not depend on Space numbers being around forever!

private let USERDATA_TAG = "hs.spaces.watcher"

// MARK: - Userdata Struct

private struct SpaceWatcherData {
    var selfRef: Int32
    var running: Bool
    var fn: Int32
    var obj: UnsafeMutableRawPointer?
}

// MARK: - SpaceWatcher Class

private class SpaceWatcher: NSObject {
    var object: UnsafeMutablePointer<SpaceWatcherData>

    init(object: UnsafeMutablePointer<SpaceWatcherData>) {
        self.object = object
        super.init()
    }

    // Call the lua callback function.
    func callback(dict: NSDictionary?, space: Int32) {
        if object.pointee.fn != LUA_NOREF {
            let L = lua_getCurrentState()!

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(object.pointee.fn))
            lua_pushinteger(L, lua_Integer(space))
            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                lua_pop(L, 1)
            }
        }
    }

    @objc func spaceChanged(_ notification: NSNotification) {
        let spaceID = SLSGetActiveSpace(SLSMainConnectionID())
        let currentSpace = Int32(clamping: spaceID)

        callback(dict: notification.userInfo as NSDictionary?, space: currentSpace)
    }
}

// MARK: - Module Functions

/// hs.spaces.watcher.new(handler) -> watcher
/// Constructor
/// Creates a new watcher for Space change events
///
/// Parameters:
///  * handler - A function to be called when the active Space changes. It should accept one argument, which will be the number of the new Space (or -1 if the number cannot be determined)
///
/// Returns:
///  * An `hs.spaces.watcher` object
private func space_watcher_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let spaceWatcher = lua_newuserdata(L, MemoryLayout<SpaceWatcherData>.size)!
        .assumingMemoryBound(to: SpaceWatcherData.self)

    lua_pushvalue(L, 1)
    spaceWatcher.pointee.fn = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    spaceWatcher.pointee.running = false
    spaceWatcher.pointee.selfRef = LUA_NOREF

    let watcher = SpaceWatcher(object: spaceWatcher)
    spaceWatcher.pointee.obj = Unmanaged.passRetained(watcher).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

/// hs.spaces.watcher:start()
/// Method
/// Starts the Spaces watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The watcher object
private func space_watcher_start(_ L: LuaState) throws -> CInt {
    let spaceWatcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: SpaceWatcherData.self)
    lua_settop(L, 1)
    lua_pushvalue(L, 1)

    if spaceWatcher.pointee.running {
        return 1
    }

    spaceWatcher.pointee.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    spaceWatcher.pointee.running = true

    let center = NSWorkspace.shared.notificationCenter
    let observer = Unmanaged<SpaceWatcher>.fromOpaque(spaceWatcher.pointee.obj!).takeUnretainedValue()
    center.addObserver(
        observer,
        selector: #selector(SpaceWatcher.spaceChanged(_:)),
        name: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil
    )

    lua_pushvalue(L, 1)
    return 1
}

/// hs.spaces.watcher:stop()
/// Method
/// Stops the Spaces watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The watcher object
private func space_watcher_stop(_ L: LuaState) throws -> CInt {
    let spaceWatcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: SpaceWatcherData.self)
    lua_settop(L, 1)
    lua_pushvalue(L, 1)

    if !spaceWatcher.pointee.running {
        return 1
    }

    spaceWatcher.pointee.running = false
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, spaceWatcher.pointee.selfRef)
    spaceWatcher.pointee.selfRef = LUA_NOREF
    let observer = Unmanaged<SpaceWatcher>.fromOpaque(spaceWatcher.pointee.obj!).takeUnretainedValue()
    NSWorkspace.shared.notificationCenter.removeObserver(observer)
    return 1
}

private func space_watcher_gc(_ L: LuaState) throws -> CInt {
    let spaceWatcher = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: SpaceWatcherData.self)

    _ = try space_watcher_stop(L)
    lua_pop(L, 1)  // pop stop's self-return

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, spaceWatcher.pointee.fn)
    spaceWatcher.pointee.fn = LUA_NOREF

    let _: SpaceWatcher = Unmanaged.fromOpaque(spaceWatcher.pointee.obj!).takeRetainedValue()
    spaceWatcher.pointee.obj = nil
    return 0
}

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    lua_pushstring(L, "\(USERDATA_TAG): (\(lua_topointer(L, 1)!))")
    return 1
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libspaces_watcher")
public func luaopen_hs_libspaces_watcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")  // mt.__index = mt
        L.push(space_watcher_start)
        lua_setfield(L, -2, "start")
        L.push(space_watcher_stop)
        lua_setfield(L, -2, "stop")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(space_watcher_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(space_watcher_new)
        lua_setfield(L, -2, "new")
    }
}
