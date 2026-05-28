import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.uielement.watcher"
private var refTable: LSRefTable = LUA_NOREF

private func getWatcher(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> (NSObject & HSuielementWatcherProtocol)? {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue() as? NSObject & HSuielementWatcherProtocol
}

private func watcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    guard let watcher = skin.toNSObject(atIndex: 1) as? HSuielementWatcherProtocol else { return 0 }
    watcher.watcherRef = skin.luaRef(refTable, at: 1)
    if let events = skin.toNSObject(atIndex: 2) as? [String] {
        watcher.start(events, withState: L)
    }
    lua_pushvalue(L, 1)
    return 1
}

private func watcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let watcher = skin.toNSObject(atIndex: 1) as? HSuielementWatcherProtocol else { return 0 }
    watcher.stop()
    watcher.watcherRef = skin.luaUnref(refTable, ref: watcher.watcherRef)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.uielement.watcher:pid() -> number
/// Method
/// Returns the PID of the element being watched
private func watcher_pid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let watcher = skin.toNSObject(atIndex: 1) as? HSuielementWatcherProtocol else { return 0 }
    lua_pushnumber(L, lua_Number(watcher.pid))
    return 1
}

/// hs.uielement.watcher:element() -> object
/// Method
/// Returns the element the watcher is watching.
private func watcher_element(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let watcher = skin.toNSObject(atIndex: 1) as? HSuielementWatcherProtocol else { return 0 }

    let element = HSuielement(withElement: watcher.elementRef)

    if element.isWindow {
        let window = HSwindow(axuiElementRef: watcher.elementRef)
        skin.pushNSObject(window)
        return 1
    } else if element.isApplication {
        let app = HSapplication(pid: watcher.pid, withState: L)
        skin.pushNSObject(app)
        return 1
    }
    skin.pushNSObject(element)
    return 1
    lua_pushnil(L)
    return 1
}

private func watcher_watchDestroyed(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    guard let watcher = skin.toNSObject(atIndex: 1) as? HSuielementWatcherProtocol else { return 0 }

    if lua_type(L, 2) == LUA_TBOOLEAN {
        watcher.watchDestroyed = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, watcher.watchDestroyed ? 1 : 0)
    }
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSuielementWatcher(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let value = obj as? NSObject & HSuielementWatcherProtocol else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value as NSObject).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSuielementWatcherFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let rawPtr = ptr.pointee else { return nil }
        return Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
    } else {
        skin.logError("\(USERDATA_TAG): expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, desc)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        if let w1 = skin.toNSObject(atIndex: 1) as? NSObject,
           let w2 = skin.toNSObject(atIndex: 2) as? NSObject {
            isEqual = w1.isEqual(w2)
        }
    }
    lua_pushboolean(L, isEqual ? 1 : 0)
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let watcher = Unmanaged<NSObject>.fromOpaque(rawPtr).takeRetainedValue()
        if let w = watcher as? HSuielementWatcherProtocol {
            var tmplsCanary = w.lsCanary
            skin.destroy(&tmplsCanary)
            w.lsCanary = tmplsCanary

            w.selfRefCount -= 1
            if w.selfRefCount == 0 {
                w.stop()
                w.handlerRef = skin.luaUnref(w.refTable, ref: w.handlerRef)
                w.userDataRef = skin.luaUnref(w.refTable, ref: w.userDataRef)
            }
        }
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Registration

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_start"),          func: watcher_start),
    luaL_Reg(name: strdup("_stop"),           func: watcher_stop),
    luaL_Reg(name: strdup("pid"),             func: watcher_pid),
    luaL_Reg(name: strdup("element"),         func: watcher_element),
    luaL_Reg(name: strdup("watchDestroyed"),  func: watcher_watchDestroyed),
    luaL_Reg(name: strdup("__tostring"),      func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),            func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),            func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libuielementwatcher")
public func luaopen_hs_libuielementwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(module_metaLib.count - 1))
    luaL_setfuncs(L, &module_metaLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
