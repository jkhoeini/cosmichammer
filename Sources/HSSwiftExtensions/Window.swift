import Cocoa
import CLua
import Lua
import Carbon
import os.log

private let USERDATA_TAG = "hs.window"

@_silgen_name("CGSSetDebugOptions")
private func cgsSetDebugOptions(_ options: Int32)

// SkyLight private API for querying window corner radii via the window iterator.
@_silgen_name("SLSMainConnectionID")
private func slsMainConnectionID() -> Int32

@_silgen_name("SLSWindowQueryWindows")
private func SLSWindowQueryWindows(_ cid: Int32, _ windows: CFArray, _ options: UInt32) -> CFTypeRef?

@_silgen_name("SLSWindowQueryResultCopyWindows")
private func SLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> CFTypeRef?

@_silgen_name("SLSWindowIteratorGetCount")
private func SLSWindowIteratorGetCount(_ iterator: CFTypeRef) -> Int32

@_silgen_name("SLSWindowIteratorAdvance")
private func SLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool

@_silgen_name("SLSWindowIteratorGetCornerRadii")
private func SLSWindowIteratorGetCornerRadii(_ iterator: CFTypeRef) -> CFArray?

private let kCGSDebugOptionNormal: Int32 = 0
private let kCGSDebugOptionNoShadows: Int32 = 16384

private func getWindow(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSwindowProtocol? {
    return toHSwindowFromLua(L, idx) as? HSwindowProtocol
}

// MARK: - Helpers

private var systemWideElement: AXUIElement = {
    AXUIElementCreateSystemWide()
}()

// MARK: - Module Functions

/// hs.window.list(allWindows) -> table
/// Function
/// Gets a table containing all the window data retrieved from CGWindowListCreate.
private func window_list(_ L: LuaState) throws -> CInt {
    let allWindows = lua_toboolean(L, 1) != 0

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

    lua_pushany(L, windows as NSArray)
    return 1
}

/// hs.window.timeout(value) -> boolean
/// Function
/// Sets the timeout value used in the accessibility API.
private func window_timeout(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TNUMBER)
    let value = Float(lua_tonumber(L, 1))
    let result = AXUIElementSetMessagingTimeout(systemWideElement, value)
    if result == .illegalArgument {
        os_log(.error, "%{public}s","hs.window.timeout() - One or more of the arguments is an illegal value (timeout values must be positive).")
        L.push(false)
        return 1
    }
    if result == .invalidUIElement {
        os_log(.error, "%{public}s","hs.window.timeout() - The AXUIElementRef is invalid.")
        L.push(false)
        return 1
    }
    L.push(true)
    return 1
}

/// hs.window.focusedWindow() -> window
/// Constructor
/// Returns the window that has keyboard/mouse focus
private func window_focusedwindow(_ L: LuaState) throws -> CInt {
    if let windowClass = HSuicore.windowClass {
        let result = catchingObjCException {
            (windowClass as AnyObject).perform(Selector(("focusedWindow")))?.takeUnretainedValue()
        }
        pushHSwindowOrNil(L, result)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.window.setShadows(shadows)
/// Function
/// Enables/Disables window shadows
private func window_setShadows(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TBOOLEAN)
    let shadows = lua_toboolean(L, 1) != 0
    cgsSetDebugOptions(shadows ? kCGSDebugOptionNormal : kCGSDebugOptionNoShadows)
    return 0
}

/// hs.window.snapshotForID(ID [, keepTransparency]) -> hs.image-object
/// Function
/// Returns a snapshot of the window specified by the ID
private func window_snapshotForID(_ L: LuaState) throws -> CInt {
    let windowID = CGWindowID(lua_tointeger(L, 1))
    let keepTransparency = lua_toboolean(L, 2) != 0
    if let windowClass = HSuicore.windowClass {
        let result = catchingObjCException {
            (windowClass as AnyObject).perform(
                Selector(("snapshotForID:keepTransparency:")),
                with: NSNumber(value: windowID),
                with: NSNumber(value: keepTransparency)
            )?.takeUnretainedValue()
        }
        lua_pushany(L, result)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__orderedwinids(_ L: LuaState) throws -> CInt {
    if let windowClass = HSuicore.windowClass {
        let result = catchingObjCException {
            (windowClass as AnyObject).perform(Selector(("orderedWindowIDs")))?.takeUnretainedValue()
        }
        lua_pushany(L, result)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Instance Methods

private func window_title(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, win.title() as NSString?)
    return 1
}

private func window_subrole(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, win.subRole() as NSString?)
    return 1
}

private func window_role(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, win.role() as NSString?)
    return 1
}

private func window_isstandard(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { L.push(false); return 1 }
    L.push(win.isStandard())
    return 1
}

private func window__topleft(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushNSPoint(L, win.getTopLeft())
    return 1
}

private func window__size(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushNSSize(L, win.getSize())
    return 1
}

private func window__settopleft(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setTopLeft(lua_tableToPoint(L, at: 2))
    lua_pushvalue(L, 1)
    return 1
}

private func window__setsize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setSize(lua_tableToSize(L, at: 2))
    lua_pushvalue(L, 1)
    return 1
}

private func window__setframe(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setFrame(lua_tableToRect(L, at: 2))
    lua_pushvalue(L, 1)
    return 1
}

private func window__togglezoom(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.toggleZoom()
    lua_pushvalue(L, 1)
    return 1
}

private func window_getZoomButtonRect(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushNSRect(L, win.getZoomButtonRect())
    return 1
}

private func window_isMaximizable(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }

    var button: CFTypeRef?
    var isEnabled: CFTypeRef?

    guard AXUIElementCopyAttributeValue(win.elementRef, kAXZoomButtonAttribute as CFString, &button) == .success,
          let buttonElement = button,
          AXUIElementCopyAttributeValue(buttonElement as! AXUIElement, kAXEnabledAttribute as CFString, &isEnabled) == .success else {
        lua_pushnil(L)
        return 1
    }

    L.push(CFBooleanGetValue(isEnabled as! CFBoolean))
    return 1
}

private func window__close(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { L.push(false); return 1 }
    L.push(win.close())
    return 1
}

private func window_focustab(_ L: LuaState) throws -> CInt {
    guard let win = getWindow(L, at: 1) else { L.push(false); return 1 }
    let tabIndex = Int32(lua_tointeger(L, 2))
    L.push(win.focusTab(tabIndex))
    return 1
}

private func window_tabcount(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { L.push(0); return 1 }
    L.push(Int(win.getTabCount()))
    return 1
}

private func window__setfullscreen(_ L: LuaState) throws -> CInt {
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setFullscreen(lua_toboolean(L, 2) != 0)
    lua_pushvalue(L, 1)
    return 1
}

private func window_isfullscreen(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    L.push(win.isFullscreen())
    return 1
}

private func window__minimize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setMinimized(true)
    lua_pushvalue(L, 1)
    return 1
}

private func window__unminimize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.setMinimized(false)
    lua_pushvalue(L, 1)
    return 1
}

private func window_isminimized(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { L.push(false); return 1 }
    L.push(win.isMinimized())
    return 1
}

private func window_pid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    L.push(Int(win.pid))
    return 1
}

private func window_application(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }

    lua_settop(L, 0)

    if let app = HSapplication(pid: win.pid, withState: L) {
        pushHSapplicationOrNil(L, app)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_becomemain(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.becomeMain()
    lua_pushvalue(L, 1)
    return 1
}

private func window_raise(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushvalue(L, 1); return 1 }
    win.raise()
    lua_pushvalue(L, 1)
    return 1
}

private func window_id(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    L.push(Int(win.winID))
    return 1
}

private func window_snapshot(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let keepTransparency = lua_toboolean(L, 2) != 0
    lua_pushany(L, win.snapshot(keepTransparency))
    return 1
}

// MARK: - Corner Radius (SkyLight private API)

/// Returns the corner radius for the given CGWindowID, or nil if unavailable.
private func windowCornerRadius(for windowID: CGWindowID) -> CGFloat? {
    precondition(windowID != 0, "windowCornerRadius: windowID must not be 0")
    let cid = slsMainConnectionID()
    let windowArray = [NSNumber(value: windowID)] as CFArray
    guard let query = SLSWindowQueryWindows(cid, windowArray, 0x0) else { return nil }
    guard let iterator = SLSWindowQueryResultCopyWindows(query) else { return nil }
    guard SLSWindowIteratorGetCount(iterator) > 0 else { return nil }
    guard SLSWindowIteratorAdvance(iterator) else { return nil }

    guard let radiiRef = SLSWindowIteratorGetCornerRadii(iterator),
          let radii = radiiRef as? NSArray,
          radii.count > 0,
          let value = radii[0] as? NSNumber else { return nil }
    let radius = CGFloat(value.doubleValue)
    return radius > 0 ? radius : nil
}

/// hs.window:cornerRadius() -> number
/// Method
/// Gets the corner radius of the window as reported by the system window server.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number representing the corner radius in points, or 0 if unavailable.
///
/// Notes:
///  * This uses a private macOS API (SkyLight) and may not work on all macOS versions.
///  * Standard windows on macOS Sequoia/Tahoe have a corner radius of approximately 10.
///  * Returns 0 for windows whose corner radius cannot be determined.
private func window_cornerRadius(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else {
        L.push(0.0)
        return 1
    }
    let radius = windowCornerRadius(for: CGWindowID(win.winID)) ?? 0
    L.push(Double(radius))
    return 1
}

/// hs.window.cornerRadiusForID(windowID) -> number
/// Function
/// Gets the corner radius of a window given its window ID.
///
/// Parameters:
///  * windowID - a number representing the window ID (as returned by `hs.window:id()`)
///
/// Returns:
///  * A number representing the corner radius in points, or 0 if unavailable.
///
/// Notes:
///  * This uses a private macOS API (SkyLight) and may not work on all macOS versions.
///  * Standard windows on macOS Sequoia/Tahoe have a corner radius of approximately 10.
///  * Returns 0 for windows whose corner radius cannot be determined or for invalid window IDs.
private func window_cornerRadiusForID(_ L: LuaState) throws -> CInt {
    let windowID = CGWindowID(lua_tointeger(L, 1))
    guard windowID != 0 else {
        L.push(0.0)
        return 1
    }
    let radius = windowCornerRadius(for: windowID) ?? 0
    L.push(Double(radius))
    return 1
}

// MARK: - hs.uielement methods on hs.window

private func window_uielement_isApplication(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { L.push(false); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    L.push(element.isApplication)
    return 1
}

private func window_uielement_isWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { L.push(false); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    L.push(element.isWindow)
    return 1
}

private func window_uielement_role(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    lua_pushany(L, element.role as NSString)
    return 1
}

private func window_uielement_selectedText(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    lua_pushany(L, element.selectedText as NSString?)
    return 1
}

private func window_uielement_newWatcher(_ L: LuaState) throws -> CInt {
    guard let win = getWindow(L, at: 1) else { lua_pushnil(L); return 1 }
    let element = HSuielement(withElement: win.elementRef)
    let watcher = element.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)
    pushHSuielementWatcherOrNil(L, watcher)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

@discardableResult
func pushHSwindow(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    precondition(L != nil, "pushHSwindow: L must not be nil")
    guard let value = obj as? NSObject & HSwindowProtocol else { return 0 }
    let previousTop = lua_gettop(L)
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value as NSObject).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    assert(lua_gettop(L) == previousTop + 1, "pushHSwindow: stack should grow by exactly 1")
    return 1
}

func pushHSwindowOrNil(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) {
    if pushHSwindow(L, obj) == 0 {
        lua_pushnil(L)
    }
}

func pushHSwindows(_ L: UnsafeMutablePointer<lua_State>!, _ windows: [Any]?) {
    precondition(L != nil, "pushHSwindows: L must not be nil")
    guard let windows = windows else {
        lua_pushnil(L)
        return
    }

    let previousTop = lua_gettop(L)
    lua_createtable(L, Int32(windows.count), 0)
    var index: lua_Integer = 1
    for window in windows {
        if pushHSwindow(L, window) != 0 {
            lua_rawseti(L, -2, index)
            index += 1
        }
    }
    assert(lua_gettop(L) == previousTop + 1, "pushHSwindows: stack should grow by exactly 1 (table)")
}

private func toHSwindowFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    precondition(L != nil, "toHSwindowFromLua: L must not be nil")
    precondition(idx != 0, "toHSwindowFromLua: idx must not be 0")
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let rawPtr = ptr.pointee else { return nil }
        return Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
    } else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG): expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let win = getWindow(L, at: 1)
    let title = win?.title() ?? "nil"
    L.push("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        if let w1 = toHSwindowFromLua(L, 1) as? HSwindowProtocol,
           let w2 = toHSwindowFromLua(L, 2) as? HSwindowProtocol {
            isEqual = CFEqual(w1.elementRef, w2.elementRef)
        }
    }
    L.push(isEqual)
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
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

@_cdecl("luaopen_hs_libwindow")
public func luaopen_hs_libwindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "luaopen_hs_libwindow: L must not be nil")
    return runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        L.push(window_title);                   lua_setfield(L, -2, "title")
        L.push(window_subrole);                  lua_setfield(L, -2, "subrole")
        L.push(window_role);                     lua_setfield(L, -2, "role")
        L.push(window_isstandard);               lua_setfield(L, -2, "isStandard")
        L.push(window__topleft);                 lua_setfield(L, -2, "_topLeft")
        L.push(window__size);                    lua_setfield(L, -2, "_size")
        L.push(window__settopleft);              lua_setfield(L, -2, "_setTopLeft")
        L.push(window__setsize);                 lua_setfield(L, -2, "_setSize")
        L.push(window__setframe);                lua_setfield(L, -2, "_setFrame")
        L.push(window__minimize);                lua_setfield(L, -2, "_minimize")
        L.push(window__unminimize);              lua_setfield(L, -2, "_unminimize")
        L.push(window_isminimized);              lua_setfield(L, -2, "isMinimized")
        L.push(window_isMaximizable);            lua_setfield(L, -2, "isMaximizable")
        L.push(window_pid);                      lua_setfield(L, -2, "pid")
        L.push(window_application);              lua_setfield(L, -2, "application")
        L.push(window_focustab);                 lua_setfield(L, -2, "focusTab")
        L.push(window_tabcount);                 lua_setfield(L, -2, "tabCount")
        L.push(window_becomemain);               lua_setfield(L, -2, "becomeMain")
        L.push(window_raise);                    lua_setfield(L, -2, "raise")
        L.push(window_id);                       lua_setfield(L, -2, "id")
        L.push(window__togglezoom);              lua_setfield(L, -2, "_toggleZoom")
        L.push(window_getZoomButtonRect);        lua_setfield(L, -2, "zoomButtonRect")
        L.push(window__close);                   lua_setfield(L, -2, "_close")
        L.push(window__setfullscreen);           lua_setfield(L, -2, "_setFullScreen")
        L.push(window_isfullscreen);             lua_setfield(L, -2, "isFullScreen")
        L.push(window_snapshot);                 lua_setfield(L, -2, "snapshot")
        L.push(window_cornerRadius);             lua_setfield(L, -2, "cornerRadius")
        L.push(window_uielement_isApplication);  lua_setfield(L, -2, "isApplication")
        L.push(window_uielement_isWindow);       lua_setfield(L, -2, "isWindow")
        L.push(window_uielement_selectedText);   lua_setfield(L, -2, "selectedText")
        L.push(window_uielement_newWatcher);     lua_setfield(L, -2, "newWatcher")
        L.push(userdata_tostring);               lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq);                     lua_setfield(L, -2, "__eq")
        L.push(userdata_gc);                     lua_setfield(L, -2, "__gc")

        // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 7)

        L.push(window_focusedwindow);    lua_setfield(L, -2, "focusedWindow")
        L.push(window__orderedwinids);   lua_setfield(L, -2, "_orderedwinids")
        L.push(window_setShadows);       lua_setfield(L, -2, "setShadows")
        L.push(window_snapshotForID);    lua_setfield(L, -2, "snapshotForID")
        L.push(window_cornerRadiusForID); lua_setfield(L, -2, "cornerRadiusForID")
        L.push(window_timeout);          lua_setfield(L, -2, "timeout")
        L.push(window_list);             lua_setfield(L, -2, "list")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 0)
        lua_setmetatable(L, -2)
    }
}
