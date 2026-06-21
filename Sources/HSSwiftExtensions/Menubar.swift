import Cocoa
import CLua
import Lua
import Carbon
import os.log
import HSDSTCore

// MARK: - Definitions

let mb_USERDATA_TAG = "hs.menubar"

func mb_get_item_arg(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<menubaritem_t> {
    return luaL_checkudata(L, idx, mb_USERDATA_TAG)!.assumingMemoryBound(to: menubaritem_t.self)
}

// Adds undocumented "appearance" argument to "popUpMenuPositioningItem"
@objc protocol NSMenuMISSINGOrder {
    @objc func popUpMenuPositioningItem(_ item: Any?, atLocation location: CGPoint, in view: Any?, appearance: Any?) -> Bool
}

// Callbacks + Helpers -> MenubarHelpers.swift

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
func menubarNew(_ L: LuaState) throws -> CInt {

    let statusBar = NSStatusBar.system
    var statusItem: NSStatusItem

    if lua_isboolean(L, 1) && lua_toboolean(L, 1) == 0 {
        statusItem = NSStatusItem()
    } else {
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    }

    if lua_isstring(L, 2) {
        let autosaveName = lua_tovalue(L, at: 2) as! String

        let preferredPositionString = "NSStatusItem Preferred Position"
        var key = "HS\(preferredPositionString) \(autosaveName)"
        let autosaveValue = environmentGet(L).settings.object(forKey: key) as? NSNumber

        key = "\(preferredPositionString) \(autosaveName)"
        environmentGet(L).settings.set(autosaveValue, forKey: key)

        statusItem.autosaveName = NSStatusItem.AutosaveName(autosaveName)
    }

    statusItem.button?.imagePosition = .imageLeading
    let menuBarItem = lua_newuserdata(L, MemoryLayout<menubaritem_t>.size)!.assumingMemoryBound(to: menubaritem_t.self)
    memset(menuBarItem, 0, MemoryLayout<menubaritem_t>.size)

    menuBarItem.pointee.menuBarItemObject = Unmanaged.passRetained(statusItem).toOpaque()
    menuBarItem.pointee.click_callback = nil
    menuBarItem.pointee.removed = false

    let defaultFromFont = NSFont.menuFont(ofSize: 0).pointSize
    menuBarItem.pointee.stateBoxImageSize = NSSize(width: defaultFromFont, height: defaultFromFont)

    luaL_getmetatable(L, mb_USERDATA_TAG)
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
func menubar_autosaveName(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let menuItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if lua_gettop(L) == 2 {
        let autosaveName = lua_tovalue(L, at: 2) as! String

        let preferredPositionString = "NSStatusItem Preferred Position"
        var key = "HS\(preferredPositionString) \(autosaveName)"
        let autosaveValue = environmentGet(L).settings.object(forKey: key) as? NSNumber

        key = "\(preferredPositionString) \(autosaveName)"
        environmentGet(L).settings.set(autosaveValue, forKey: key)

        menuItem.autosaveName = NSStatusItem.AutosaveName(autosaveName)

        lua_settop(L, 1)
    } else {
        lua_pushany(L, menuItem.autosaveName as NSString?)
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
func menubarImagePosition(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let menuItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    let button = menuItem.button!

    if lua_gettop(L) == 2 {
        button.imagePosition = NSControl.ImagePosition(rawValue: UInt(lua_tointegerx(L, 2, nil)))!
        lua_settop(L, 1)
    } else {
        L.push(Int(button.imagePosition.rawValue))
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
func menubarSetTitle(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)

    var titleText: String? = nil
    var titleAText: NSAttributedString? = nil

    let argType = lua_type(L, 2)
    if argType == LUA_TSTRING || argType == LUA_TNUMBER {
        _ = luaL_checkstring(L, 2)
        titleText = lua_tovalue(L, at: 2) as? String
    } else if luaL_testudata(L, 2, "hs.styledtext") != nil || argType == LUA_TTABLE {
        titleAText = lua_toNSAttributedString(L, at: 2) as? NSAttributedString
    } else if !lua_isnoneornil(L, 2) {
        throw LuaCallError("expected string, styled-text object, or nil")
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
func menubarSetIcon(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    var iconImage: NSImage? = nil

    if lua_isnoneornil(L, 2) {
        iconImage = nil
    } else {
        iconImage = toNSImage(L, at: 2)

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
func menubarSetTooltip(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let toolTipText = lua_tovalue(L, at: 2) as! String
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
func menubarSetClickCallback(_ L: LuaState) throws -> CInt {

    let menuBarItem = mb_get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    // Remove any existing click callback
    if let callback = menuBarItem.pointee.click_callback {
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        let _ = Unmanaged<HSMenubarItemClickDelegate>.fromOpaque(callback).takeRetainedValue()
        menuBarItem.pointee.click_callback = nil
    }

    if lua_isfunction(L, 2) {
        let object = HSMenubarItemClickDelegate()
        object.fn = L.ref(index: 2)
        object.generation = lua_currentStateGeneration()
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
func menubarSetMenu(_ L: LuaState) throws -> CInt {

    let menuBarItem = mb_get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    var menu: NSMenu? = nil
    var delegate: HSMenubarItemMenuDelegate? = nil

    switch lua_type(L, 2) {
    case LUA_TTABLE:
        menu = mb_create_or_reuse_menu(L, statusItem, "Cosmic HammerMenuItemStaticMenu")
        menu?.autoenablesItems = false
        mb_parse_table(L, 2, menu!, menuBarItem.pointee.stateBoxImageSize)
        if menu?.numberOfItems == 0 {
            menu = nil
        }

    case LUA_TFUNCTION:
        menu = mb_create_or_reuse_menu(L, statusItem, "Cosmic HammerMenuItemDynamicMenu")
        menu?.autoenablesItems = false
        delegate = HSMenubarItemMenuDelegate()
        delegate!.stateBoxImageSize = menuBarItem.pointee.stateBoxImageSize
        delegate!.fn = L.ref(index: 2)
        delegate!.generation = lua_currentStateGeneration()
        mb_dynamicMenuDelegates?.add(delegate!)

    default:
        break
    }

    if menu == nil {
        mb_erase_all_menu_parts(L, statusItem)
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
func menubar_delete(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)

    // Guard against double-delete: :delete() sets menuBarItemObject = nil,
    // so __gc must not force-unwrap it again.
    guard let rawObj = menuBarItem.pointee.menuBarItemObject else { return 0 }

    let statusBar = NSStatusBar.system
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(rawObj).takeRetainedValue()

    // If an autosaveName exists, store the preferred position
    if let autosaveName = statusItem.autosaveName {
        let preferredPositionString = "NSStatusItem Preferred Position"
        var key = "\(preferredPositionString) \(autosaveName)"
        let autosaveValue = environmentGet(L).settings.object(forKey: key) as? NSNumber

        key = "HS\(preferredPositionString) \(autosaveName)"
        environmentGet(L).settings.set(autosaveValue, forKey: key)
    }

    // Remove any click callback directly (no lua_call — safe during GC)
    if let callback = menuBarItem.pointee.click_callback {
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        let _ = Unmanaged<HSMenubarItemClickDelegate>.fromOpaque(callback).takeRetainedValue()
        menuBarItem.pointee.click_callback = nil
    }

    // Remove all menu stuff associated with this item
    mb_erase_all_menu_parts(L, statusItem)

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
///  * This method is blocking. Cosmic Hammer will be unable to respond to any other activity while the pop-up menu is being displayed.
///  * `darkMode` uses an undocumented macOS API call, so may break in a future release.
func menubar_render(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
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
                let ifStyle = environmentGet(L).settings.string(forKey: "AppleInterfaceStyle")
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
        os_log(.error, "%{public}s", "hs.menubar:popupMenu() argument must be a valid hs.geometry.point table")
        lua_pushnil(L)
        return 1
    }

    guard let menu = menu else {
        if let callback = menuBarItem.pointee.click_callback {
            Unmanaged<HSMenubarItemClickDelegate>.fromOpaque(callback).takeUnretainedValue().click(nil)
        } else {
            os_log(.info, "%{public}s", "hs.menubar:popupMenu() Missing menu object")
        }
        lua_settop(L, 1)
        return 1
    }

    let env = environmentGet(L)
    let screenHeight = env.screen.allScreens().first?.frame.height ?? NSScreen.screens[0].frame.size.height
    menuPoint.y = screenHeight - menuPoint.y

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
func menubar_removeFromMenuBar(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)

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
func menubar_returnToMenuBar(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)

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
func menubar_isInMenubar(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    L.push(!menuBarItem.pointee.removed)
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
func menubarGetTitle(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        if let title = statusItem.button?.attributedTitle {
            NSAttributedString_toLua(L, obj: title)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushany(L, statusItem.button?.title as NSString?)
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
func menubarGetIcon(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if let theImage = statusItem.button?.image {
        if NSImage_tolua(L, theImage) == 0 {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }

    return 1
}

func menubarFrame(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()
    if let statusBarWindow = statusItem.value(forKey: "window") as? NSWindow {
        mb_geom_pushrect(L, statusBarWindow.frame)
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
func menubarStateImageSize(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(menuBarItem.pointee.menuBarItemObject!).takeUnretainedValue()

    if lua_gettop(L) == 1 {
        lua_pushNSSize(L, menuBarItem.pointee.stateBoxImageSize)
    } else {
        var newSize: NSSize
        if lua_type(L, 2) == LUA_TTABLE {
            newSize = lua_tableToSize(L, at: 2)
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
@discardableResult
func pushImagePositionsTable(_ L: LuaState) -> CInt {
    lua_newtable(L)
    L.push(Int(NSControl.ImagePosition.noImage.rawValue));       lua_setfield(L, -2, "none")
    L.push(Int(NSControl.ImagePosition.imageOnly.rawValue));     lua_setfield(L, -2, "imageOnly")
    L.push(Int(NSControl.ImagePosition.imageLeading.rawValue));  lua_setfield(L, -2, "imageLeading")
    L.push(Int(NSControl.ImagePosition.imageTrailing.rawValue)); lua_setfield(L, -2, "imageTrailing")
    L.push(Int(NSControl.ImagePosition.imageLeft.rawValue));     lua_setfield(L, -2, "imageLeft")
    L.push(Int(NSControl.ImagePosition.imageRight.rawValue));    lua_setfield(L, -2, "imageRight")
    L.push(Int(NSControl.ImagePosition.imageBelow.rawValue));    lua_setfield(L, -2, "imageBelow")
    L.push(Int(NSControl.ImagePosition.imageAbove.rawValue));    lua_setfield(L, -2, "imageAbove")
    L.push(Int(NSControl.ImagePosition.imageOverlaps.rawValue)); lua_setfield(L, -2, "imageOverlaps")
    return 1
}

func menubar_setup() {
    if mb_dynamicMenuDelegates == nil {
        mb_dynamicMenuDelegates = NSMutableArray()
    }
}

func menubar_gc(_ L: LuaState) throws -> CInt {
    mb_dynamicMenuDelegates?.removeAllObjects()
    mb_dynamicMenuDelegates = nil
    return 0
}

func menubaritem_gc(_ L: LuaState) throws -> CInt {
    // Call menubar_delete directly as a Swift function — never via lua_call,
    // which corrupts the allocator when invoked from within a GC finalizer
    // during lua_close().
    return try menubar_delete(L)
}

func mb_userdata_tostring(_ L: LuaState) throws -> CInt {
    let menuBarItem = mb_get_item_arg(L, 1)
    guard let rawObj = menuBarItem.pointee.menuBarItemObject else {
        L.push("\(mb_USERDATA_TAG): (deleted) (\(String(describing: lua_topointer(L, 1)!)))")
        return 1
    }
    let statusItem = Unmanaged<NSStatusItem>.fromOpaque(rawObj).takeUnretainedValue()
    let title = statusItem.button?.title ?? ""

    L.push("\(mb_USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    return 1
}


@_cdecl("luaopen_hs_libmenubar")
func luaopen_hs_libmenubar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        menubar_setup()

        // Register userdata metatable
        luaL_newmetatable(L, mb_USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(menubarSetTitle);            lua_setfield(L, -2, "setTitle")
        L.push(menubarSetIcon);             lua_setfield(L, -2, "_setIcon")
        L.push(menubarGetTitle);            lua_setfield(L, -2, "title")
        L.push(menubarGetIcon);             lua_setfield(L, -2, "icon")
        L.push(menubarSetTooltip);          lua_setfield(L, -2, "setTooltip")
        L.push(menubarSetClickCallback);    lua_setfield(L, -2, "setClickCallback")
        L.push(menubarSetMenu);             lua_setfield(L, -2, "setMenu")
        L.push(menubar_render);             lua_setfield(L, -2, "popupMenu")
        L.push(menubar_removeFromMenuBar);  lua_setfield(L, -2, "removeFromMenuBar")
        L.push(menubar_returnToMenuBar);    lua_setfield(L, -2, "returnToMenuBar")
        L.push(menubar_delete);             lua_setfield(L, -2, "delete")
        L.push(menubarStateImageSize);      lua_setfield(L, -2, "stateImageSize")
        L.push(menubarFrame);               lua_setfield(L, -2, "_frame")
        L.push(menubarImagePosition);       lua_setfield(L, -2, "imagePosition")
        L.push(menubar_isInMenubar);        lua_setfield(L, -2, "isInMenubar")
        L.push(menubar_isInMenubar);        lua_setfield(L, -2, "isInMenuBar")
        L.push(menubar_autosaveName);       lua_setfield(L, -2, "autosaveName")
        L.push(mb_userdata_tostring);       lua_setfield(L, -2, "__tostring")
        L.push(menubaritem_gc);             lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(menubarNew);                 lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(menubar_gc);                 lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        pushImagePositionsTable(L); lua_setfield(L, -2, "imagePositions")
    }
}
