import Cocoa
import Carbon
import LuaSkin

// MARK: - Callback Objects

@objc class HSMenubarCallbackObject: NSObject {
    var fn: Int32 = LUA_NOREF
    var item: Int32 = LUA_NOREF

    func callback_runner() {
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!

        var fn_result: Bool

        let event = NSApp.currentEvent

        skin.pushLuaRef(mb_refTable, ref: fn)

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

            skin.pushLuaRef(mb_refTable, ref: item)

            fn_result = skin.protectedCallAndTraceback(2, nresults: 1)
        } else {
            fn_result = skin.protectedCallAndTraceback(0, nresults: 1)
        }

        if !fn_result {
            let errorMsg = String(cString: lua_tostring(L, -1)!)
            skin.logError("hs.menubar:setClickCallback() callback error: \(errorMsg)")
            return
        }
    }
}

// MARK: - Menubar item struct

struct menubaritem_t {
    var menuBarItemObject: UnsafeMutableRawPointer?
    var click_callback: UnsafeMutableRawPointer?
    var click_fn: Int32
    var removed: Bool
    var stateBoxImageSize: NSSize
}

// Delegate objects
var mb_dynamicMenuDelegates: NSMutableArray!

@objc class HSMenubarItemClickDelegate: HSMenubarCallbackObject {
    @objc func click(_ sender: Any?) {
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        // Issue #909 -- if the callback causes the menu to be replaced, we crash if this delegate
        // disappears from beneath us... this keeps it from being collected before the callback is done.
        var myDelegate: NSObject? = nil
        if let menuItem = sender as? NSMenuItem {
            myDelegate = menuItem.representedObject as? NSObject
        }
        callback_runner()
        lua_pop(skin.l, 1)
        _lua_stackguard_exit(skin.l)
        myDelegate = nil // NOTE: DO NOT USE `self` AFTER THIS POINT
    }
}

@objc class HSMenubarItemMenuDelegate: HSMenubarCallbackObject, NSMenuDelegate {
    var stateBoxImageSize: NSSize = .zero

    func menuNeedsUpdate(_ menu: NSMenu) {
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        callback_runner()

        if lua_type(skin.l, lua_gettop(skin.l)) == LUA_TTABLE {
            mb_erase_menu_items(skin.l, menu)
            mb_parse_table(skin.l, lua_gettop(skin.l), menu, stateBoxImageSize)
        } else {
            skin.logError("hs.menubar:setMenu() callback must return a valid table")
        }
        lua_pop(skin.l, 1)
        _lua_stackguard_exit(skin.l)
    }
}

// MARK: - Helper functions

func mb_proportionallyScaleStateImageSize(_ theImage: NSImage, _ stateBoxImageSize: NSSize) -> NSSize {
    let sourceSize = theImage.size
    let ratio = fmin(stateBoxImageSize.height / sourceSize.height, stateBoxImageSize.width / sourceSize.width)
    return NSSize(width: sourceSize.width * ratio, height: sourceSize.height * ratio)
}

// Helper function to parse a Lua table and turn it into an NSMenu hierarchy
func mb_parse_table(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ menu: NSMenu, _ stateBoxImageSize: NSSize) {
    let skin = LuaSkin.skin(with: L)

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

        let aTitle = skin.luaObject(at:-1, toClass: "NSAttributedString") as! NSAttributedString
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
                let subMenu = NSMenu(title: "Cosmic HammerSubMenu")
                subMenu.autoenablesItems = false
                if lua_checkstack(L, 20) != 0 {
                    mb_parse_table(L, lua_gettop(L), subMenu, stateBoxImageSize)
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
                delegate.fn = skin.luaRef(mb_refTable)
                delegate.item = skin.luaRef(mb_refTable, at: -2)
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
            if let state = skin.toNSObject(at:-1) as? String {
                if state == "on"    { menuItem.state = .on }
                if state == "off"   { menuItem.state = .off }
                if state == "mixed" { menuItem.state = .mixed }
            }
            lua_pop(L, 1)

            // MARK: tooltip key
            lua_getfield(L, -1, "tooltip")
            if lua_isstring(L, -1) {
                menuItem.toolTip = skin.toNSObject(at:-1) as? String
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
                if let image = skin.luaObject(at:-1, toClass: "NSImage") as? NSImage {
                    menuItem.image = image.copy() as? NSImage
                }
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "onStateImage")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObject(at:-1, toClass: "NSImage") as? NSImage {
                    let imageCopy = image.copy() as! NSImage
                    imageCopy.size = mb_proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                    menuItem.onStateImage = imageCopy
                }
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "offStateImage")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObject(at:-1, toClass: "NSImage") as? NSImage {
                    let imageCopy = image.copy() as! NSImage
                    imageCopy.size = mb_proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                    menuItem.offStateImage = imageCopy
                }
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "mixedStateImage")
            if luaL_testudata(L, -1, "hs.image") != nil {
                if let image = skin.luaObject(at:-1, toClass: "NSImage") as? NSImage {
                    let imageCopy = image.copy() as! NSImage
                    imageCopy.size = mb_proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                    menuItem.mixedStateImage = imageCopy
                }
            }
            lua_pop(L, 1)

            // MARK: shortcut key
            lua_getfield(L, -1, "shortcut")
            if lua_isstring(L, -1) {
                let shortcutKey = skin.toNSObject(at:-1) as! String
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
func mb_erase_menu_items(_ L: UnsafeMutablePointer<lua_State>!, _ menu: NSMenu) {
    let skin = LuaSkin.skin(with: L)

    for menuItem in menu.items {
        if let target = menuItem.representedObject as? HSMenubarItemClickDelegate {
            target.fn = skin.luaUnref(mb_refTable, ref: target.fn)
            target.item = skin.luaUnref(mb_refTable, ref: target.item)
            menuItem.target = nil
            menuItem.action = nil
            menuItem.representedObject = nil
        }
        if menuItem.hasSubmenu {
            mb_erase_menu_items(L, menuItem.submenu!)
            menuItem.submenu = nil
        }
        menu.removeItem(menuItem)
    }
}

// Remove and clean up a dynamic menu delegate
func mb_erase_menu_delegate(_ L: UnsafeMutablePointer<lua_State>!, _ menu: NSMenu) {
    let skin = LuaSkin.skin(with: L)

    if let delegate = menu.delegate as? HSMenubarItemMenuDelegate {
        delegate.fn = skin.luaUnref(mb_refTable, ref: delegate.fn)
        mb_dynamicMenuDelegates.remove(delegate)
        menu.delegate = nil
    }
}

// Remove any kind of menu on a menubar item
func mb_erase_all_menu_parts(_ L: UnsafeMutablePointer<lua_State>!, _ statusItem: NSStatusItem) {
    if let menu = statusItem.menu {
        mb_erase_menu_delegate(L, menu)
        mb_erase_menu_items(L, menu)
        statusItem.menu = nil
    }
}

// Prepare an existing menu on a menubar item for reuse or create a new menu
func mb_create_or_reuse_menu(_ L: UnsafeMutablePointer<lua_State>!, _ statusItem: NSStatusItem, _ menuTitle: String) -> NSMenu {
    if let menu = statusItem.menu {
        mb_erase_menu_delegate(L, menu)
        mb_erase_menu_items(L, menu)
        statusItem.menu = nil
        menu.title = menuTitle
        return menu
    }
    return NSMenu(title: menuTitle)
}

// Create and push a lua geometry rect
func mb_geom_pushrect(_ L: UnsafeMutablePointer<lua_State>!, _ rect: NSRect) {
    lua_newtable(L)
    lua_pushnumber(L, Double(rect.origin.x));    lua_setfield(L, -2, "x")
    lua_pushnumber(L, Double(rect.origin.y));    lua_setfield(L, -2, "y")
    lua_pushnumber(L, Double(rect.size.width));  lua_setfield(L, -2, "w")
    lua_pushnumber(L, Double(rect.size.height)); lua_setfield(L, -2, "h")
}

