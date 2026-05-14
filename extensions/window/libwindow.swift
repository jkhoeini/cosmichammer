import Foundation
import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.window"
private var refTable: Int32 = LUA_NOREF

// MARK: - Helper functions

private var systemWideElement: AXUIElement = {
    AXUIElementCreateSystemWide()
}()

/// hs.window.list(allWindows) -> table
/// Function
/// Gets a table containing all the window data retrieved from `CGWindowListCreate`.
///
/// Parameters:
///  * allWindows - Get all the windows, even those "below" the Dock window.
///
/// Returns:
///  * `true` is succesful otherwise `false` if an error occurred.
///
/// Notes:
///  * This allows you to get window information without Accessibility Permissions.
private func window_list(_ L: OpaquePointer!) -> Int32 {
    let allWindows = lua_toboolean(L, 1) != 0

    var windowListArray = CGWindowListCreate(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    )!
    var windows = CGWindowListCreateDescriptionFromArray(windowListArray)! as! [[CFString: Any]]

    if !allWindows {
        var dockWindowNumber: CGWindowID?
        for window in windows {
            if let name = window[kCGWindowName] as? String, name == "Dock" {
                dockWindowNumber = window[kCGWindowNumber] as? CGWindowID
                break
            }
        }
        if let dockWinNum = dockWindowNumber {
            windowListArray = CGWindowListCreate(
                [.optionOnScreenBelowWindow, .excludeDesktopElements],
                dockWinNum
            )!
            windows = CGWindowListCreateDescriptionFromArray(windowListArray)! as! [[CFString: Any]]
        }
    }

    LuaSkin.shared(withState: nil)!.pushNSObject(windows as NSArray)
    return 1
}

/// hs.window.timeout(value) -> boolean
/// Function
/// Sets the timeout value used in the accessibility API.
///
/// Parameters:
///  * value - The number of seconds for the new timeout value.
///
/// Returns:
///  * `true` is succesful otherwise `false` if an error occurred.
private func window_timeout(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TNUMBER, LS_TBREAK)
    let value = skin.toNSObject(atIndex: 1) as! NSNumber
    let fvalue = value.floatValue
    let result = AXUIElementSetMessagingTimeout(systemWideElement, fvalue)
    if result == .illegalArgument {
        LuaSkin.logError("hs.window.timeout() - One or more of the arguments is an illegal value (timeout values must be positive).")
        lua_pushboolean(L, 0)
        return 1
    }
    if result == .invalidUIElement {
        LuaSkin.logError("hs.window.timeout() - The AXUIElementRef is invalid.")
        lua_pushboolean(L, 0)
        return 1
    }
    lua_pushboolean(L, 1)
    return 1
}

/// hs.window.focusedWindow() -> window
/// Constructor
/// Returns the window that has keyboard/mouse focus
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.window` object representing the currently focused window
private func window_focusedwindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(HSwindow.focusedWindow())
    return 1
}

/// hs.window:title() -> string
/// Method
/// Gets the title of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the title of the window
private func window_title(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSObject(win.title)
    return 1
}

/// hs.window:subrole() -> string
/// Method
/// Gets the subrole of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the subrole of the window
///
/// Notes:
///  * This typically helps to determine if a window is a special kind of window - such as a modal window, or a floating window
private func window_subrole(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSObject(win.subRole)
    return 1
}

/// hs.window:role() -> string
/// Method
/// Gets the role of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the role of the window
private func window_role(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSObject(win.role)
    return 1
}

/// hs.window:isStandard() -> bool
/// Method
/// Determines if the window is a standard window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is standard, otherwise false
///
/// Notes:
///  * "Standard window" means that this is not an unusual popup window, a modal dialog, a floating window, etc.
private func window_isstandard(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushboolean(L, win.isStandard ? 1 : 0)
    return 1
}

/// hs.window:topLeft() -> point
/// Method
/// Gets the absolute co-ordinates of the top left of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A point-table containing the absolute co-ordinates of the top left corner of the window
private func window__topleft(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSPoint(win.topLeft)
    return 1
}

/// hs.window:size() -> size
/// Method
/// Gets the size of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A size-table containing the width and height of the window
private func window__size(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSSize(win.size)
    return 1
}

/// hs.window:setTopLeft(point) -> window
/// Method
/// Moves the window to a given point
///
/// Parameters:
///  * point - A point-table containing the absolute co-ordinates the window should be moved to
///
/// Returns:
///  * The `hs.window` object
private func window__settopleft(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.topLeft = skin.tableToPoint(atIndex: 2)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:setSize(size) -> window
/// Method
/// Resizes the window
///
/// Parameters:
///  * size - A size-table containing the width and height the window should be resized to
///
/// Returns:
///  * The `hs.window` object
private func window__setsize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.size = skin.tableToSize(atIndex: 2)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:_setFrame(frame) -> window
/// Method
/// Sets the frame of the window instantly using the three-step resize process with Enhanced UI management
///
/// Parameters:
///  * frame - A table containing x, y, w, h keys for the window frame
///
/// Returns:
///  * The `hs.window` object
///
/// Notes:
///  * This is an internal method that implements the standard three-step size,position,size pattern
///  * Disables AXEnhancedUserInterface during the operation for better reliability
///  * This should be preferred over calling _setSize and _setTopLeft separately
private func window__setframe(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    let frame = skin.tableToRect(atIndex: 2)
    win.setFrame(frame)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:toggleZoom() -> window
/// Method
/// Toggles the zoom state of the window (this is effectively equivalent to clicking the green maximize/fullscreen button at the top left of a window)
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
private func window__togglezoom(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.toggleZoom()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:zoomButtonRect() -> rect-table or nil
/// Method
/// Gets a rect-table for the location of the zoom button (the green button typically found at the top left of a window)
///
/// Parameters:
///  * None
///
/// Returns:
///  * A rect-table containing the bounding frame of the zoom button, or nil if an error occurred
///
/// Notes:
///  * The co-ordinates in the rect-table (i.e. the `x` and `y` values) are in absolute co-ordinates, not relative to the window the button is part of, or the screen the window is on
///  * Although not perfect as such, this method can provide a useful way to find a region of the titlebar suitable for simulating mouse click events on, with `hs.eventtap`
private func window_getZoomButtonRect(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSRect(win.zoomButtonRect)
    return 1
}

/// hs.window:isMaximizable() -> bool or nil
/// Method
/// Determines if a window is maximizable
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is maximizable, False if it isn't, or nil if an error occurred
private func window_isMaximizable(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow

    var button: CFTypeRef?
    var isEnabled: CFTypeRef?

    guard AXUIElementCopyAttributeValue(win.elementRef, kAXZoomButtonAttribute as CFString, &button) == .success else {
        lua_pushnil(L)
        return 1
    }
    guard AXUIElementCopyAttributeValue(button as! AXUIElement, kAXEnabledAttribute as CFString, &isEnabled) == .success else {
        lua_pushnil(L)
        return 1
    }

    lua_pushboolean(L, (isEnabled as! CFBoolean) == kCFBooleanTrue ? 1 : 0)
    return 1
}

/// hs.window:close() -> bool
/// Method
/// Closes the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the operation succeeded, false if not
private func window__close(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushboolean(L, win.close() ? 1 : 0)
    return 1
}

/// hs.window:focusTab(index) -> bool
/// Method
/// Focuses the tab in the window's tab group at index, or the last tab if index is out of bounds
///
/// Parameters:
///  * index - A number, a 1-based index of a tab to focus
///
/// Returns:
///  * true if the tab was successfully pressed, or false if there was a problem
///
/// Notes:
///  * This method works with document tab groups and some app tabs, like Chrome and Safari.
private func window_focustab(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    let tabIndex = Int32(lua_tointeger(L, 2))
    lua_pushboolean(L, win.focusTab(tabIndex) ? 1 : 0)
    return 1
}

/// hs.window:tabCount() -> number or nil
/// Method
/// Gets the number of tabs in the window has
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of tabs, or nil if an error occurred
///
/// Notes:
///  * Intended for use with the focusTab method, if this returns a number, then focusTab can switch between that many tabs.
private func window_tabcount(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushinteger(L, lua_Integer(win.tabCount))
    return 1
}

/// hs.window:setFullScreen(fullscreen) -> window
/// Method
/// Sets the fullscreen state of the window
///
/// Parameters:
///  * fullscreen - A boolean, true if the window should be set fullscreen, false if not
///
/// Returns:
///  * The `hs.window` object
private func window__setfullscreen(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.fullscreen = lua_toboolean(L, 2) != 0
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:isFullScreen() -> bool or nil
/// Method
/// Gets the fullscreen state of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is fullscreen, false if not. Nil if an error occurred
private func window_isfullscreen(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushboolean(L, win.fullscreen ? 1 : 0)
    return 1
}

/// hs.window:minimize() -> window
/// Method
/// Minimizes the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
///
/// Notes:
///  * This method will always animate per your system settings and is not affected by `hs.window.animationDuration`
private func window__minimize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.minimized = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:unminimize() -> window
/// Method
/// Un-minimizes the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
private func window__unminimize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.minimized = false
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:isMinimized() -> bool
/// Method
/// Gets the minimized state of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is minimized, otherwise false
private func window_isminimized(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushboolean(L, win.minimized ? 1 : 0)
    return 1
}

// hs.window:pid()
private func window_pid(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushinteger(L, lua_Integer(win.pid))
    return 1
}

/// hs.window:application() -> app or nil
/// Method
/// Gets the `hs.application` object the window belongs to
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.application` object representing the application that owns the window, or nil if an error occurred
private func window_application(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    let app = HSapplication(pid: win.pid, withState: L)
    lua_settop(L, 0)
    if app == nil {
        lua_pushnil(L)
    } else {
        skin.pushNSObject(app)
    }
    return 1
}

/// hs.window:becomeMain() -> window
/// Method
/// Makes the window the main window of its application
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
///
/// Notes:
///  * Make a window become the main window does not transfer focus to the application. See `hs.window.focus()`
private func window_becomemain(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.becomeMain()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.window:raise() -> window
/// Method
/// Brings a window to the front of the screen without focussing it
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
private func window_raise(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    win.raise()
    lua_pushvalue(L, 1)
    return 1
}

private func window__orderedwinids(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(HSwindow.orderedWindowIDs())
    return 1
}

/// hs.window:id() -> number or nil
/// Method
/// Gets the unique identifier of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the unique identifier of the window, or nil if an error occurred
private func window_id(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    lua_pushinteger(L, lua_Integer(win.winID))
    return 1
}

/// hs.window.setShadows(shadows)
/// Function
/// Enables/Disables window shadows
///
/// Parameters:
///  * shadows - A boolean, true to show window shadows, false to hide window shadows
///
/// Returns:
///  * None
///
/// Notes:
///  * This function uses a private, undocumented OS X API call, so it is not guaranteed to work in any future OS X release
private func window_setShadows(_ L: OpaquePointer!) -> Int32 {
    luaL_checktype(L, 1, LUA_TBOOLEAN)
    let shadows = lua_toboolean(L, 1) != 0

    // CoreGraphics private API for window shadows
    typealias CGSSetDebugOptionsFunc = @convention(c) (Int32) -> Void
    let kCGSDebugOptionNormal: Int32 = 0
    let kCGSDebugOptionNoShadows: Int32 = 16384

    if let handle = dlopen(nil, RTLD_LAZY),
       let sym = dlsym(handle, "CGSSetDebugOptions") {
        let fn = unsafeBitCast(sym, to: CGSSetDebugOptionsFunc.self)
        fn(shadows ? kCGSDebugOptionNormal : kCGSDebugOptionNoShadows)
        dlclose(handle)
    }

    return 0
}

/// hs.window.snapshotForID(ID [, keepTransparency]) -> hs.image-object
/// Function
/// Returns a snapshot of the window specified by the ID as an `hs.image` object
///
/// Parameters:
///  * ID - Window ID of the window to take a snapshot of.
///  * keepTransparency - optional boolean value indicating if the windows alpha value (transparency) should be maintained in the resulting image or if it should be fully opaque (default).
///
/// Returns:
///  * `hs.image` object of the window snapshot or nil if unable to create a snapshot
///
/// Notes:
///  * See also method `hs.window:snapshot()`
///  * Because the window ID cannot always be dynamically determined, this function will allow you to provide the ID of a window that was cached earlier.
private func window_snapshotForID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TNUMBER | LS_TSTRING, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let windowID = CGWindowID(lua_tointeger(L, 1))
    skin.pushNSObject(HSwindow.snapshot(forID: windowID, keepTransparency: lua_toboolean(L, 2) != 0))
    return 1
}

/// hs.window:snapshot([keepTransparency]) -> hs.image-object
/// Method
/// Returns a snapshot of the window as an `hs.image` object
///
/// Parameters:
///  * keepTransparency - optional boolean value indicating if the windows alpha value (transparency) should be maintained in the resulting image or if it should be fully opaque (default).
///
/// Returns:
///  * `hs.image` object of the window snapshot or nil if unable to create a snapshot
///
/// Notes:
///  * See also function `hs.window.snapshotForID()`
private func window_snapshot(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    skin.pushNSObject(win.snapshot(lua_toboolean(L, 2) != 0))
    return 1
}

// MARK: - hs.uielement methods

private func window_uielement_isApplication(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement!
    lua_pushboolean(L, uiElement.role == "AXApplication" ? 1 : 0)
    return 1
}

private func window_uielement_isWindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement!
    lua_pushboolean(L, uiElement.isWindow ? 1 : 0)
    return 1
}

private func window_uielement_role(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement!
    skin.pushNSObject(uiElement.role)
    return 1
}

private func window_uielement_selectedText(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement!
    skin.pushNSObject(uiElement.selectedText)
    return 1
}

private func window_uielement_newWatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION, LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    let uiElement = win.uiElement!
    let watcher = uiElement.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)!
    skin.pushNSObject(watcher)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSwindow(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let value = obj as! HSwindow
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSwindowFromLua(_ L: OpaquePointer!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.shared(withState: L)!
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<HSwindow>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        skin.logError(String(format: "expected %s object, found %s",
                             USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let win: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
    let str = String(format: "%s: %@ (%p)", USERDATA_TAG, win.title ?? "" as NSString, lua_topointer(L, 1)!)
    lua_pushstring(L, str)
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)!
        let win1: HSwindow = skin.toNSObject(atIndex: 1) as! HSwindow
        let win2: HSwindow = skin.toNSObject(atIndex: 2) as! HSwindow
        isEqual = CFEqual(win1.elementRef, win2.elementRef)
    }
    lua_pushboolean(L, isEqual ? 1 : 0)
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let win = Unmanaged<HSwindow>.fromOpaque(rawPtr).takeRetainedValue()
        win.selfRefCount -= 1
        if win.selfRefCount == 0 {
            // allow ARC to release
        }
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Module functions
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("focusedWindow"), func: window_focusedwindow),
    luaL_Reg(name: strdup("_orderedwinids"), func: window__orderedwinids),
    luaL_Reg(name: strdup("setShadows"), func: window_setShadows),
    luaL_Reg(name: strdup("snapshotForID"), func: window_snapshotForID),
    luaL_Reg(name: strdup("timeout"), func: window_timeout),
    luaL_Reg(name: strdup("list"), func: window_list),
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("title"), func: window_title),
    luaL_Reg(name: strdup("subrole"), func: window_subrole),
    luaL_Reg(name: strdup("role"), func: window_role),
    luaL_Reg(name: strdup("isStandard"), func: window_isstandard),
    luaL_Reg(name: strdup("_topLeft"), func: window__topleft),
    luaL_Reg(name: strdup("_size"), func: window__size),
    luaL_Reg(name: strdup("_setTopLeft"), func: window__settopleft),
    luaL_Reg(name: strdup("_setSize"), func: window__setsize),
    luaL_Reg(name: strdup("_setFrame"), func: window__setframe),
    luaL_Reg(name: strdup("_minimize"), func: window__minimize),
    luaL_Reg(name: strdup("_unminimize"), func: window__unminimize),
    luaL_Reg(name: strdup("isMinimized"), func: window_isminimized),
    luaL_Reg(name: strdup("isMaximizable"), func: window_isMaximizable),
    luaL_Reg(name: strdup("pid"), func: window_pid),
    luaL_Reg(name: strdup("application"), func: window_application),
    luaL_Reg(name: strdup("focusTab"), func: window_focustab),
    luaL_Reg(name: strdup("tabCount"), func: window_tabcount),
    luaL_Reg(name: strdup("becomeMain"), func: window_becomemain),
    luaL_Reg(name: strdup("raise"), func: window_raise),
    luaL_Reg(name: strdup("id"), func: window_id),
    luaL_Reg(name: strdup("_toggleZoom"), func: window__togglezoom),
    luaL_Reg(name: strdup("zoomButtonRect"), func: window_getZoomButtonRect),
    luaL_Reg(name: strdup("_close"), func: window__close),
    luaL_Reg(name: strdup("_setFullScreen"), func: window__setfullscreen),
    luaL_Reg(name: strdup("isFullScreen"), func: window_isfullscreen),
    luaL_Reg(name: strdup("snapshot"), func: window_snapshot),

    // hs.uielement methods
    luaL_Reg(name: strdup("isApplication"), func: window_uielement_isApplication),
    luaL_Reg(name: strdup("isWindow"), func: window_uielement_isWindow),
    luaL_Reg(name: strdup("role"), func: window_uielement_role),
    luaL_Reg(name: strdup("selectedText"), func: window_uielement_selectedText),
    luaL_Reg(name: strdup("newWatcher"), func: window_uielement_newWatcher),

    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwindow")
public func luaopen_hs_libwindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &module_metaLib)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushHSwindow, forClass: "HSwindow")
    skin.registerLuaObjectHelper(toHSwindowFromLua, forClass: "HSwindow",
                                 withUserdataMapping: USERDATA_TAG)
    return 1
}
