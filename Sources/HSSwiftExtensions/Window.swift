import HSDSTCore
import Cocoa
import CLua
import Lua
import Carbon
import os.log

private let USERDATA_TAG = "hs.window"

// MARK: - Window userdata: stores a UInt32 window ID (routed through WindowProtocol)

struct WindowUserData {
    var windowID: UInt32
    var lsCanary: UInt64
}

/// Extract the WindowUserData pointer from the Lua stack at the given index.
private func userdataToWindow(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<WindowUserData> {
    return luaL_checkudata(L, idx, USERDATA_TAG).assumingMemoryBound(to: WindowUserData.self)
}

/// Push a new hs.window userdata for the given window ID.
private func new_window(_ L: UnsafeMutablePointer<lua_State>!, _ windowID: UInt32) {
    precondition(L != nil, "lua_State must not be nil")
    precondition(windowID != 0, "windowID must not be 0")
    let ptr = lua_newuserdata(L, MemoryLayout<WindowUserData>.size)!
    let win = ptr.assumingMemoryBound(to: WindowUserData.self)
    win.pointee.windowID = windowID
    win.pointee.lsCanary = lua_currentStateGeneration()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
}

/// Get the window ID from userdata at the given stack index, or return 0 if invalid.
/// Handles both the new WindowUserData format and the legacy HSwindow pointer format.
private func getWindowID(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> UInt32 {
    guard luaL_testudata(L, idx, USERDATA_TAG) != nil else { return 0 }
    let udataSize: Int = lua_rawlen(L, idx)
    if udataSize == MemoryLayout<WindowUserData>.size {
        // New ID-based format
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: WindowUserData.self)
        return ptr.pointee.windowID
    } else {
        // Legacy HSwindow pointer format — extract winID from the HSwindow object
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let rawPtr = ptr.pointee else { return 0 }
        let obj = Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
        if let win = obj as? HSwindowProtocol {
            return UInt32(win.winID)
        }
        return 0
    }
}

// MARK: - Legacy HSwindow bridge (cross-extension compatibility)
// These functions remain for Application.swift, AXUIElement.swift, UielementWatcher.swift
// which still create HSwindow objects from AXUIElement refs.
// Phase 4 (Accessibility) will migrate those callers.

private func getWindow(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSwindowProtocol? {
    // Legacy HSwindow callers (Application.swift etc.) still push HSwindow objects.
    // The new WindowUserData format is used by new_window(), the old by pushHSwindow().
    // toHSwindowFromLua handles the legacy pointer format.
    return toHSwindowFromLua(L, idx) as? HSwindowProtocol
}

// MARK: - Module Functions

/// hs.window.list(allWindows) -> table
/// Function
/// Gets a table containing all the window data retrieved from CGWindowListCreate.
private func window_list(_ L: LuaState) throws -> CInt {
    let allWindows = lua_toboolean(L, 1) != 0
    let win = environmentGet(L).window
    let windows = win.listWindowInfo(allWindows: allWindows)
    lua_pushany(L, windows as NSArray)
    return 1
}

/// hs.window.timeout(value) -> boolean
/// Function
/// Sets the timeout value used in the accessibility API.
private func window_timeout(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TNUMBER)
    let value = Float(lua_tonumber(L, 1))
    let win = environmentGet(L).window
    let success = win.setTimeout(value)
    if !success {
        os_log(.error, "%{public}s", "hs.window.timeout() - timeout value must be positive.")
    }
    L.push(success)
    return 1
}

/// hs.window._allWindows() -> table of hs.window objects
/// Function
/// Returns all windows from the WindowProtocol (includes simulated windows).
private func window__allwindows(_ L: LuaState) throws -> CInt {
    let win = environmentGet(L).window
    let allWins = win.allWindows()
    lua_createtable(L, Int32(allWins.count), 0)
    for (i, info) in allWins.enumerated() {
        new_window(L, info.id)
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    return 1
}

/// hs.window.focusedWindow() -> window
/// Constructor
/// Returns the window that has keyboard/mouse focus
private func window_focusedwindow(_ L: LuaState) throws -> CInt {
    let win = environmentGet(L).window
    if let info = win.focusedWindow() {
        new_window(L, info.id)
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
    let win = environmentGet(L).window
    win.setShadows(shadows)
    return 0
}

/// hs.window.snapshotForID(ID [, keepTransparency]) -> hs.image-object
/// Function
/// Returns a snapshot of the window specified by the ID
private func window_snapshotForID(_ L: LuaState) throws -> CInt {
    let windowID = UInt32(lua_tointeger(L, 1))
    let keepTransparency = lua_toboolean(L, 2) != 0
    let win = environmentGet(L).window
    if let data = win.snapshotForID(windowID, keepTransparency: keepTransparency) {
        let nsImage = NSImage(data: data)
        lua_pushany(L, nsImage)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__orderedwinids(_ L: LuaState) throws -> CInt {
    let win = environmentGet(L).window
    let ids = win.orderedWindowIDs()
    let nsNumbers = ids.map { NSNumber(value: $0) }
    lua_pushany(L, nsNumbers as NSArray)
    return 1
}

/// hs.window.cornerRadiusForID(windowID) -> number
/// Function
/// Gets the corner radius of a window given its window ID.
private func window_cornerRadiusForID(_ L: LuaState) throws -> CInt {
    let windowID = UInt32(lua_tointeger(L, 1))
    guard windowID != 0 else {
        L.push(0.0)
        return 1
    }
    let win = environmentGet(L).window
    L.push(win.cornerRadius(forWindowID: windowID))
    return 1
}

// MARK: - Instance Methods

private func window_title(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        lua_pushany(L, info.title as NSString?)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_subrole(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        lua_pushany(L, info.subrole as NSString?)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_role(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        lua_pushany(L, info.role as NSString?)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_isstandard(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { L.push(false); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        L.push(info.isStandard)
    } else {
        L.push(false)
    }
    return 1
}

private func window__topleft(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        lua_pushNSPoint(L, NSPoint(x: info.frame.x, y: info.frame.y))
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__size(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        lua_pushNSSize(L, NSSize(width: info.frame.width, height: info.frame.height))
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__settopleft(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_checktype(L, 2, LUA_TTABLE)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let point = lua_tableToPoint(L, at: 2)
    let win = environmentGet(L).window
    _ = win.setTopLeft((Double(point.x), Double(point.y)), forWindowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window__setsize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_checktype(L, 2, LUA_TTABLE)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let size = lua_tableToSize(L, at: 2)
    let win = environmentGet(L).window
    _ = win.setSize((Double(size.width), Double(size.height)), forWindowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window__setframe(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_checktype(L, 2, LUA_TTABLE)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let rect = lua_tableToRect(L, at: 2)
    let win = environmentGet(L).window
    _ = win.setFrame((Double(rect.origin.x), Double(rect.origin.y),
                      Double(rect.size.width), Double(rect.size.height)), forWindowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window__togglezoom(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let win = environmentGet(L).window
    _ = win.toggleZoom(windowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window_getZoomButtonRect(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let rect = win.zoomButtonRect(forWindowID: wid) {
        lua_pushNSRect(L, NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_isMaximizable(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let maximizable = win.isMaximizable(forWindowID: wid) {
        L.push(maximizable)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__close(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { L.push(false); return 1 }
    let win = environmentGet(L).window
    L.push(win.close(windowID: wid))
    return 1
}

private func window_focustab(_ L: LuaState) throws -> CInt {
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { L.push(false); return 1 }
    let tabIndex = Int32(lua_tointeger(L, 2))
    let win = environmentGet(L).window
    L.push(win.focusTab(tabIndex, forWindowID: wid))
    return 1
}

private func window_tabcount(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { L.push(0); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        L.push(Int(info.tabCount))
    } else {
        L.push(0)
    }
    return 1
}

private func window__setfullscreen(_ L: LuaState) throws -> CInt {
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let fullscreen = lua_toboolean(L, 2) != 0
    let win = environmentGet(L).window
    _ = win.setFullScreen(fullscreen, forWindowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window_isfullscreen(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        L.push(info.isFullScreen)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__minimize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let win = environmentGet(L).window
    _ = win.minimize(windowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window__unminimize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let win = environmentGet(L).window
    _ = win.unminimize(windowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window_isminimized(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { L.push(false); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        L.push(info.isMinimized)
    } else {
        L.push(false)
    }
    return 1
}

private func window_pid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let win = environmentGet(L).window
    if let info = win.windowInfo(forID: wid) {
        L.push(Int(info.pid))
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_application(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let winProto = environmentGet(L).window
    if let info = winProto.windowInfo(forID: wid) {
        lua_settop(L, 0)
        // Try production HSapplication first, fall back to protocol-based lookup
        if let app = HSapplication(pid: info.pid, withState: L) {
            pushHSapplicationOrNil(L, app)
        } else if let appInfo = environmentGet(L).application.applicationForPID(info.pid) {
            pushApplicationInfo(L, appInfo)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_becomemain(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let win = environmentGet(L).window
    _ = win.becomeMain(windowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window_raise(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushvalue(L, 1); return 1 }
    let win = environmentGet(L).window
    _ = win.raise(windowID: wid)
    lua_pushvalue(L, 1)
    return 1
}

private func window_id(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    L.push(Int(wid))
    return 1
}

private func window_snapshot(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { lua_pushnil(L); return 1 }
    let keepTransparency = lua_toboolean(L, 2) != 0
    let win = environmentGet(L).window
    if let data = win.snapshot(windowID: wid, keepTransparency: keepTransparency) {
        let nsImage = NSImage(data: data)
        lua_pushany(L, nsImage)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Desktop

private func window__desktop(_ L: LuaState) throws -> CInt {
    let win = environmentGet(L).window
    if let info = win.desktopWindow() {
        if info.id == 0 || info.id == UInt32.max {
            // Desktop window has no meaningful ID; push nil for :id() but still create userdata
            // Use a special ID that won't collide with real windows but is non-zero for new_window
            let ptr = lua_newuserdata(L, MemoryLayout<WindowUserData>.size)!
            let userData = ptr.assumingMemoryBound(to: WindowUserData.self)
            userData.pointee.windowID = info.id
            userData.pointee.lsCanary = lua_currentStateGeneration()
            luaL_getmetatable(L, USERDATA_TAG)
            lua_setmetatable(L, -2)
        } else {
            new_window(L, info.id)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Corner Radius

private func window_cornerRadius(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0 else { L.push(0.0); return 1 }
    let win = environmentGet(L).window
    L.push(win.cornerRadius(forWindowID: wid))
    return 1
}

// MARK: - hs.uielement methods on hs.window
// These bridge to HSuielement via AXUIElement. Deferred to Phase 4 (Accessibility).
// For now, they look up the HSwindow from the old push mechanism or fall back to
// creating an HSwindow from the protocol to get the elementRef.

/// Helper: obtain an AXUIElement for the window ID by finding it through the accessibility tree.
/// This is the bridge between the new ID-based approach and the legacy AX-based uielement methods.
private func findElementRefForWindowID(_ L: UnsafeMutablePointer<lua_State>!, _ wid: UInt32) -> AXUIElement? {
    // Try to get it from the legacy HSwindow if the userdata is in the old format
    if let win = toHSwindowFromLua(L, 1) as? HSwindowProtocol {
        return win.elementRef
    }
    // Otherwise, look up by iterating apps (same strategy as ProductionWindow.findWindowElement)
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windowsRef = windowsRef
        else { continue }
        let windowsArray = unsafeBitCast(windowsRef, to: CFArray.self)
        let count = CFArrayGetCount(windowsArray)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(windowsArray, i) else { continue }
            let winElement = unsafeBitCast(raw, to: AXUIElement.self)
            var winIDOut: CGWindowID = 0
            if _AXUIElementGetWindow(winElement, &winIDOut) == .success && winIDOut == wid {
                return winElement
            }
        }
    }
    return nil
}

private func window_uielement_isApplication(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0, let elementRef = findElementRefForWindowID(L, wid) else {
        L.push(false); return 1
    }
    let element = HSuielement(withElement: elementRef)
    L.push(element.isApplication)
    return 1
}

private func window_uielement_isWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0, let elementRef = findElementRefForWindowID(L, wid) else {
        L.push(false); return 1
    }
    let element = HSuielement(withElement: elementRef)
    L.push(element.isWindow)
    return 1
}

private func window_uielement_role(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0, let elementRef = findElementRefForWindowID(L, wid) else {
        lua_pushnil(L); return 1
    }
    let element = HSuielement(withElement: elementRef)
    lua_pushany(L, element.role as NSString)
    return 1
}

private func window_uielement_selectedText(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    guard wid != 0, let elementRef = findElementRefForWindowID(L, wid) else {
        lua_pushnil(L); return 1
    }
    let element = HSuielement(withElement: elementRef)
    lua_pushany(L, element.selectedText as NSString?)
    return 1
}

private func window_uielement_newWatcher(_ L: LuaState) throws -> CInt {
    let wid = getWindowID(L, at: 1)
    guard wid != 0, let elementRef = findElementRefForWindowID(L, wid) else {
        lua_pushnil(L); return 1
    }
    let element = HSuielement(withElement: elementRef)
    let watcher = element.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)
    pushHSuielementWatcherOrNil(L, watcher)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These remain for cross-extension compatibility (Application.swift, AXUIElement.swift,
// UielementWatcher.swift). Phase 4 will migrate those callers to use window IDs.

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
        let udataSize: Int = lua_rawlen(L, idx)
        if udataSize == MemoryLayout<WindowUserData>.size {
            return nil
        }
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let rawPtr = ptr.pointee else { return nil }
        let obj = Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
        return obj
    } else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG): expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wid = getWindowID(L, at: 1)
    if wid != 0 {
        let win = environmentGet(L).window
        let title = win.windowInfo(forID: wid)?.title ?? "nil"
        L.push("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    } else {
        // Legacy HSwindow format
        let win = getWindow(L, at: 1)
        let title = win?.title() ?? "nil"
        L.push("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    }
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let wid1 = getWindowID(L, at: 1)
        let wid2 = getWindowID(L, at: 2)
        if wid1 != 0 && wid2 != 0 {
            // New ID-based comparison
            isEqual = wid1 == wid2
        } else {
            // Legacy elementRef comparison
            if let w1 = toHSwindowFromLua(L, 1) as? HSwindowProtocol,
               let w2 = toHSwindowFromLua(L, 2) as? HSwindowProtocol {
                isEqual = CFEqual(w1.elementRef, w2.elementRef)
            }
        }
    }
    L.push(isEqual)
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    // Check the userdata size to determine if it's a new WindowUserData or legacy HSwindow pointer.
    // Both use the same metatable tag, so we need to distinguish them.
    // WindowUserData = 12 bytes (UInt32 + UInt64), legacy = pointer size (8 bytes).
    // However, lua_newuserdata allocates the exact requested size. For the new format,
    // we just let it go (no ARC to manage). For the legacy format, we need to release.
    let udataSize: Int = lua_rawlen(L, 1)
    if udataSize == MemoryLayout<WindowUserData>.size {
        // New format: nothing to release (no ARC-managed objects)
    } else {
        // Legacy HSwindow pointer format
        let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        if let rawPtr = ptr.pointee {
            let win = Unmanaged<NSObject>.fromOpaque(rawPtr).takeRetainedValue()
            if let proto = win as? HSwindowProtocol {
                proto.selfRefCount -= 1
            }
            ptr.pointee = nil
        }
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
        L.push(window__desktop);         lua_setfield(L, -2, "_desktop")
        L.push(window__allwindows);      lua_setfield(L, -2, "_allWindows")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 0)
        lua_setmetatable(L, -2)
    }
}
