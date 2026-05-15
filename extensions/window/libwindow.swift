import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.window"
private var refTable: LSRefTable = LUA_NOREF

@_silgen_name("CGSSetDebugOptions")
private func cgsSetDebugOptions(_ options: Int32)

private let kCGSDebugOptionNormal: Int32 = 0
private let kCGSDebugOptionNoShadows: Int32 = 16384

private func getWindow(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSwindowProtocol? {
    let skin = LuaSkin.skin(with: L)
    return skin.toNSObject(at: idx) as? HSwindowProtocol
}

// MARK: - Helpers

private var systemWideElement: AXUIElement = {
    AXUIElementCreateSystemWide()
}()

// MARK: - Module Functions

/// hs.window.list(allWindows) -> table
/// Function
/// Gets a table containing all the window data retrieved from CGWindowListCreate.
private func window_list(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let allWindows = lua_toboolean(L, 1) != 0
    let skin = LuaSkin.skin(with: L)

    var windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [NSDictionary] ?? []

    if !allWindows {
        var dockWindowNumber: CGWindowID = 0
        for win in windows {
            if let name = win[kCGWindowName as String] as? String, name == "Dock",
               let num = win[kCGWindowNumber as String] as? NSNumber {
                dockWindowNumber = CGWindowID(num.uint32Value)
                break
            }
        }
        if dockWindowNumber != 0 {
            windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenBelowWindow, .excludeDesktopElements],
                dockWindowNumber
            ) as? [NSDictionary] ?? []
        }
    }

    skin.pushNSObject(windows as NSArray)
    return 1
}

/// hs.window.timeout(value) -> boolean
/// Function
/// Sets the timeout value used in the accessibility API.
private func window_timeout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TNUMBER, LS_TBREAK)
    let value = Float(lua_tonumber(L, 1))
    let result = AXUIElementSetMessagingTimeout(systemWideElement, value)
    if result == .illegalArgument {
        LuaSkin.skin(with: nil).logError("hs.window.timeout() - One or more of the arguments is an illegal value (timeout values must be positive).")
        lua_pushboolean(L, 0)
        return 1
    }
    if result == .invalidUIElement {
        LuaSkin.skin(with: nil).logError("hs.window.timeout() - The AXUIElementRef is invalid.")
        lua_pushboolean(L, 0)
        return 1
    }
    lua_pushboolean(L, 1)
    return 1
}

/// hs.window.focusedWindow() -> window
/// Constructor
/// Returns the window that has keyboard/mouse focus
private func window_focusedwindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    if let windowClass = HSuicore.windowClass {
        let result = (windowClass as AnyObject).perform(Selector(("focusedWindow")))?.takeUnretainedValue()
        skin.pushNSObject(result)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.window.setShadows(shadows)
/// Function
/// Enables/Disables window shadows
private func window_setShadows(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TBOOLEAN)
    let shadows = lua_toboolean(L, 1) != 0
    cgsSetDebugOptions(shadows ? kCGSDebugOptionNormal : kCGSDebugOptionNoShadows)
    return 0
}

/// hs.window.snapshotForID(ID [, keepTransparency]) -> hs.image-object
/// Function
/// Returns a snapshot of the window specified by the ID
private func window_snapshotForID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TNUMBER | LS_TSTRING, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let windowID = CGWindowID(lua_tointeger(L, 1))
    let keepTransparency = lua_toboolean(L, 2) != 0
    if let windowClass = HSuicore.windowClass {
        let result = (windowClass as AnyObject).perform(
            Selector(("snapshotForID:keepTransparency:")),
            with: NSNumber(value: windowID),
            with: NSNumber(value: keepTransparency)
        )?.takeUnretainedValue()
        skin.pushNSObject(result)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__orderedwinids(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    if let windowClass = HSuicore.windowClass {
        let result = (windowClass as AnyObject).perform(Selector(("orderedWindowIDs")))?.takeUnretainedValue()
        skin.pushNSObject(result)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Instance Methods

private func window_title(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    skin.pushNSObject(win.title() as NSString?)
    return 1
}

private func window_subrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    skin.pushNSObject(win.subRole() as NSString?)
    return 1
}

private func window_role(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    skin.pushNSObject(win.role() as NSString?)
    return 1
}

private func window_isstandard(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushboolean(L, 0); return 1 }
    lua_pushboolean(L, win.isStandard() ? 1 : 0)
    return 1
}

private func window__topleft(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    skin.pushNSPoint(win.getTopLeft())
    return 1
}

private func window__size(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    skin.pushNSSize(win.getSize())
    return 1
}

private func window__settopleft(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setTopLeft(skin.tableToPoint(at: 2))
    lua_pushvalue(L, 1)
    return 1
}

private func window__setsize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setSize(skin.tableToSize(at: 2))
    lua_pushvalue(L, 1)
    return 1
}

private func window__setframe(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setFrame(skin.tableToRect(at: 2))
    lua_pushvalue(L, 1)
    return 1
}

private func window__togglezoom(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.toggleZoom()
    lua_pushvalue(L, 1)
    return 1
}

private func window_getZoomButtonRect(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    skin.pushNSRect(win.getZoomButtonRect())
    return 1
}

private func window_isMaximizable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }

    var button: CFTypeRef?
    var isEnabled: CFTypeRef?

    guard AXUIElementCopyAttributeValue(win.elementRef, kAXZoomButtonAttribute as CFString, &button) == .success,
          let buttonElement = button,
          AXUIElementCopyAttributeValue(buttonElement as! AXUIElement, kAXEnabledAttribute as CFString, &isEnabled) == .success else {
        lua_pushnil(L)
        return 1
    }

    lua_pushboolean(L, CFBooleanGetValue(isEnabled as! CFBoolean) ? 1 : 0)
    return 1
}

private func window__close(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushboolean(L, 0); return 1 }
    lua_pushboolean(L, win.close() ? 1 : 0)
    return 1
}

private func window_focustab(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushboolean(L, 0); return 1 }
    let tabIndex = Int32(lua_tointeger(L, 2))
    lua_pushboolean(L, win.focusTab(tabIndex) ? 1 : 0)
    return 1
}

private func window_tabcount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushinteger(L, 0); return 1 }
    lua_pushinteger(L, lua_Integer(win.getTabCount()))
    return 1
}

private func window__setfullscreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setFullscreen(lua_toboolean(L, 2) != 0)
    lua_pushvalue(L, 1)
    return 1
}

private func window_isfullscreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushboolean(L, win.isFullscreen() ? 1 : 0)
    return 1
}

private func window__minimize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setMinimized(true)
    lua_pushvalue(L, 1)
    return 1
}

private func window__unminimize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setMinimized(false)
    lua_pushvalue(L, 1)
    return 1
}

private func window_isminimized(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushboolean(L, 0); return 1 }
    lua_pushboolean(L, win.isMinimized() ? 1 : 0)
    return 1
}

private func window_pid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushinteger(L, lua_Integer(win.pid))
    return 1
}

private func window_application(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }

    lua_settop(L, 0)

    if let app = HSapplication(pid: win.pid, withState: L) {
        skin.pushNSObject(app)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_becomemain(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.becomeMain()
    lua_pushvalue(L, 1)
    return 1
}

private func window_raise(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.raise()
    lua_pushvalue(L, 1)
    return 1
}

private func window_id(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushinteger(L, lua_Integer(win.winID))
    return 1
}

private func window_snapshot(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let keepTransparency = lua_toboolean(L, 2) != 0
    skin.pushNSObject(win.snapshot(keepTransparency))
    return 1
}

// MARK: - hs.uielement methods on hs.window

private func window_uielement_isApplication(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushboolean(L, 0); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    lua_pushboolean(L, element.isApplication ? 1 : 0)
    return 1
}

private func window_uielement_isWindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushboolean(L, 0); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    lua_pushboolean(L, element.isWindow ? 1 : 0)
    return 1
}

private func window_uielement_role(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    skin.pushNSObject(element.role as NSString)
    return 1
}

private func window_uielement_selectedText(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    skin.pushNSObject(element.selectedText as NSString?)
    return 1
}

private func window_uielement_newWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION, LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    let watcher = element.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)
    skin.pushNSObject(watcher)
    lua_pushnil(L)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSwindow(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let value = obj as? NSObject & HSwindowProtocol else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value as NSObject).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSwindowFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
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
    let win = getWindow(L, at: 1)
    let title = win?.title() ?? "nil"
    lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        if let w1 = skin.toNSObject(at: 1) as? HSwindowProtocol,
           let w2 = skin.toNSObject(at: 2) as? HSwindowProtocol {
            isEqual = CFEqual(w1.elementRef, w2.elementRef)
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
        let win = Unmanaged<NSObject>.fromOpaque(rawPtr).takeRetainedValue()
        if let proto = win as? HSwindowProtocol {
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
    luaL_Reg(name: strdup("focusedWindow"),  func: window_focusedwindow),
    luaL_Reg(name: strdup("_orderedwinids"), func: window__orderedwinids),
    luaL_Reg(name: strdup("setShadows"),     func: window_setShadows),
    luaL_Reg(name: strdup("snapshotForID"),  func: window_snapshotForID),
    luaL_Reg(name: strdup("timeout"),        func: window_timeout),
    luaL_Reg(name: strdup("list"),           func: window_list),
    luaL_Reg(name: nil, func: nil),
]

private let module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private let userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("title"),          func: window_title),
    luaL_Reg(name: strdup("subrole"),        func: window_subrole),
    luaL_Reg(name: strdup("role"),           func: window_role),
    luaL_Reg(name: strdup("isStandard"),     func: window_isstandard),
    luaL_Reg(name: strdup("_topLeft"),       func: window__topleft),
    luaL_Reg(name: strdup("_size"),          func: window__size),
    luaL_Reg(name: strdup("_setTopLeft"),    func: window__settopleft),
    luaL_Reg(name: strdup("_setSize"),       func: window__setsize),
    luaL_Reg(name: strdup("_setFrame"),      func: window__setframe),
    luaL_Reg(name: strdup("_minimize"),      func: window__minimize),
    luaL_Reg(name: strdup("_unminimize"),    func: window__unminimize),
    luaL_Reg(name: strdup("isMinimized"),    func: window_isminimized),
    luaL_Reg(name: strdup("isMaximizable"),  func: window_isMaximizable),
    luaL_Reg(name: strdup("pid"),            func: window_pid),
    luaL_Reg(name: strdup("application"),    func: window_application),
    luaL_Reg(name: strdup("focusTab"),       func: window_focustab),
    luaL_Reg(name: strdup("tabCount"),       func: window_tabcount),
    luaL_Reg(name: strdup("becomeMain"),     func: window_becomemain),
    luaL_Reg(name: strdup("raise"),          func: window_raise),
    luaL_Reg(name: strdup("id"),             func: window_id),
    luaL_Reg(name: strdup("_toggleZoom"),    func: window__togglezoom),
    luaL_Reg(name: strdup("zoomButtonRect"), func: window_getZoomButtonRect),
    luaL_Reg(name: strdup("_close"),         func: window__close),
    luaL_Reg(name: strdup("_setFullScreen"), func: window__setfullscreen),
    luaL_Reg(name: strdup("isFullScreen"),   func: window_isfullscreen),
    luaL_Reg(name: strdup("snapshot"),       func: window_snapshot),
    luaL_Reg(name: strdup("isApplication"),  func: window_uielement_isApplication),
    luaL_Reg(name: strdup("isWindow"),       func: window_uielement_isWindow),
    luaL_Reg(name: strdup("selectedText"),   func: window_uielement_selectedText),
    luaL_Reg(name: strdup("newWatcher"),     func: window_uielement_newWatcher),
    luaL_Reg(name: strdup("__tostring"),     func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),           func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),           func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwindow")
public func luaopen_hs_libwindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: moduleLib,
                                    metaFunctions: module_metaLib,
                                    objectFunctions: userdata_metaLib)
    skin.registerPushNSHelper(pushHSwindow, forClass: "HSwindow")
    skin.registerLuaObjectHelper(toHSwindowFromLua, forClass: "HSwindow",
                                 withUserdataMapping: USERDATA_TAG)
    return 1
}
