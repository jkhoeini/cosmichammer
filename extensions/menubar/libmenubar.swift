import Cocoa
import Carbon
import LuaSkin

// MARK: - Definitions

private let USERDATA_TAG = "hs.menubar"
private var refTable: LSRefTable = LUA_NOREF

private func get_item_arg(_ L: OpaquePointer!, _ idx: Int32) -> UnsafeMutablePointer<menubaritem_t> {
    return luaL_checkudata(L, idx, USERDATA_TAG)!.assumingMemoryBound(to: menubaritem_t.self)
}

// Adds undocumented "appearance" argument to "popUpMenuPositioningItem"
@objc private protocol NSMenuMISSINGOrder {
    @objc func popUpMenuPositioningItem(_ item: Any?, atLocation location: CGPoint, in view: Any?, appearance: Any?) -> Bool
}

// MARK: - Callback Objects

@objc private class HSMenubarCallbackObject: NSObject {
    var fn: Int32 = LUA_NOREF
    var item: Int32 = LUA_NOREF

    func callback_runner() {
        let skin = LuaSkin.shared(withState: nil)!
        let L = skin.L!

        var fn_result: Bool

        let event = NSApp.currentEvent

        skin.pushLuaRef(refTable, ref: fn)

        if let event = event {
            let theFlags = event.modifierFlags
            let isCommandKey = theFlags.contains(.command)
            let isShiftKey   = theFlags.contains(.shift)
            let isOptKey     = theFlags.contains(.option)
            let isCtrlKey    = theFlags.contains(.control)
            let isFnKey      = theFlags.contains(.function)

            lua_newtable(L)

            lua_pushboolean(L, isCommandKey ? 1 : 0)
            lua_setfield(L, -2, "cmd")

            lua_pushboolean(L, isShiftKey ? 1 : 0)
            lua_setfield(L, -2, "shift")

            lua_pushboolean(L, isOptKey ? 1 : 0)
            lua_setfield(L, -2, "alt")

            lua_pushboolean(L, isCtrlKey ? 1 : 0)
            lua_setfield(L, -2, "ctrl")

            lua_pushboolean(L, isFnKey ? 1 : 0)
            lua_setfield(L, -2, "fn")

            skin.pushLuaRef(refTable, ref: item)

            fn_result = skin.protectedCallAndTraceback(2, nresults: 1)
        } else {
            fn_result = skin.protectedCallAndTraceback(0, nresults: 1)
        }

        if !fn_result {
            let errorMsg = String(cString: lua_tostring(L, -1))
            skin.logError("hs.menubar:setClickCallback() callback error: \(errorMsg)")
            return
        }
    }
}

// MARK: - Menubar item struct

private struct menubaritem_t {
    var menuBarItemObject: UnsafeMutableRawPointer?
    var click_callback: UnsafeMutableRawPointer?
    var click_fn: Int32
    var removed: Bool
    var stateBoxImageSize: NSSize
}

// Delegate objects
private var dynamicMenuDelegates: NSMutableArray!

@objc private class HSMenubarItemClickDelegate: HSMenubarCallbackObject {
    @objc func click(_ sender: Any?) {
        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)
        // Issue #909 -- if the callback causes the menu to be replaced, we crash if this delegate
        // disappears from beneath us... this keeps it from being collected before the callback is done.
        var myDelegate: NSObject? = nil
        if let menuItem = sender as? NSMenuItem {
            myDelegate = menuItem.representedObject as? NSObject
        }
        callback_runner()
        lua_pop(skin.L, 1)
        _lua_stackguard_exit(skin.L)
        myDelegate = nil // NOTE: DO NOT USE `self` AFTER THIS POINT
    }
}

@objc private class HSMenubarItemMenuDelegate: HSMenubarCallbackObject, NSMenuDelegate {
    var stateBoxImageSize: NSSize = .zero

    func menuNeedsUpdate(_ menu: NSMenu) {
        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)
        callback_runner()

        if lua_type(skin.L, lua_gettop(skin.L)) == LUA_TTABLE {
            erase_menu_items(skin.L, menu)
            parse_table(skin.L, lua_gettop(skin.L), menu, stateBoxImageSize)
        } else {
            skin.logError("hs.menubar:setMenu() callback must return a valid table")
        }
        lua_pop(skin.L, 1)
        _lua_stackguard_exit(skin.L)
    }
}

// MARK: - Helper functions

private func proportionallyScaleStateImageSize(_ theImage: NSImage, _ stateBoxImageSize: NSSize) -> NSSize {
    let sourceSize = theImage.size
    let ratio = fmin(stateBoxImageSize.height / sourceSize.height, stateBoxImageSize.width / sourceSize.width)
    return NSSize(width: sourceSize.width * ratio, height: sourceSize.height * ratio)
}

// Helper function to parse a Lua table and turn it into an NSMenu hierarchy
private func parse_table(_ L: OpaquePointer!, _ idx: Int32, _ menu: NSMenu, _ stateBoxImageSize: NSSize) {
    let skin = LuaSkin.shared(withState: L)!

    lua_pushnil(L)
    while lua_next(L, idx) != 0 {
        if lua_type(L, -1) != LUA_TTABLE {
            skin.logBreadcrumb("Error: table entry is not a menu item table: \(String(cString: lua_typename(L, lua_type(L, -1))))")
            lua_pop(L, 1)
            continue
        }

        // MARK: title key
        let titleType = lua_getfield(L, -1, "title")

        if !lua_isstring(L, -1) && luaL_testudata(L, -1, "hs.styledtext") == nil {
            skin.logBreadcrumb("Error: malformed menu table entry. Instead of a title string, we found: \(String(cString: lua_typename(L, lua_type(L, -1))))")
            lua_pop(L, 2)
            continue
        }

        let aTitle = skin.luaObjectAtIndex(-1, toClass: "NSAttributedString") as! NSAttributedString
        let title = aTitle.string

        lua_pop(L, 1)

        if title == "-" {
            menu.addItem(.separator())
        } else {
            let menuTitle = title ?? ""
            let menuItem = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
            if titleType != LUA_TSTRING { menuItem.attributedTitle = aTitle }

            // MARK: menu key
            lua_getfield(L, -1, "menu")
            if lua_istable(L, -1) {
                let subMenu = NSMenu(title: "HammerspoonSubMenu")
                subMenu.autoenablesItems = false
                if lua_checkstack(L, 20) != 0 {
                    parse_table(L, lua_gettop(L), subMenu, stateBoxImageSize)
                    menuItem.submenu = subMenu
                } else {
                    skin.logError("hs.menubar menu recursion depth exceeded.")
                }
            }
            lua_pop(L, 1)

            // MARK: fn key
            lua_getfield(L, -1, "fn")
            if lua_isfunction(L, -1) {
                let delegate = HSMenubarItemClickDelegate()
                lua_pushvalue(L, -1)
                delegate.fn = skin.luaRef(refTable)
                delegate.item = skin.luaRef(refTable, atIndex: -2)
                menuItem.target = delegate
                menuItem.action = #selector(HSMenubarItemClickDelegate.click(_:))
                menuItem.representedObject = delegate
            }
            lua_pop(L, 1)

            // MARK: disabled key
            lua_getfield(L, -1, "disabled")
            if lua_isboolean(L, -1) {
                menuItem.isEnabled = lua_toboolean(L, -1) == 0
            } else {
                menuItem.isEnabled = true
            }
            lua_pop(L, 1)

            // MARK: checked key
            lua_getfield(L, -1, "checked")
            if lua_isboolean(L, -1) {
                menuItem.state = lua_toboolean(L, -1) != 0 ? .on : .off
            } else {
                menuItem.state = .off
            }
            lua_pop(L, 1)

            // MARK: state key
            lua_getfield(L, -1, "state")
            if let state = skin.toNSObjectAtIndex(-1) as? String {
                if state == "on"    { menuItem.state = .on }
                if state == "off"   { menuItem.state = .off }
                if state == "mixed" { menuItem.state = .mixed }
            }
            lua_pop(L, 1)

            // MARK: tooltip key
            lua_getfield(L, -1, "tooltip")
            if lua_isstring(L, -1) {
                menuItem.toolTip = skin.toNSObjectAtIndex(-1) as? String
            }
            lua_pop(L, 1)

            // MARK: indent key
            lua_getfield(L, -1, "indent")
            var indentLevel = Int(lua_tointegerx(L, -1, nil))
            if indentLevel < 0  { indentLevel = 0 }
            if indentLevel > 15 { indentLevel = 15 }
            menuItem.indentationLevel = indentLevel
            lua_pop(L, 1)

            // MARK: image keys
            lua_getfield(L, -1, "image")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObjectAtIndex(-1, toClass: "NSImage") as? NSImage {
                    menuItem.image = image.copy() as? NSImage
                }
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "onStateImage")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObjectAtIndex(-1, toClass: "NSImage") as? NSImage {
                    let imageCopy = image.copy() as! NSImage
                    imageCopy.size = proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                    menuItem.onStateImage = imageCopy
                }
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "offStateImage")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObjectAtIndex(-1, toClass: "NSImage") as? NSImage {
                    let imageCopy = image.copy() as! NSImage
                    imageCopy.size = proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                    menuItem.offStateImage = imageCopy
                }
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "mixedStateImage")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObjectAtIndex(-1, toClass: "NSImage") as? NSImage {
                    let imageCopy = image.copy() as! NSImage
                    imageCopy.size = proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                    menuItem.mixedStateImage = imageCopy
                }
            }
            lua_pop(L, 1)

            // MARK: shortcut key
            lua_getfield(L, -1, "shortcut")
            if lua_isstring(L, -1) {
                let shortcutKey = skin.toNSObjectAtIndex(-1) as! String
                menuItem.keyEquivalent = shortcutKey
                menuItem.keyEquivalentModifierMask = []
            }
            lua_pop(L, 1)

            menu.addItem(menuItem)
        }
        lua_pop(L, 1)
    }
}

// Recursively remove all items from a menu, de-allocating their delegates as we go
private func erase_menu_items(_ L: OpaquePointer!, _ menu: NSMenu) {
    let skin = LuaSkin.shared(withState: L)!

    for menuItem in menu.items {
        if let target = menuItem.representedObject as? HSMenubarItemClickDelegate {
            target.fn = skin.luaUnref(refTable, ref: target.fn)
            target.item = skin.luaUnref(refTable, ref: target.item)
            menuItem.target = nil
            menuItem.action = nil
            menuItem.representedObject = nil
        }
        if menuItem.hasSubmenu {
            erase_menu_items(L, menuItem.submenu!)
            menuItem.submenu = nil
        }
        menu.removeItem(menuItem)
    }
}

// Remove and clean up a dynamic menu delegate
private func erase_menu_delegate(_ L: OpaquePointer!, _ menu: NSMenu) {
    let skin = LuaSkin.shared(withState: L)!

    if let delegate = menu.delegate as? HSMenubarItemMenuDelegate {
        delegate.fn = skin.luaUnref(refTable, ref: delegate.fn)
        dynamicMenuDelegates.remove(delegate)
        menu.delegate = nil
    }
}

// Remove any kind of menu on a menubar item
private func erase_all_menu_parts(_ L: OpaquePointer!, _ statusItem: NSStatusItem) {
    if let menu = statusItem.menu {
        erase_menu_delegate(L, menu)
        erase_menu_items(L, menu)
        statusItem.menu = nil
    }
}

// Prepare an existing menu on a menubar item for reuse or create a new menu
private func create_or_reuse_menu(_ L: OpaquePointer!, _ statusItem: NSStatusItem, _ menuTitle: String) -> NSMenu {
    if let menu = statusItem.menu {
        erase_menu_delegate(L, menu)
        erase_menu_items(L, menu)
        statusItem.menu = nil
        menu.title = menuTitle
        return menu
    }
    return NSMenu(title: menuTitle)
}

// Create and push a lua geometry rect
private func geom_pushrect(_ L: OpaquePointer!, _ rect: NSRect) {
    lua_newtable(L)
    lua_pushnumber(L, Double(rect.origin.x));    lua_setfield(L, -2, "x")
    lua_pushnumber(L, Double(rect.origin.y));    lua_setfield(L, -2, "y")
    lua_pushnumber(L, Double(rect.size.width));  lua_setfield(L, -2, "w")
    lua_pushnumber(L, Double(rect.size.height)); lua_setfield(L, -2, "h")
}

// MARK: - API implementations

/// hs.menubar.new([inMenuBar], [autosaveName]) -> menubaritem or nil
/// Constructor
/// Creates a new menu bar item object and optionally add it to the system menubar
///
/// Parameters:
///  * inMenuBar - an optional parameter which defaults to true.  If it is true, the menubaritem is added to the system menubar, otherwise the menubaritem is hidden.
///  * autosaveName - an optional parameter allowing you to define an autosave name, so that macOS can restore the menubar position between restarts.
///
/// Returns:
///  * menubar item object to use with other API methods, or nil if it could not be created
///
/// Notes:
///  * You should call hs.menubar:setTitle() or hs.menubar:setIcon() after creating the object, otherwise it will be invisible
///
///  * Calling this method with inMenuBar equal to false is equivalent to calling hs.menubar.new():removeFromMenuBar().
///  * A hidden menubaritem can be added to the system menubar by calling hs.menubar:returnToMenuBar() or used as a pop-up menu by calling hs.menubar:popupMenu().
private func menubarNew(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    let statusBar = NSStatusBar.system
    var statusItem: NSStatusItem

    if lua_isboolean(L, 1) && lua_toboolean(L, 1) == 0 {
        statusItem = NSStatusItem()
    } else {
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    }

    if lua_isstring(L, 2) {
        let autosaveName = skin.toNSObjectAtIndex(2) as! String

        let preferredPositionString = "NSStatusItem Preferred Position"
        var key = "HS\(preferredPositionString) \(autosaveName)"
        let autosaveValue = UserDefaults.standard.object(forKey: key) as? NSNumber

        key = "\(preferredPositionString) \(autosaveName)"
        UserDefaults.standard.set(autosaveValue, forKey: key)

        statusItem.autosaveName = NSStatusItem.AutosaveName(autosaveName)
    }

    statusItem.button?.imagePosition = .imageLeading
    let menuBarItem = lua_newuserdata(L, MemoryLayout<menubaritem_t>.size)!.assumingMemoryBound(to: menubaritem_t.self)
    memset(menuBarItem, 0, MemoryLayout<menubaritem_t>.size)

    menuBarItem.pointee.menuBarItemObject = Unmanaged.passRetained(statusItem).toOpaque()
    menuBarItem.pointee.click_callback = nil
    menuBarItem.pointee.click_fn = LUA_NOREF
    menuBarItem.pointee.removed = false

    let defaultFromFont = NSFont.menuFont(ofSize: 0).pointSize
    menuBarItem.pointee.stateBoxImageSize = NSSize(width: defaultFromFont, height: defaultFromFont)

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    if lua_isboolean(L, 1) && lua_toboolean(L, 1) == 0 {
        menuBarItem.pointee.removed = true
    }

    return 1
}

/// hs.menubar:autosaveName([name]) -> menubaritem | current-value
/// Method
/// Get or set the autosave name of the menubar. By defining an autosave name, macOS can restore the menubar position after reloads.
///
/// Parameters:
///  * name - An optional string if you want to set the autosave name
///
/// Returns:
///  * Either the menubar item, if its autosave name was changed, or the current value of the autosave name
private func menubar_autosaveName(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TSTRING | LS_TOPTIONAL,
                   LS_TBREAK)
    let menuBarItem = get_item_arg(L, 1)
    let menuItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if lua_gettop(L) == 2 {
        let autosaveName = skin.toNSObjectAtIndex(2) as! String

        let preferredPositionString = "NSStatusItem Preferred Position"
        var key = "HS\(preferredPositionString) \(autosaveName)"
        let autosaveValue = UserDefaults.standard.object(forKey: key) as? NSNumber

        key = "\(preferredPositionString) \(autosaveName)"
        UserDefaults.standard.set(autosaveValue, forKey: key)

        menuItem.autosaveName = NSStatusItem.AutosaveName(autosaveName)

        lua_settop(L, 1)
    } else {
        skin.pushNSObject(menuItem.autosaveName as NSString?)
    }
    return 1
}

/// hs.menubar:imagePosition([position]) -> menubaritem | current-value
/// Method
/// Get or set the position of a menubar image relative to its text title
///
/// Parameters:
///  * position - Either one of the values in `hs.menubar.imagePositions` which will be set, or nothing to return the current position
///
/// Returns:
///  * Either the menubar item, if its image position was changed, or the current value of the image position
private func menubarImagePosition(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL,
                   LS_TBREAK)
    let menuBarItem = get_item_arg(L, 1)
    let menuItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    let button = menuItem.button!

    if lua_gettop(L) == 2 {
        button.imagePosition = NSControl.ImagePosition(rawValue: UInt(lua_tointegerx(L, 2, nil)))!
        lua_settop(L, 1)
    } else {
        lua_pushinteger(L, lua_Integer(button.imagePosition.rawValue))
    }
    return 1
}

/// hs.menubar:setTitle(title) -> menubaritem
/// Method
/// Sets the title of a menubar item object. The title will be displayed in the system menubar
///
/// Parameters:
///  * `title` - A string or `hs.styledtext` object to use as the title, or nil to remove the title
///
/// Returns:
///  * the menubar item
///
/// Notes:
///  * If you set an icon as well as a title, they will both be displayed next to each other
///  * Has no affect on the display of a pop-up menu, but changes will be be in effect if hs.menubar:returnToMenuBar() is called on the menubaritem.
private func menubarSetTitle(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let menuBarItem = get_item_arg(L, 1)

    var titleText: String? = nil
    var titleAText: NSAttributedString? = nil

    let argType = lua_type(L, 2)
    if argType == LUA_TSTRING || argType == LUA_TNUMBER {
        luaL_checkstring(L, 2)
        titleText = skin.toNSObjectAtIndex(2) as? String
    } else if luaL_testudata(L, 2, "hs.styledtext") != nil || argType == LUA_TTABLE {
        titleAText = skin.luaObjectAtIndex(2, toClass: "NSAttributedString") as? NSAttributedString
    } else if !lua_isnoneornil(L, 2) {
        return luaL_error(L, "expected string, styled-text object, or nil")
    }

    let menuItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    if titleText == nil && titleAText == nil { menuItem.button?.title = "" }
    if let text = titleText { menuItem.button?.title = text }
    if let aText = titleAText { menuItem.button?.attributedTitle = aText }

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:setIcon(imageData[, template]) -> menubaritem or nil
/// Method
/// Sets the image of a menubar item object. The image will be displayed in the system menubar
///
/// Parameters:
///  * imageData - This can one of the following:
///   * An `hs.image` object
///   * A string containing a path to an image file
///   * A string beginning with `ASCII:` which signifies that the rest of the string is interpreted as a special form of ASCII diagram, which will be rendered to an image and used as the icon. See the notes below for information about the special format of ASCII diagram.
///   * nil, indicating that the current image is to be removed
///  * template - An optional boolean value which defaults to true. If it's true, the provided image will be treated as a "template" image, which allows it to automatically support OS X 10.10's Dark Mode. If it's false, the image will be used as is, supporting colour.
///
/// Returns:
///  * the menubaritem if the image was loaded and set, `nil` if it could not be found or loaded
// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
private func menubarSetIcon(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)
    var iconImage: NSImage? = nil

    if lua_isnoneornil(L, 2) {
        iconImage = nil
    } else {
        let skin = LuaSkin.shared(withState: L)!
        iconImage = skin.luaObjectAtIndex(2, toClass: "NSImage") as? NSImage

        guard let image = iconImage else {
            lua_pushnil(L)
            return 1
        }
        if lua_isboolean(L, 3) && lua_toboolean(L, 3) == 0 {
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        iconImage = image
    }
    Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue().button?.image = iconImage

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:setTooltip(tooltip) -> menubaritem
/// Method
/// Sets the tooltip text on a menubar item
///
/// Parameters:
///  * `tooltip` - A string to use as the tooltip
///
/// Returns:
///  * the menubaritem
///
/// Notes:
///  * Has no affect on the display of a pop-up menu, but changes will be be in effect if hs.menubar:returnToMenuBar() is called on the menubaritem.
private func menubarSetTooltip(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TSTRING, LS_TBREAK)
    let menuBarItem = get_item_arg(L, 1)
    let toolTipText = skin.toNSObjectAtIndex(2) as! String
    Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue().button?.toolTip = toolTipText

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:setClickCallback([fn]) -> menubaritem
/// Method
/// Registers a function to be called when the menubar item is clicked
///
/// Parameters:
///  * `fn` - An optional function to be called when the menubar item is clicked. If this argument is not provided, any existing function will be removed. The function can optionally accept a single argument, which will be a table containing boolean values indicating which keyboard modifiers were held down when the menubar item was clicked; The possible keys are:
///   * cmd
///   * alt
///   * shift
///   * ctrl
///   * fn
///
/// Returns:
///  * the menubaritem
///
/// Notes:
///  * If a menu has been attached to the menubar item, this callback will never be called
///  * Has no affect on the display of a pop-up menu, but changes will be be in effect if hs.menubar:returnToMenuBar() is called on the menubaritem.
private func menubarSetClickCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)

    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    // Remove any existing click callback
    menuBarItem.pointee.click_fn = skin.luaUnref(refTable, ref: menuBarItem.pointee.click_fn)
    if let callback = menuBarItem.pointee.click_callback {
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        let _ = Unmanaged<HSMenubarItemClickDelegate>.fromOpaque(callback).takeRetainedValue()
        menuBarItem.pointee.click_callback = nil
    }

    if lua_isfunction(L, 2) {
        lua_pushvalue(L, 2)
        menuBarItem.pointee.click_fn = skin.luaRef(refTable)
        let object = HSMenubarItemClickDelegate()
        object.fn = menuBarItem.pointee.click_fn
        menuBarItem.pointee.click_callback = Unmanaged.passRetained(object).toOpaque()
        statusItem.button?.target = object
        statusItem.button?.action = #selector(HSMenubarItemClickDelegate.click(_:))
    }

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:setMenu(menuTable) -> menubaritem
/// Method
/// Attaches a dropdown menu to the menubar item
///
/// Parameters:
///  * `menuTable`:
///   * If this argument is `nil`: Removes any previously registered menu
///   * If this argument is a table: Sets the menu for this menubar item to the supplied table.
///   * If this argument is a function: The function will be called each time the user clicks on the menubar item and the function should return a table that specifies the menu to be displayed.
///
/// Returns:
///  * the menubaritem
private func menubarSetMenu(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!

    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    var menu: NSMenu? = nil
    var delegate: HSMenubarItemMenuDelegate? = nil

    switch lua_type(L, 2) {
    case LUA_TTABLE:
        menu = create_or_reuse_menu(L, statusItem, "HammerspoonMenuItemStaticMenu")
        menu?.autoenablesItems = false
        parse_table(L, 2, menu!, menuBarItem.pointee.stateBoxImageSize)
        if menu?.numberOfItems == 0 {
            menu = nil
        }

    case LUA_TFUNCTION:
        menu = create_or_reuse_menu(L, statusItem, "HammerspoonMenuItemDynamicMenu")
        menu?.autoenablesItems = false
        delegate = HSMenubarItemMenuDelegate()
        delegate!.stateBoxImageSize = menuBarItem.pointee.stateBoxImageSize
        lua_pushvalue(L, 2)
        delegate!.fn = skin.luaRef(refTable)
        dynamicMenuDelegates.add(delegate!)

    default:
        break
    }

    if menu == nil {
        erase_all_menu_parts(L, statusItem)
    } else {
        statusItem.menu = menu
        if let del = delegate {
            menu?.delegate = del
        }
    }

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:delete()
/// Method
/// Removes the menubar item from the menubar and destroys it
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func menubar_delete(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)

    let statusBar = NSStatusBar.system
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeRetainedValue()

    // If an autosaveName exists, store the preferred position
    if let autosaveName = statusItem.autosaveName {
        let preferredPositionString = "NSStatusItem Preferred Position"
        var key = "\(preferredPositionString) \(autosaveName)"
        let autosaveValue = UserDefaults.standard.object(forKey: key) as? NSNumber

        key = "HS\(preferredPositionString) \(autosaveName)"
        UserDefaults.standard.set(autosaveValue, forKey: key)
    }

    // Remove any click callback the menubar item has
    lua_pushcfunction(L, menubarSetClickCallback)
    lua_pushvalue(L, 1)
    lua_pushnil(L)
    lua_call(L, 2, 0)

    // Remove all menu stuff associated with this item
    erase_all_menu_parts(L, statusItem)

    if !menuBarItem.pointee.removed {
        statusBar.removeStatusItem(statusItem)
        menuBarItem.pointee.removed = true
    }

    menuBarItem.pointee.menuBarItemObject = nil

    return 0
}

/// hs.menubar:popupMenu(point[, darkMode]) -> menubaritem
/// Method
/// Display a menubaritem as a pop up menu at the specified screen point.
///
/// Parameters:
///  * point - the location of the upper left corner of the pop-up menu to be displayed.
///  * darkMode - (optional) `true` to force the menubar dark (defaults to your macOS General Appearance settings)
///
/// Returns:
///  * The menubaritem
///
/// Notes:
///  * Items which trigger hs.menubar:setClickCallback() will invoke the callback function, but we cannot control the positioning of any visual elements the function may create -- calling this method on such an object is the equivalent of invoking its callback function directly.
///  * This method is blocking. Hammerspoon will be unable to respond to any other activity while the pop-up menu is being displayed.
///  * `darkMode` uses an undocumented macOS API call, so may break in a future release.
private func menubar_render(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    let menu = statusItem.menu

    var menuPoint = NSPoint.zero

    // Support darkMode for popup menus
    var darkMode = false
    if lua_gettop(L) > 2 {
        if lua_type(L, 3) == LUA_TBOOLEAN || lua_type(L, 3) == LUA_TNIL {
            if lua_type(L, 3) == LUA_TBOOLEAN {
                darkMode = lua_toboolean(L, 3) != 0
            } else {
                let ifStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
                darkMode = ifStyle == "Dark"
            }
            lua_remove(L, 3)
        }
    }
    let appearance = NSAppearance(named: darkMode ? .vibrantDark : .vibrantLight)

    switch lua_type(L, 2) {
    case LUA_TTABLE:
        lua_getfield(L, 2, "x")
        menuPoint.x = CGFloat(lua_tonumber(L, -1))
        lua_pop(L, 1)

        lua_getfield(L, 2, "y")
        menuPoint.y = CGFloat(lua_tonumber(L, -1))
        lua_pop(L, 1)

    default:
        skin.logError("hs.menubar:popupMenu() argument must be a valid hs.geometry.point table")
        lua_pushnil(L)
        return 1
    }

    guard let menu = menu else {
        if let callback = menuBarItem.pointee.click_callback {
            Unmanaged<HSMenubarItemClickDelegate>.fromOpaque(callback).takeUnretainedValue().click(nil)
        } else {
            skin.logWarn("hs.menubar:popupMenu() Missing menu object")
        }
        lua_settop(L, 1)
        return 1
    }

    menuPoint.y = NSScreen.screens[0].frame.size.height - menuPoint.y

    (menu as AnyObject).popUpMenuPositioningItem?(nil, atLocation: menuPoint, in: nil, appearance: appearance)

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:removeFromMenuBar() -> menubaritem
/// Method
/// Removes a menu from the system menu bar.  The item can still be used as a pop-up menu, unless you also delete it.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the menubaritem
private func menubar_removeFromMenuBar(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)

    if !menuBarItem.pointee.removed {
        let statusBar = NSStatusBar.system
        let oldStatusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeRetainedValue()
        let newStatusItem = NSStatusItem()

        menuBarItem.pointee.menuBarItemObject = Unmanaged.passRetained(newStatusItem).toOpaque()
        newStatusItem.button?.target  = oldStatusItem.button?.target
        newStatusItem.button?.action  = oldStatusItem.button?.action
        newStatusItem.menu            = oldStatusItem.menu
        newStatusItem.button?.title   = oldStatusItem.button?.title ?? ""
        newStatusItem.button?.image   = oldStatusItem.button?.image
        newStatusItem.button?.toolTip = oldStatusItem.button?.toolTip

        statusBar.removeStatusItem(oldStatusItem)
        menuBarItem.pointee.removed = true
    }

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:returnToMenuBar() -> menubaritem
/// Method
/// Returns a previously removed menu back to the system menu bar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the menubaritem
private func menubar_returnToMenuBar(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)

    if menuBarItem.pointee.removed {
        let statusBar = NSStatusBar.system
        let oldStatusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeRetainedValue()

        let newStatusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        menuBarItem.pointee.menuBarItemObject = Unmanaged.passRetained(newStatusItem).toOpaque()
        newStatusItem.button?.target  = oldStatusItem.button?.target
        newStatusItem.button?.action  = oldStatusItem.button?.action
        newStatusItem.menu            = oldStatusItem.menu
        newStatusItem.button?.title   = oldStatusItem.button?.title ?? ""
        newStatusItem.button?.image   = oldStatusItem.button?.image
        newStatusItem.button?.toolTip = oldStatusItem.button?.toolTip

        menuBarItem.pointee.removed = false
    }

    lua_settop(L, 1)
    return 1
}

/// hs.menubar:isInMenuBar() -> boolean
/// Method
/// Returns a boolean indicating whether or not the specified menu is currently in the OS X menubar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean indicating whether or not the specified menu is currently in the OS X menubar
private func menubar_isInMenubar(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)
    lua_pushboolean(L, !menuBarItem.pointee.removed ? 1 : 0)
    return 1
}

/// hs.menubar:title([styled]) -> string | styledtextObject
/// Method
/// Returns the current title of the menubar item object.
///
/// Parameters:
///  * styled - an optional boolean, defaulting to false, indicating that a styledtextObject representing the text of the menu title should be returned
///
/// Returns:
///  * the menubar item title, or an empty string, if there isn't one.  If `styled` is not set or is false, then a string is returned; otherwise a styledtextObject will be returned.
private func menubarGetTitle(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        skin.pushNSObject(statusItem.button?.attributedTitle)
    } else {
        skin.pushNSObject(statusItem.button?.title as NSString?)
    }
    return 1
}

/// hs.menubar:icon() -> hs.image object
/// Method
/// Returns the current icon of the menubar item object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the menubar item icon as an hs.image object, or nil, if there isn't one.
private func menubarGetIcon(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if let theImage = statusItem.button?.image {
        let skin = LuaSkin.shared(withState: L)!
        skin.pushNSObject(theImage)
    } else {
        lua_pushnil(L)
    }

    return 1
}

private func menubarFrame(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    if let statusBarWindow = statusItem.value(forKey: "window") as? NSWindow {
        geom_pushrect(L, statusBarWindow.frame)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.menubar:stateImageSize([size]) -> hs.image object | current value
/// Method
/// Get or set the size for state images when the menu is displayed.
///
/// Parameters:
///  * size - an optional table specifying the size for state images displayed when using the `checked` or `state` key in a menu table definition.  Defaults to a size determined by the system menu font point size.  If you specify an explicit nil, the size is reset to this default.
///
/// Returns:
///  * if a parameter is provided, returns the menubar item; otherwise returns the current value.
private func menubarStateImageSize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, UnsafeMutablePointer(mutating: (USERDATA_TAG as NSString).utf8String!),
                   LS_TTABLE | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if lua_gettop(L) == 1 {
        skin.pushNSSize(menuBarItem.pointee.stateBoxImageSize)
    } else {
        var newSize: NSSize
        if lua_type(L, 2) == LUA_TTABLE {
            newSize = skin.tableToSize(atIndex: 2)
        } else {
            let defaultFromFont = NSFont.menuFont(ofSize: 0).pointSize
            newSize = NSSize(width: defaultFromFont, height: defaultFromFont)
        }
        menuBarItem.pointee.stateBoxImageSize = newSize
        if let menu = statusItem.menu, let theDelegate = menu.delegate as? HSMenubarItemMenuDelegate {
            theDelegate.stateBoxImageSize = newSize
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

// MARK: - Lua/hs glue

/// hs.menubar.imagePositions[]
/// Constant
/// Pre-defined list of image positions for a menubar item
///
/// The constants defined are as follows:
///  * none          - don't show the image
///  * imageOnly     - only show the image, not the title
///  * imageLeading  - show the image before the title
///  * imageTrailing - show the image after the title
///  * imageLeft     - show the image to the left of the title
///  * imageRight    - show the image to the right of the title
///  * imageBelow    - show the image below the title
///  * imageAbove    - show the image above the title
///  * imageOverlaps - show the image on top of the title
private func pushImagePositionsTable(_ L: OpaquePointer!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.noImage.rawValue));       lua_setfield(L, -2, "none")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageOnly.rawValue));     lua_setfield(L, -2, "imageOnly")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageLeading.rawValue));  lua_setfield(L, -2, "imageLeading")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageTrailing.rawValue)); lua_setfield(L, -2, "imageTrailing")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageLeft.rawValue));     lua_setfield(L, -2, "imageLeft")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageRight.rawValue));    lua_setfield(L, -2, "imageRight")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageBelow.rawValue));    lua_setfield(L, -2, "imageBelow")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageAbove.rawValue));    lua_setfield(L, -2, "imageAbove")
    lua_pushinteger(L, lua_Integer(NSControl.ImagePosition.imageOverlaps.rawValue)); lua_setfield(L, -2, "imageOverlaps")
    return 1
}

private func menubar_setup() {
    if dynamicMenuDelegates == nil {
        dynamicMenuDelegates = NSMutableArray()
    }
}

private func menubar_gc(_ L: OpaquePointer!) -> Int32 {
    dynamicMenuDelegates?.removeAllObjects()
    dynamicMenuDelegates = nil
    return 0
}

private func menubaritem_gc(_ L: OpaquePointer!) -> Int32 {
    lua_pushcfunction(L, menubar_delete)
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)
    return 0
}

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let menuBarItem = get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    let title = statusItem.button?.title ?? ""

    lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
    return 1
}

// MARK: - luaL_Reg tables

private var menubarlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: menubarNew),
    luaL_Reg(name: nil,           func: nil),
]

private var menubar_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("setTitle"),          func: menubarSetTitle),
    luaL_Reg(name: strdup("_setIcon"),          func: menubarSetIcon),
    luaL_Reg(name: strdup("title"),             func: menubarGetTitle),
    luaL_Reg(name: strdup("icon"),              func: menubarGetIcon),
    luaL_Reg(name: strdup("setTooltip"),        func: menubarSetTooltip),
    luaL_Reg(name: strdup("setClickCallback"),  func: menubarSetClickCallback),
    luaL_Reg(name: strdup("setMenu"),           func: menubarSetMenu),
    luaL_Reg(name: strdup("popupMenu"),         func: menubar_render),
    luaL_Reg(name: strdup("removeFromMenuBar"), func: menubar_removeFromMenuBar),
    luaL_Reg(name: strdup("returnToMenuBar"),   func: menubar_returnToMenuBar),
    luaL_Reg(name: strdup("delete"),            func: menubar_delete),
    luaL_Reg(name: strdup("stateImageSize"),    func: menubarStateImageSize),
    luaL_Reg(name: strdup("_frame"),            func: menubarFrame),
    luaL_Reg(name: strdup("imagePosition"),     func: menubarImagePosition),
    luaL_Reg(name: strdup("isInMenubar"),       func: menubar_isInMenubar),
    luaL_Reg(name: strdup("isInMenuBar"),       func: menubar_isInMenubar),
    luaL_Reg(name: strdup("autosaveName"),      func: menubar_autosaveName),

    luaL_Reg(name: strdup("__tostring"),        func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"),              func: menubaritem_gc),
    luaL_Reg(name: nil,                         func: nil),
]

private var menubar_gclib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: menubar_gc),
    luaL_Reg(name: nil,            func: nil),
]

@_cdecl("luaopen_hs_libmenubar")
func luaopen_hs_libmenubar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!

    menubar_setup()

    refTable = skin.registerLibrary(withObject: USERDATA_TAG, functions: &menubarlib,
                                    metaFunctions: &menubar_gclib, objectFunctions: &menubar_metalib)

    pushImagePositionsTable(L); lua_setfield(L, -2, "imagePositions")

    return 1
}
