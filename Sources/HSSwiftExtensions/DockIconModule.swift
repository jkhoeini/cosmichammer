import Cocoa
import CLua
import Lua

/// hs.dockicon.visible() -> bool
/// Function
/// Determine whether Cosmic Hammer's dock icon is visible
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the dock icon is visible, false if not
private func icon_visible(_ L: LuaState) throws -> CInt {
    lua_pushboolean(L, MJDockIconVisible() ? 1 : 0)
    return 1
}

/// hs.dockicon.show()
/// Function
/// Make Cosmic Hammer's dock icon visible
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func icon_show(_ L: LuaState) throws -> CInt {
    MJDockIconSetVisible(true)
    return 0
}

/// hs.dockicon.hide()
/// Function
/// Hide Cosmic Hammer's dock icon
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func icon_hide(_ L: LuaState) throws -> CInt {
    MJDockIconSetVisible(false)
    return 0
}

/// hs.dockicon.bounce(indefinitely)
/// Function
/// Bounce Cosmic Hammer's dock icon
///
/// Parameters:
///  * indefinitely - A boolean value, true if the dock icon should bounce until the dock icon is clicked, false if the dock icon should only bounce briefly
///
/// Returns:
///  * None
private func icon_bounce(_ L: LuaState) throws -> CInt {
    let requestType: NSApplication.RequestUserAttentionType = lua_toboolean(L, 1) != 0 ? .criticalRequest : .informationalRequest
    NSApplication.shared.requestUserAttention(requestType)
    return 0
}

/// hs.dockicon.setBadge(badge)
/// Function
/// Set Cosmic Hammer's dock icon badge
///
/// Parameters:
///  * badge - A string containing the label to place inside the dock icon badge. If the string is empty, the badge will be cleared
///
/// Returns:
///  * None
private func icon_setBadge(_ L: LuaState) throws -> CInt {
    let tile = NSApplication.shared.dockTile
    tile.badgeLabel = String(cString: luaL_checkstring(L, 1))
    tile.display()
    return 0
}

@objc protocol HSCanvasViewProtocol {
    @objc var wrapperWindow: NSWindow? { get }
}

/// hs.dockicon.tileCanvas([canvas]) -> canvasObject | nil
/// Function
/// Get or set a canvas object to be displayed as the Cosmic Hammer dock icon
///
/// Parameters:
///  * `canvas` - an optional `hs.canvas` object specifying the canvas to be displayed as the dock icon for Cosmic Hammer. If an explicit `nil` is specified, the dock icon will revert to the Cosmic Hammer application icon.
///
/// Returns:
///  * If the dock icon is assigned a canvas object, that canvas object will be returned, otherwise returns nil.
///
/// Notes:
///  * If you update the canvas object by changing any of its components, it will not be reflected in the dock icon until you invoke [hs.dockicon.tileUpdate](#tileUpdate).
private func icon_docktileCanvas(_ L: LuaState) throws -> CInt {
    let tile = NSApplication.shared.dockTile

    if lua_gettop(L) != 0 {
        let oldView = tile.contentView
        if lua_type(L, 1) == LUA_TNIL {
            tile.contentView = nil
        } else {
            luaL_checkudata(L, 1, "hs.canvas")
            let ptr = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let rawPtr = ptr.pointee {
                tile.contentView = Unmanaged<AnyObject>.fromOpaque(rawPtr).takeUnretainedValue() as? NSView
            }
        }
        tile.display()
        // if canvas removed from tile, reattach it so it can be displayed as a canvas again
        if let oldView = oldView, oldView != tile.contentView,
           oldView.isKind(of: NSClassFromString("HSCanvasView")!) {
            if let canvasView = oldView as? HSCanvasViewProtocol,
               let window = canvasView.wrapperWindow {
                window.contentView = oldView
            }
        }
    }
    if tile.contentView != nil {
        lua_pushany(L, "\(tile.contentView!)")
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.dockicon.tileSize() -> size table
/// Function
/// Returns a table containing the size of the tile representing the dock icon.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the size of the tile representing the dock icon for Cosmic Hammer. This table will contain `h` and `w` keys specifying the tile height and width as numbers.
///
/// Notes:
///  * the size returned specifies the display size of the dock icon tile. If your canvas item is larger than this, then only the top left portion corresponding to the size returned will be displayed.
private func icon_docktileSize(_ L: LuaState) throws -> CInt {
    let tile = NSApplication.shared.dockTile
    lua_pushNSSize(L, tile.size)
    return 1
}

/// hs.dockicon.tileUpdate() -> none
/// Function
/// Force an update of the dock icon.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
///
/// Notes:
///  * Changes made to a canvas object are not reflected automatically like they are when a canvas is being displayed on the screen; you must invoke this method after making changes to the canvas for the updates to be reflected in the dock icon.
private func icon_docktileUpdate(_ L: LuaState) throws -> CInt {
    let tile = NSApplication.shared.dockTile
    tile.display()
    return 0
}


@_cdecl("luaopen_hs_libdockicon")
public func luaopen_hs_libdockicon(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create module table
        lua_createtable(L, 0, 8)
        L.push(icon_visible)
        lua_setfield(L, -2, "visible")
        L.push(icon_show)
        lua_setfield(L, -2, "show")
        L.push(icon_hide)
        lua_setfield(L, -2, "hide")
        L.push(icon_bounce)
        lua_setfield(L, -2, "bounce")
        L.push(icon_setBadge)
        lua_setfield(L, -2, "setBadge")
        L.push(icon_docktileCanvas)
        lua_setfield(L, -2, "tileCanvas")
        L.push(icon_docktileSize)
        lua_setfield(L, -2, "tileSize")
        L.push(icon_docktileUpdate)
        lua_setfield(L, -2, "tileUpdate")
    }
}
