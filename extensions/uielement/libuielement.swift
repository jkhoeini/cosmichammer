import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.uielement"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Helper to extract HSuielement from userdata

private func getObject(from L: OpaquePointer!, at idx: Int32) -> HSuielement {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSuielement>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeUnretainedValue()
}

private func getObjectTransfer(from L: OpaquePointer!, at idx: Int32) -> HSuielement {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSuielement>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeRetainedValue()
}

// MARK: - Lua functions

/// hs.uielement.focusedElement() -> element or nil
/// Function
/// Gets the currently focused UI element
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.uielement` object or nil if no object could be found
private func uielement_focusedElement(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)
    let element = HSuielement.focusedElement()
    skin.pushNSObject(element)
    return 1
}

/// hs.uielement:isWindow() -> bool
/// Method
/// Returns whether the UI element represents a window.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the UI element is a window, otherwise false
private func uielement_iswindow(_ L: OpaquePointer!) -> Int32 {
    // NOTE: If you find yourself modifying this method, you should check hs.application and hs.window, since they contain clones of it
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let element: HSuielement = skin.toNSObject(atIndex: 1) as! HSuielement
    lua_pushboolean(L, element.isWindow ? 1 : 0)
    return 1
}

/// hs.uielement:role() -> string
/// Method
/// Returns the role of the element.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the role of the UI element
private func uielement_role(_ L: OpaquePointer!) -> Int32 {
    // NOTE: If you find yourself modifying this method, you should check hs.application and hs.window, since they contain clones of it
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let element: HSuielement = skin.toNSObject(atIndex: 1) as! HSuielement
    skin.pushNSObject(element.role)
    return 1
}

/// hs.uielement:selectedText() -> string or nil
/// Method
/// Returns the selected text in the element
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the selected text, or nil if none could be found
///
/// Notes:
///  * Many applications (e.g. Safari, Mail, Firefox) do not implement the necessary accessibility features for this to work in their web views
private func uielement_selectedText(_ L: OpaquePointer!) -> Int32 {
    // NOTE: If you find yourself modifying this method, you should check hs.application and hs.window, since they contain clones of it
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let element: HSuielement = skin.toNSObject(atIndex: 1) as! HSuielement
    skin.pushNSObject(element.selectedText)
    return 1
}

/// hs.uielement:newWatcher(handler[, userData]) -> hs.uielement.watcher or nil
/// Method
/// Creates a new watcher
///
/// Parameters:
///  * A function to be called when a watched event occurs.  The function will be passed the following arguments:
///    * element: The element the event occurred on. Note this is not always the element being watched.
///    * event: The name of the event that occurred.
///    * watcher: The watcher object being created.
///    * userData: The userData you included, if any.
///  * an optional userData object which will be included as the final argument to the callback function when it is called.
///
/// Returns:
///  * An `hs.uielement.watcher` object, or `nil` if an error occurred
private func uielement_newWatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION, LS_TANY | LS_TOPTIONAL, LS_TBREAK)

    let uiElement: HSuielement = skin.toNSObject(atIndex: 1) as! HSuielement
    let watcher = uiElement.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L) as? HSuielementWatcher
    skin.pushNSObject(watcher)

    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

private func pushHSuielement(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    guard let value = obj as? HSuielement else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSuielementFromLua(_ L: OpaquePointer!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.shared(withState: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return getObject(from: L, at: idx)
    } else {
        skin.logError("\(String(format: "expected %s object, found %s", USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))")
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func uielement_eq(_ L: OpaquePointer!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)
        let element1: HSuielement = skin.toNSObject(atIndex: 1) as! HSuielement
        let element2: HSuielement = skin.toNSObject(atIndex: 2) as! HSuielement
        isEqual = CFEqual(element1.elementRef, element2.elementRef)
    }
    lua_pushboolean(L, isEqual ? 1 : 0)
    return 1
}

// Clean up a bare uielement if it isn't needed anymore.
private func uielement_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let element = getObjectTransfer(from: L, at: 1)
    element.selfRefCount -= 1
    if element.selfRefCount == 0 {
        // element goes out of scope and is deallocated
    }

    // Remove the Metatable so future use of the variable in Lua won't think it's valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - luaL_Reg tables

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("focusedElement"), func: { uielement_focusedElement($0) }),
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("role"), func: { uielement_role($0) }),
    luaL_Reg(name: strdup("isWindow"), func: { uielement_iswindow($0) }),
    luaL_Reg(name: strdup("selectedText"), func: { uielement_selectedText($0) }),
    luaL_Reg(name: strdup("newWatcher"), func: { uielement_newWatcher($0) }),
    luaL_Reg(name: strdup("__eq"), func: { uielement_eq($0) }),
    luaL_Reg(name: strdup("__gc"), func: { uielement_gc($0) }),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libuielement")
public func luaopen_hs_libuielement(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &module_metaLib)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)
    skin.registerPushNSHelper(pushHSuielement, forClass: "HSuielement")
    skin.registerLuaObjectHelper(toHSuielementFromLua, forClass: "HSuielement", withUserdataMapping: USERDATA_TAG)

    return 1
}
