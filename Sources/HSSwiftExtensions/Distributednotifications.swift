import Foundation
import CLua
import Lua
import Cocoa

private let USERDATA_TAG = "hs.distributednotifications"

// MARK: - HSDistNotWatcher Definition

private class HSDistNotWatcher: NSObject {
    var fnRef: Int32 = LUA_NOREF
    var object: String?
    var name: String?

    @objc func callback(_ note: NSNotification) {
        guard fnRef != LUA_NOREF && fnRef != LUA_REFNIL else { return }
        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fnRef))
        lua_pushany(L, note.name.rawValue)
        lua_pushany(L, note.object)
        lua_pushany(L, note.userInfo)
        if lua_pcall(L, 3, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions

/// hs.distributednotifications.new(callback[, name[, object]]) -> object
/// Constructor
/// Creates a new NSDistributedNotificationCenter watcher
///
/// Parameters:
///  * callback - A function to be called when a matching notification arrives. The function should accept one argument:
///   * notificationName - A string containing the name of the notification
///  * name - An optional string containing the name of notifications to watch for. A value of `nil` will cause all notifications to be watched on macOS versions earlier than Catalina. Defaults to `nil`.
///  * object - An optional string containing the name of sending objects to watch for. A value of `nil` will cause all sending objects to be watched. Defaults to `nil`.
///
/// Returns:
///  * An `hs.distributednotifications` object
///
/// Notes:
///  * On Catalina and above, it is no longer possible to observe all notifications - the `name` parameter is effectively now required. See https://mjtsai.com/blog/2019/10/04/nsdistributednotificationcenter-no-longer-supports-nil-names/
private func distnot_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let name: String? = lua_isnoneornil(L, 2) ? nil : (lua_type(L, 2) == LUA_TSTRING ? String(cString: lua_tostring(L, 2)!) : nil)
    let obj: String? = lua_isnoneornil(L, 3) ? nil : (lua_type(L, 3) == LUA_TSTRING ? String(cString: lua_tostring(L, 3)!) : nil)

    // Allocate userdata to store a pointer to the watcher
    let userData = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    userData.pointee = nil

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    let watcher = HSDistNotWatcher()
    userData.pointee = Unmanaged.passRetained(watcher).toOpaque()

    lua_pushvalue(L, 1)
    watcher.fnRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    watcher.name = name
    watcher.object = obj

    return 1
}

// MARK: - Module Methods

/// hs.distributednotifications.post(name[, sender[, userInfo]])
/// Function
/// Sends a distributed notification
///
/// Parameters:
///  * name - A string containing the name of the notification
///  * sender - An optional string containing the name of the sender of the notification (in the form `com.domain.application.foo`). Defaults to nil.
///  * userInfo - An optional table containing additional information to post with the notification. Defaults to nil.
///
/// Returns:
///  * None
private func distnot_post(_ L: LuaState) throws -> CInt {
    guard lua_type(L, 1) == LUA_TSTRING else {
        throw LuaCallError("expected string for argument 1")
    }

    let noteName = String(cString: lua_tostring(L, 1)!)
    let object: String? = (lua_type(L, 2) == LUA_TSTRING) ? String(cString: lua_tostring(L, 2)!) : nil
    let userInfo: [AnyHashable: Any]? = (lua_type(L, 3) == LUA_TTABLE) ? (lua_tovalue(L, at: 3) as? [String: Any]) : nil

    let center = DistributedNotificationCenter.default()
    center.postNotificationName(
        NSNotification.Name(noteName),
        object: object,
        userInfo: userInfo,
        deliverImmediately: true
    )

    return 0
}

/// hs.distributednotifications:start() -> object
/// Method
/// Starts a NSDistributedNotificationCenter watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.distributednotifications` object
private func distnot_start(_ L: LuaState) throws -> CInt {
    let userData = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeUnretainedValue()

    let center = DistributedNotificationCenter.default()
    let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
    center.addObserver(
        watcher,
        selector: #selector(HSDistNotWatcher.callback(_:)),
        name: noteName,
        object: watcher.object,
        suspensionBehavior: .deliverImmediately
    )

    lua_pushvalue(L, 1)
    return 1
}

/// hs.distributednotifications:stop() -> object
/// Method
/// Stops a NSDistributedNotificationCenter watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.distributednotifications` object
private func distnot_stop(_ L: LuaState) throws -> CInt {
    let userData = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeUnretainedValue()

    let center = DistributedNotificationCenter.default()
    let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
    center.removeObserver(watcher, name: noteName, object: watcher.object)

    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Cosmic Hammer Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let userData = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeUnretainedValue()

    let ptr = Unmanaged.passUnretained(watcher).toOpaque()
    lua_pushstring(L, "\(USERDATA_TAG): name: \(watcher.name ?? "nil") object: \(watcher.object ?? "nil") (\(ptr))")
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    let userData = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeRetainedValue()

    let center = DistributedNotificationCenter.default()
    let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
    center.removeObserver(watcher, name: noteName, object: watcher.object)

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, watcher.fnRef)
    watcher.fnRef = LUA_NOREF

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)

    return 0
}

@_cdecl("luaopen_hs_libdistributednotifications")
public func luaopen_hs_libdistributednotifications(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")  // mt.__index = mt
        L.push(distnot_start)
        lua_setfield(L, -2, "start")
        L.push(distnot_stop)
        lua_setfield(L, -2, "stop")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 2)
        L.push(distnot_new)
        lua_setfield(L, -2, "new")
        L.push(distnot_post)
        lua_setfield(L, -2, "post")
    }
}
