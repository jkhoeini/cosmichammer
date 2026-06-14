import Cocoa
import CLua
import Lua
import Carbon
import os.log

// MARK: - Callback Objects

@objc class HSMenubarCallbackObject: NSObject {
    var fn: LuaValue?
    var item: LuaValue?
    var generation: UInt64 = 0

    func callback_runner() {
        guard lua_isStateGenerationValid(generation) else { return }
        let L = lua_getCurrentState()!

        guard let fnRef = fn else { return }

        var fn_result: Bool

        let event = NSApp.currentEvent

        fnRef.push(onto: L)

        if let event = event {
            let theFlags = event.modifierFlags
            let isCommandKey = theFlags.contains(.command)
            let isShiftKey   = theFlags.contains(.shift)
            let isOptKey     = theFlags.contains(.option)
            let isCtrlKey    = theFlags.contains(.control)
            let isFnKey      = theFlags.contains(.function)

            lua_newtable(L)

            L.push(isCommandKey)
            lua_setfield(L, -2, "cmd")

            L.push(isShiftKey)
            lua_setfield(L, -2, "shift")

            L.push(isOptKey)
            lua_setfield(L, -2, "alt")

            L.push(isCtrlKey)
            lua_setfield(L, -2, "ctrl")

            L.push(isFnKey)
            lua_setfield(L, -2, "fn")

            if let itemRef = item {
                itemRef.push(onto: L)
            } else {
                lua_pushnil(L)
            }

            fn_result = lua_pcall(L, 2, 1, 0) == LUA_OK
        } else {
            fn_result = lua_pcall(L, 0, 1, 0) == LUA_OK
        }

        if !fn_result {
            let errorMsg = String(cString: lua_tostring(L, -1)!)
            os_log(.error, "%{public}s", "hs.menubar:setClickCallback() callback error: \(errorMsg)")
            return
        }
    }
}

// MARK: - Menubar item struct

struct menubaritem_t {
    var menuBarItemObject: UnsafeMutableRawPointer?
    var click_callback: UnsafeMutableRawPointer?
    var removed: Bool
    var stateBoxImageSize: NSSize
}

// Delegate objects
var mb_dynamicMenuDelegates: NSMutableArray!

@objc class HSMenubarItemClickDelegate: HSMenubarCallbackObject {
    @objc func click(_ sender: Any?) {
        let L = lua_getCurrentState()!
        // Issue #909 -- if the callback causes the menu to be replaced, we crash if this delegate
        // disappears from beneath us... this keeps it from being collected before the callback is done.
        var myDelegate: NSObject? = nil
        if let menuItem = sender as? NSMenuItem {
            myDelegate = menuItem.representedObject as? NSObject
        }
        callback_runner()
        lua_pop(L, 1)
        myDelegate = nil // NOTE: DO NOT USE `self` AFTER THIS POINT
    }
}

@objc class HSMenubarItemMenuDelegate: HSMenubarCallbackObject, NSMenuDelegate {
    var stateBoxImageSize: NSSize = .zero

    func menuNeedsUpdate(_ menu: NSMenu) {
        let L = lua_getCurrentState()!
        callback_runner()

        if lua_type(L, lua_gettop(L)) == LUA_TTABLE {
            mb_erase_menu_items(L, menu)
            mb_parse_table(L, lua_gettop(L), menu, stateBoxImageSize)
        } else {
            os_log(.error, "%{public}s", "hs.menubar:setMenu() callback must return a valid table")
        }
        lua_pop(L, 1)
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
    lua_pushnil(L)
    while lua_next(L, idx) != 0 {
        if lua_type(L, -1) != LUA_TTABLE {
            os_log(.debug, "%{public}s", "Error: table entry is not a menu item table: \(String(cString: lua_typename(L, lua_type(L, -1))))")
            lua_pop(L, 1)
            continue
        }

        // MARK: title key
        let titleType = lua_getfield(L, -1, "title")

        if !lua_isstring(L, -1) && luaL_testudata(L, -1, "hs.styledtext") == nil {
            os_log(.debug, "%{public}s", "Error: malformed menu table entry. Instead of a title string, we found: \(String(cString: lua_typename(L, lua_type(L, -1))))")
            lua_pop(L, 2)
            continue
        }

        let aTitle: NSAttributedString
        if let styledText = toNSAttributedString(L, at: -1) {
            aTitle = styledText
        } else if lua_isstring(L, -1) {
            aTitle = NSAttributedString(string: String(cString: lua_tostring(L, -1)!))
        } else {
            aTitle = NSAttributedString(string: "")
        }
        let title = aTitle.string

        lua_pop(L, 1)

        if title == "-" {
            menu.addItem(.separator())
        } else {
            let menuTitle = title
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
                    os_log(.error, "%{public}s", "hs.menubar menu recursion depth exceeded.")
                }
            }
            lua_pop(L, 1)

            // MARK: fn key
            lua_getfield(L, -1, "fn")
            if lua_isfunction(L, -1) {
                let delegate = HSMenubarItemClickDelegate()
                delegate.fn = L.ref(index: -1)
                delegate.item = L.ref(index: -2)
                delegate.generation = lua_currentStateGeneration()
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
            if let state = lua_tovalue(L, at: -1) as? String {
                if state == "on"    { menuItem.state = .on }
                if state == "off"   { menuItem.state = .off }
                if state == "mixed" { menuItem.state = .mixed }
            }
            lua_pop(L, 1)

            // MARK: tooltip key
            lua_getfield(L, -1, "tooltip")
            if lua_isstring(L, -1) {
                menuItem.toolTip = lua_tovalue(L, at: -1) as? String
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
            if let image = toNSImage(L, at: -1) {
                menuItem.image = image.copy() as? NSImage
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "onStateImage")
            if let image = toNSImage(L, at: -1) {
                let imageCopy = image.copy() as! NSImage
                imageCopy.size = mb_proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                menuItem.onStateImage = imageCopy
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "offStateImage")
            if let image = toNSImage(L, at: -1) {
                let imageCopy = image.copy() as! NSImage
                imageCopy.size = mb_proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                menuItem.offStateImage = imageCopy
            }
            lua_pop(L, 1)

            lua_getfield(L, -1, "mixedStateImage")
            if let image = toNSImage(L, at: -1) {
                let imageCopy = image.copy() as! NSImage
                imageCopy.size = mb_proportionallyScaleStateImageSize(imageCopy, stateBoxImageSize)
                menuItem.mixedStateImage = imageCopy
            }
            lua_pop(L, 1)

            // MARK: shortcut key
            lua_getfield(L, -1, "shortcut")
            if lua_isstring(L, -1) {
                let shortcutKey = lua_tovalue(L, at: -1) as! String
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

    for menuItem in menu.items {
        if let target = menuItem.representedObject as? HSMenubarItemClickDelegate {
            target.fn = nil
            target.item = nil
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

    if let delegate = menu.delegate as? HSMenubarItemMenuDelegate {
        delegate.fn = nil
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
    L.push(Double(rect.origin.x));    lua_setfield(L, -2, "x")
    L.push(Double(rect.origin.y));    lua_setfield(L, -2, "y")
    L.push(Double(rect.size.width));  lua_setfield(L, -2, "w")
    L.push(Double(rect.size.height)); lua_setfield(L, -2, "h")
}

