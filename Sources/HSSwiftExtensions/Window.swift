import HSDSTCore
import Cocoa
import CLua
import Lua
import Carbon
import os.log

private let USERDATA_TAG = "hs.window"

// MARK: - Window userdata format
//
// All window userdata uses a single format: a retained pointer to a WindowHandleBox NSObject
// that holds a WindowElementHandle for O(1) access. Size = MemoryLayout<UnsafeMutableRawPointer>.size.

/// Box that holds a WindowElementHandle for storage in Lua userdata.
/// This is an NSObject so it participates in ARC via Unmanaged retain/release.
final class WindowHandleBox: NSObject {
    let handle: any WindowElementHandle
    init(_ handle: any WindowElementHandle) { self.handle = handle }
}

/// Push a WindowElementHandle as an hs.window userdata.
func pushWindowElement(_ L: UnsafeMutablePointer<lua_State>!, _ handle: any WindowElementHandle) {
    precondition(L != nil, "lua_State must not be nil")
    let box = WindowHandleBox(handle)
    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    ptr.pointee = Unmanaged.passRetained(box).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
}

/// Extract the WindowElementHandle from userdata.
private func getWindowHandle(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> (any WindowElementHandle)? {
    guard luaL_testudata(L, idx, USERDATA_TAG) != nil else { return nil }
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    let obj = Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
    return (obj as? WindowHandleBox)?.handle
}

/// Get the window ID from userdata at the given stack index, or return 0 if invalid.
private func getWindowID(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> UInt32 {
    guard let handle = getWindowHandle(L, at: idx) else { return 0 }
    return handle.windowID
}

@discardableResult
private func traceWindowAutomation(
    _ L: UnsafeMutablePointer<lua_State>!,
    handle: any WindowElementHandle,
    action: String,
    operation: () -> Bool
) -> Bool {
    let telemetry = environmentGet(L).telemetry
    let spanID = telemetry.startSpan(
        name: "hs.window.\(action)",
        kind: .internalSpan,
        attributes: [
            TelemetrySemanticConventions.Attribute.UI.system: "macos",
            TelemetrySemanticConventions.Attribute.UI.action: action,
            TelemetrySemanticConventions.Attribute.Window.id: handle.windowID,
            TelemetrySemanticConventions.Attribute.Process.pid: handle.pid,
        ],
        startTime: nil
    )
    let succeeded = operation()
    if let spanID {
        telemetry.endSpan(
            id: spanID,
            status: succeeded ? .ok : .error("window action failed"),
            attributes: [TelemetrySemanticConventions.Attribute.UI.actionSuccess: succeeded],
            endTime: nil
        )
    }
    return succeeded
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
/// Uses WindowElementHandle for O(1) per-window property access.
private func window__allwindows(_ L: LuaState) throws -> CInt {
    let win = environmentGet(L).window
    let elements = win.allWindowElements()
    lua_createtable(L, Int32(elements.count), 0)
    for (i, handle) in elements.enumerated() {
        pushWindowElement(L, handle)
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    return 1
}

/// hs.window.focusedWindow() -> window
/// Constructor
/// Returns the window that has keyboard/mouse focus
/// Uses WindowElementHandle for O(1) property access on the returned window.
private func window_focusedwindow(_ L: LuaState) throws -> CInt {
    let win = environmentGet(L).window
    if let handle = win.focusedWindowElement() {
        pushWindowElement(L, handle)
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
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, handle.title() as NSString?)
    return 1
}

private func window_subrole(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, handle.subrole() as NSString?)
    return 1
}

private func window_role(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, handle.role() as NSString?)
    return 1
}

private func window_isstandard(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { L.push(false); return 1 }
    L.push(handle.isStandard())
    return 1
}

private func window__topleft(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    let f = handle.frame()
    lua_pushNSPoint(L, NSPoint(x: f.x, y: f.y))
    return 1
}

private func window__size(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    let f = handle.frame()
    lua_pushNSSize(L, NSSize(width: f.width, height: f.height))
    return 1
}

private func window__settopleft(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_checktype(L, 2, LUA_TTABLE)
    let point = lua_tableToPoint(L, at: 2)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "setTopLeft") {
            handle.setTopLeft((Double(point.x), Double(point.y)))
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window__setsize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_checktype(L, 2, LUA_TTABLE)
    let size = lua_tableToSize(L, at: 2)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "setSize") {
            handle.setSize((Double(size.width), Double(size.height)))
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window__setframe(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_checktype(L, 2, LUA_TTABLE)
    let rect = lua_tableToRect(L, at: 2)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "setFrame") {
            handle.setFrame((Double(rect.origin.x), Double(rect.origin.y),
                             Double(rect.size.width), Double(rect.size.height)))
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window__togglezoom(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "toggleZoom") {
            handle.toggleZoom()
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window_getZoomButtonRect(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    if let rect = handle.zoomButtonRect() {
        lua_pushNSRect(L, NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_isMaximizable(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    if let maximizable = handle.isMaximizable() {
        L.push(maximizable)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window__close(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { L.push(false); return 1 }
    L.push(traceWindowAutomation(L, handle: handle, action: "close") {
        handle.close()
    })
    return 1
}

private func window_focustab(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let tabIndex = Int32(lua_tointeger(L, 2))
    guard let handle = getWindowHandle(L, at: 1) else { L.push(false); return 1 }
    L.push(traceWindowAutomation(L, handle: handle, action: "focusTab") {
        handle.focusTab(tabIndex)
    })
    return 1
}

private func window_tabcount(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { L.push(0); return 1 }
    L.push(Int(handle.tabCount()))
    return 1
}

private func window__setfullscreen(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let fullscreen = lua_toboolean(L, 2) != 0
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "setFullScreen") {
            handle.setFullScreen(fullscreen)
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window_isfullscreen(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    L.push(handle.isFullScreen())
    return 1
}

private func window__minimize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "minimize") {
            handle.minimize()
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window__unminimize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "unminimize") {
            handle.unminimize()
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window_isminimized(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { L.push(false); return 1 }
    L.push(handle.isMinimized())
    return 1
}

private func window_pid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    L.push(Int(handle.pid))
    return 1
}

private func window_application(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    let appPid = handle.pid
    lua_settop(L, 0)
    if let app = HSapplication(pid: appPid, withState: L) {
        pushHSapplicationOrNil(L, app)
    } else if let appInfo = environmentGet(L).application.applicationForPID(appPid) {
        pushApplicationInfo(L, appInfo)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func window_becomemain(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "becomeMain") {
            handle.becomeMain()
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func window_raise(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    if let handle = getWindowHandle(L, at: 1) {
        traceWindowAutomation(L, handle: handle, action: "raise") {
            handle.raise()
        }
    }
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
    let keepTransparency = lua_toboolean(L, 2) != 0
    guard let handle = getWindowHandle(L, at: 1) else { lua_pushnil(L); return 1 }
    if let data = handle.snapshot(keepTransparency: keepTransparency) {
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
    guard let info = win.desktopWindow() else {
        lua_pushnil(L)
        return 1
    }
    if let handle = win.windowElement(forID: info.id) {
        pushWindowElement(L, handle)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Corner Radius

private func window_cornerRadius(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let handle = getWindowHandle(L, at: 1) else { L.push(0.0); return 1 }
    L.push(handle.cornerRadius())
    return 1
}

// MARK: - hs.uielement methods on hs.window
// These bridge to HSuielement via AXUIElement. Deferred to Phase 4 (Accessibility).
// For now, they look up the HSwindow from the old push mechanism or fall back to
// creating an HSwindow from the protocol to get the elementRef.

/// Helper: obtain an AXUIElement for the window ID by finding it through the accessibility tree.
/// This is the bridge between the new ID-based approach and the legacy AX-based uielement methods.
private func findElementRefForWindowID(_ L: UnsafeMutablePointer<lua_State>!, _ wid: UInt32) -> AXUIElement? {
    // Try to get it from the WindowHandleBox (O(1) format)
    if let handle = getWindowHandle(L, at: 1),
       let prodHandle = handle as? ProductionWindowElement {
        return prodHandle.element
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


// MARK: - Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    if let handle = getWindowHandle(L, at: 1) {
        let title = handle.title() ?? "nil"
        L.push("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    } else {
        L.push("\(USERDATA_TAG): (invalid) (\(String(describing: lua_topointer(L, 1)!)))")
    }
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let wid1 = getWindowID(L, at: 1)
        let wid2 = getWindowID(L, at: 2)
        isEqual = wid1 != 0 && wid2 != 0 && wid1 == wid2
    }
    L.push(isEqual)
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        Unmanaged<NSObject>.fromOpaque(rawPtr).release()
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
        L.push(window__desktop);         lua_setfield(L, -2, "_desktop")
        L.push(window__allwindows);      lua_setfield(L, -2, "_allWindows")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 0)
        lua_setmetatable(L, -2)
    }
}
