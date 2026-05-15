import Foundation
import Cocoa
import LuaSkin

private let USERDATA_TAG = "hs.distributednotifications"

private var refTable: LSRefTable = LUA_NOREF

// MARK: - HSDistNotWatcher Definition

private class HSDistNotWatcher: NSObject {
    var fnRef: Int32 = LUA_NOREF
    var object: String?
    var name: String?

    @objc func callback(_ note: NSNotification) {
        guard fnRef != LUA_NOREF && fnRef != LUA_REFNIL else { return }
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        skin.pushLuaRef(refTable, ref: fnRef)
        skin.pushNSObject(note.name.rawValue)
        skin.pushNSObject(note.object)
        skin.pushNSObject(note.userInfo)
        skin.protectedCallAndError("hs.distributednotification callback", nargs: 3, nresults: 0)
        _lua_stackguard_exit(skin.l)
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
private func distnot_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)

    let name: String? = lua_isnoneornil(L, 2) ? nil : (skin.toNSObject(atIndex: 2) as? String)
    let obj: String? = lua_isnoneornil(L, 3) ? nil : (skin.toNSObject(atIndex: 3) as? String)

    // Allocate userdata to store a pointer to the watcher
    let userData = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    userData.pointee = nil

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    let watcher = HSDistNotWatcher()
    userData.pointee = Unmanaged.passRetained(watcher).toOpaque()

    lua_pushvalue(L, 1)
    watcher.fnRef = skin.luaRef(refTable)
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
private func distnot_post(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TTABLE | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)

    let object: String? = lua_isnoneornil(L, 2) ? nil : (skin.toNSObject(atIndex: 2) as? String)
    let userInfo: [AnyHashable: Any]? = lua_isnoneornil(L, 3) ? nil : (skin.toNSObject(atIndex: 3) as? [AnyHashable: Any])

    let center = DistributedNotificationCenter.default()
    let noteName = skin.toNSObject(atIndex: 1) as! String
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
private func distnot_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
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
private func distnot_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeUnretainedValue()

    let center = DistributedNotificationCenter.default()
    let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
    center.removeObserver(watcher, name: noteName, object: watcher.object)

    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Hammerspoon Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeUnretainedValue()

    let ptr = Unmanaged.passUnretained(watcher).toOpaque()
    skin.pushNSObject("\(USERDATA_TAG): name: \(watcher.name ?? "nil") object: \(watcher.object ?? "nil") (\(ptr))")
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSDistNotWatcher>.fromOpaque(userData.pointee!).takeRetainedValue()

    let center = DistributedNotificationCenter.default()
    let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
    center.removeObserver(watcher, name: noteName, object: watcher.object)

    watcher.fnRef = skin.luaUnref(refTable, ref: watcher.fnRef)

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)

    return 0
}

private var distributednotificationslib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: distnot_new),
    luaL_Reg(name: strdup("post"), func: distnot_post),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"), func: distnot_start),
    luaL_Reg(name: strdup("stop"), func: distnot_stop),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libdistributednotifications")
public func luaopen_hs_libdistributednotifications(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &distributednotificationslib, metaFunctions: nil)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)

    return 1
}
