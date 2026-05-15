import Cocoa
import LuaSkin

/// hs.dockicon.visible() -> bool
/// Function
/// Determine whether Hammerspoon's dock icon is visible
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the dock icon is visible, false if not
private func icon_visible(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushboolean(L, MJDockIconVisible() ? 1 : 0)
    return 1
}

/// hs.dockicon.show()
/// Function
/// Make Hammerspoon's dock icon visible
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func icon_show(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    MJDockIconSetVisible(true)
    return 0
}

/// hs.dockicon.hide()
/// Function
/// Hide Hammerspoon's dock icon
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func icon_hide(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    MJDockIconSetVisible(false)
    return 0
}

/// hs.dockicon.bounce(indefinitely)
/// Function
/// Bounce Hammerspoon's dock icon
///
/// Parameters:
///  * indefinitely - A boolean value, true if the dock icon should bounce until the dock icon is clicked, false if the dock icon should only bounce briefly
///
/// Returns:
///  * None
private func icon_bounce(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let requestType: NSApplication.RequestUserAttentionType = lua_toboolean(L, 1) != 0 ? .criticalRequest : .informationalRequest
    NSApplication.shared.requestUserAttention(requestType)
    return 0
}

/// hs.dockicon.setBadge(badge)
/// Function
/// Set Hammerspoon's dock icon badge
///
/// Parameters:
///  * badge - A string containing the label to place inside the dock icon badge. If the string is empty, the badge will be cleared
///
/// Returns:
///  * None
private func icon_setBadge(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
/// Get or set a canvas object to be displayed as the Hammerspoon dock icon
///
/// Parameters:
///  * `canvas` - an optional `hs.canvas` object specifying the canvas to be displayed as the dock icon for Hammerspoon. If an explicit `nil` is specified, the dock icon will revert to the Hammerspoon application icon.
///
/// Returns:
///  * If the dock icon is assigned a canvas object, that canvas object will be returned, otherwise returns nil.
///
/// Notes:
///  * If you update the canvas object by changing any of its components, it will not be reflected in the dock icon until you invoke [hs.dockicon.tileUpdate](#tileUpdate).
private func icon_docktileCanvas(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let tile = NSApplication.shared.dockTile

    if lua_gettop(L) != 0 {
        let oldView = tile.contentView
        if lua_type(L, 1) == LUA_TNIL {
            tile.contentView = nil
        } else {
            skin.checkArgs(LS_TUSERDATA, "hs.canvas", LS_TBREAK)
            tile.contentView = skin.toNSObject(atIndex: 1) as? NSView
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
    skin.pushNSObject(tile.contentView)
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
///  * a table containing the size of the tile representing the dock icon for Hammerspoon. This table will contain `h` and `w` keys specifying the tile height and width as numbers.
///
/// Notes:
///  * the size returned specifies the display size of the dock icon tile. If your canvas item is larger than this, then only the top left portion corresponding to the size returned will be displayed.
private func icon_docktileSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    let tile = NSApplication.shared.dockTile

    skin.pushNSSize(tile.size)
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
private func icon_docktileUpdate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    let tile = NSApplication.shared.dockTile

    tile.display()
    return 0
}

private var icon_lib: [luaL_Reg] = [
    luaL_Reg(name: strdup("visible"),    func: icon_visible),
    luaL_Reg(name: strdup("show"),       func: icon_show),
    luaL_Reg(name: strdup("hide"),       func: icon_hide),
    luaL_Reg(name: strdup("bounce"),     func: icon_bounce),
    luaL_Reg(name: strdup("setBadge"),   func: icon_setBadge),
    luaL_Reg(name: strdup("tileCanvas"), func: icon_docktileCanvas),
    luaL_Reg(name: strdup("tileSize"),   func: icon_docktileSize),
    luaL_Reg(name: strdup("tileUpdate"), func: icon_docktileUpdate),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libdockicon")
public func luaopen_hs_libdockicon(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.dockicon", functions: &icon_lib, metaFunctions: nil)

    return 1
}
