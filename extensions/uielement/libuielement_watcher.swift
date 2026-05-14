//
//  libuielement_watcher.swift
//  Hammerspoon
//
//  Translated from HSuielementwatcher.m
//  Created by Chris Jones on 12/01/2018.
//  Copyright (c) 2018 Hammerspoon. All rights reserved.
//

import LuaSkin

private let USERDATA_TAG = "hs.uielement.watcher"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Helper to extract HSuielementWatcher from userdata

private func getObject(from L: OpaquePointer!, at idx: Int32) -> HSuielementWatcher {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSuielementWatcher>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeUnretainedValue()
}

private func getObjectTransfer(from L: OpaquePointer!, at idx: Int32) -> HSuielementWatcher {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSuielementWatcher>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeRetainedValue()
}

// MARK: - Lua functions

// This is wrapped, and documented, in init.lua
private func watcher_start(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    let watcher: HSuielementWatcher = skin.toNSObject(atIndex: 1) as! HSuielementWatcher
    watcher.watcherRef = skin.luaRef(LUA_REGISTRYINDEX, atIndex: 1)
    watcher.start(skin.toNSObject(atIndex: 2) as! [String], withState: L)
    lua_pushvalue(L, 1)
    return 1
}

// This is wrapped, and documented, in init.lua
private func watcher_stop(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let watcher: HSuielementWatcher = skin.toNSObject(atIndex: 1) as! HSuielementWatcher
    watcher.stop()
    watcher.watcherRef = skin.luaUnref(LUA_REGISTRYINDEX, ref: watcher.watcherRef)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.uielement.watcher:pid() -> number
/// Method
/// Returns the PID of the element being watched
///
/// Parameters:
///  * None
///
/// Returns:
///  * The PID of the element being watched
private func watcher_pid(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let watcher: HSuielementWatcher = skin.toNSObject(atIndex: 1) as! HSuielementWatcher
    lua_pushnumber(L, lua_Number(watcher.pid))
    return 1
}

/// hs.uielement.watcher:element() -> object
/// Method
/// Returns the element the watcher is watching.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The element the watcher is watching.
private func watcher_element(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let watcher: HSuielementWatcher = skin.toNSObject(atIndex: 1) as! HSuielementWatcher
    let element = HSuielement(elementRef: watcher.elementRef)!

    if element.isWindow {
        let window = HSwindow(axuiElementRef: watcher.elementRef)!
        skin.pushNSObject(window)
    } else if element.isApplication {
        let application = HSapplication(pid: watcher.pid, withState: L)!
        skin.pushNSObject(application)
    } else {
        skin.pushNSObject(element)
    }
    return 1
}

// This is internal API only and does not require documentation
private func watcher_watchDestroyed(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let watcher: HSuielementWatcher = skin.toNSObject(atIndex: 1) as! HSuielementWatcher

    if lua_type(L, 2) == LUA_TBOOLEAN {
        watcher.watchDestroyed = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, watcher.watchDestroyed ? 1 : 0)
    }

    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

private func pushHSuielementWatcher(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    guard let value = obj as? HSuielementWatcher else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSuielementWatcherFromLua(_ L: OpaquePointer!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.shared(withState: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return getObject(from: L, at: idx)
    } else {
        skin.logError("\(String(format: "expected %s object, found %s", USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))")
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    lua_pushstring(L, "\(USERDATA_TAG): \(lua_topointer(L, 1)!)")
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)
        let watcher1: HSuielementWatcher = skin.toNSObject(atIndex: 1) as! HSuielementWatcher
        let watcher2: HSuielementWatcher = skin.toNSObject(atIndex: 2) as! HSuielementWatcher
        isEqual = watcher1.isEqual(watcher2)
    }
    lua_pushboolean(L, isEqual ? 1 : 0)
    return 1
}

// Perform cleanup if the watcher is not required anymore.
private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let watcher = getObjectTransfer(from: L, at: 1)

    var tmpLSCanary = watcher.lsCanary
    skin.destroyGCCanary(&tmpLSCanary)
    watcher.lsCanary = tmpLSCanary

    watcher.selfRefCount -= 1
    if watcher.selfRefCount == 0 {
        watcher.stop()
        watcher.handlerRef = skin.luaUnref(watcher.refTable, ref: watcher.handlerRef)
        watcher.userDataRef = skin.luaUnref(watcher.refTable, ref: watcher.userDataRef)
        // watcher goes out of scope and is deallocated
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - luaL_Reg tables

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private var userdata_metaLibArray: [luaL_Reg] = [
    luaL_Reg(name: strdup("_start"), func: { watcher_start($0) }),
    luaL_Reg(name: strdup("_stop"), func: { watcher_stop($0) }),
    luaL_Reg(name: strdup("pid"), func: { watcher_pid($0) }),
    luaL_Reg(name: strdup("element"), func: { watcher_element($0) }),
    luaL_Reg(name: strdup("watchDestroyed"), func: { watcher_watchDestroyed($0) }),
    luaL_Reg(name: strdup("__tostring"), func: { userdata_tostring($0) }),
    luaL_Reg(name: strdup("__eq"), func: { userdata_eq($0) }),
    luaL_Reg(name: strdup("__gc"), func: { userdata_gc($0) }),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libuielementwatcher")
public func luaopen_hs_libuielementwatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    refTable = skin.registerLibraryWithObject(USERDATA_TAG,
                                              functions: &moduleLib,
                                              metaFunctions: &module_metaLib,
                                              objectFunctions: &userdata_metaLibArray)

    skin.registerPushNSHelper(pushHSuielementWatcher,
                              forClass: "HSuielementWatcher")

    skin.registerLuaObjectHelper(toHSuielementWatcherFromLua,
                                 forClass: "HSuielementWatcher",
                                 withUserdataMapping: USERDATA_TAG)

    return 1
}
