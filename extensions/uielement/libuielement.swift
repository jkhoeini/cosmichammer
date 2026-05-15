import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.uielement"
private var refTable: LSRefTable = LUA_NOREF

private func getObject(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> (NSObject & HSuielementProtocol)? {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue() as? NSObject & HSuielementProtocol
}

/// hs.uielement.focusedElement() -> element or nil
/// Function
/// Gets the currently focused UI element
private func uielement_focusedElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    guard let cls = HSuicore.uielementClass else {
        lua_pushnil(L)
        return 1
    }
    let element = (cls as AnyObject).perform(Selector(("focusedElement")))?.takeUnretainedValue()
    skin.pushNSObject(element)
    return 1
}

/// hs.uielement:isWindow() -> bool
/// Method
/// Returns whether the UI element represents a window.
private func uielement_iswindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let element = skin.toNSObject(atIndex: 1) as? HSuielementProtocol else {
        lua_pushboolean(L, 0)
        return 1
    }
    lua_pushboolean(L, element.isWindow ? 1 : 0)
    return 1
}

/// hs.uielement:role() -> string
/// Method
/// Returns the role of the element.
private func uielement_role(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let element = skin.toNSObject(atIndex: 1) as? HSuielementProtocol else {
        lua_pushnil(L)
        return 1
    }
    skin.pushNSObject(element.role as NSString)
    return 1
}

/// hs.uielement:selectedText() -> string or nil
/// Method
/// Returns the selected text in the element
private func uielement_selectedText(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let element = skin.toNSObject(atIndex: 1) as? HSuielementProtocol else {
        lua_pushnil(L)
        return 1
    }
    skin.pushNSObject(element.selectedText as NSString?)
    return 1
}

/// hs.uielement:newWatcher(handler[, userData]) -> hs.uielement.watcher or nil
/// Method
/// Creates a new watcher
private func uielement_newWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION, LS_TANY | LS_TOPTIONAL, LS_TBREAK)

    guard let uiElement = skin.toNSObject(atIndex: 1) as? HSuielementProtocol else {
        lua_pushnil(L)
        return 1
    }
    let watcher = uiElement.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)
    skin.pushNSObject(watcher)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSuielement(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let value = obj as? NSObject & HSuielementProtocol else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value as NSObject).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSuielementFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
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

private func uielement_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        if let e1 = skin.toNSObject(atIndex: 1) as? HSuielementProtocol,
           let e2 = skin.toNSObject(atIndex: 2) as? HSuielementProtocol {
            isEqual = CFEqual(e1.elementRef, e2.elementRef)
        }
    }
    lua_pushboolean(L, isEqual ? 1 : 0)
    return 1
}

private func uielement_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let element = Unmanaged<NSObject>.fromOpaque(rawPtr).takeRetainedValue()
        if let proto = element as? HSuielementProtocol {
            proto.selfRefCount -= 1
        }
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Registration

private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("focusedElement"), func: uielement_focusedElement),
    luaL_Reg(name: nil, func: nil),
]

private let module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private let userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("role"),         func: uielement_role),
    luaL_Reg(name: strdup("isWindow"),     func: uielement_iswindow),
    luaL_Reg(name: strdup("selectedText"), func: uielement_selectedText),
    luaL_Reg(name: strdup("newWatcher"),   func: uielement_newWatcher),
    luaL_Reg(name: strdup("__eq"),         func: uielement_eq),
    luaL_Reg(name: strdup("__gc"),         func: uielement_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libuielement")
public func luaopen_hs_libuielement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: moduleLib,
                                    metaFunctions: module_metaLib,
                                    objectFunctions: userdata_metaLib)
    skin.registerPushNSHelper(pushHSuielement, forClass: "HSuielement")
    skin.registerLuaObjectHelper(toHSuielementFromLua, forClass: "HSuielement",
                                 withUserdataMapping: USERDATA_TAG)
    return 1
}
