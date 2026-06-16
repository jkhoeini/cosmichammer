import Cocoa
import CLua
import HSDSTCore
import Lua
import os.log

// MARK: - Module metadata

private let USERDATA_TAG = "hs.chooser"

private func get_objectFromUserdata<T: AnyObject>(_ type: T.Type, _ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: String) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return Unmanaged<T>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

// MARK: - Lua API - Constructors

/// hs.chooser.new(completionFn) -> hs.chooser object
/// Constructor
/// Creates a new chooser object
///
/// Parameters:
///  * completionFn - A function that will be called when the chooser is dismissed. It should accept one parameter, which will be nil if the user dismissed the chooser window, otherwise it will be a table containing whatever information you supplied for the item the user chose.
///
/// Returns:
///  * An `hs.chooser` object
///
/// Notes:
///  * As of macOS Sierra and later, if you want a `hs.chooser` object to appear above full-screen windows you must hide the Cosmic Hammer Dock icon first using: `hs.dockicon.hide()`
private let chooserNew: LuaClosure = { L in
    luaL_checktype(L, 1, LUA_TFUNCTION)
    let completionCb = L.ref(index: 1)
    let chooser = HSChooser(completionCallback: completionCb)
    _ = pushHSChooser(L, chooser)

    return 1
}

// MARK: - Lua API - Methods

/// hs.chooser:show([topLeftPoint]) -> hs.chooser object
/// Method
/// Displays the chooser
///
/// Parameters:
///  * An optional `hs.geometry` point object describing the absolute screen co-ordinates for the top left point of the chooser window. Defaults to centering the window on the primary screen
///
/// Returns:
///  * The hs.chooser object
private let chooserShow: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    if lua_type(L, 2) == LUA_TTABLE {
        let userTopLeft = lua_tableToPoint(L, at: 2)
        let primaryScreenHeight = environmentGet(L).screen.allScreens().first.map { $0.frame.height } ?? 0.0
        let topLeft = NSPoint(x: userTopLeft.x,
                              y: primaryScreenHeight - userTopLeft.y)
        chooser.showAtPoint(topLeft)
    } else {
        chooser.show()
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:hide() -> hs.chooser object
/// Method
/// Hides the chooser
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.chooser` object
private let chooserHide: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser
    chooser.hide()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:isVisible() -> boolean
/// Method
/// Checks if the chooser is currently displayed
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the chooser is displayed on screen, false if not
private let chooserIsVisible: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser
    L.push(chooser.isVisible)
    return 1
}

/// hs.chooser:choices(choices) -> hs.chooser object
/// Method
/// Sets the choices for a chooser
///
/// Parameters:
///  * choices - Either a function to call when the list of choices is needed, or nil to remove any existing choices/callback, or a table containing static choices.
///
/// Returns:
///  * The `hs.chooser` object
///
/// Notes:
///  * The table of choices (be it provided statically, or returned by the callback) must contain at least the following keys for each choice:
///   * text - A string or hs.styledtext object that will be shown as the main text of the choice
///  * Each choice may also optionally contain the following keys:
///   * subText - A string or hs.styledtext object that will be shown underneath the main text of the choice
///   * image - An `hs.image` image object that will be displayed next to the choice
///   * valid - A boolean that defaults to `true`, if set to `false` selecting the choice will invoke the `invalidCallback` method instead of dismissing the chooser
///  * Any other keys/values in each choice table will be retained by the chooser and returned to the completion callback when a choice is made. This is useful for storing UUIDs or other non-user-facing information, however, it is important to note that you should not store userdata objects in the table - it is run through internal conversion functions, so only basic Lua types should be stored.
///  * If a function is given, it will be called once, when the chooser window is displayed. The results are then cached until this method is called again, or `hs.chooser:refreshChoicesCallback()` is called.
///  * If you're using a hs.styledtext object for text or subText choices, make sure you specify a color, otherwise your text could appear transparent depending on the bgDark setting.
private let chooserSetChoices: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.choicesCallback = nil
    chooser.clearChoices()

    switch lua_type(L, 2) {
    case LUA_TNIL:
        break

    case LUA_TFUNCTION:
        chooser.choicesCallback = L.ref(index: 2)

    case LUA_TTABLE:
        chooser.currentStaticChoices = lua_toChooserChoices(L, at: 2)

        var staticChoicesTypeCheckPass = false
        if let arr = chooser.currentStaticChoices as? [Any] {
            staticChoicesTypeCheckPass = true
            for element in arr {
                if !(element is NSDictionary) {
                    staticChoicesTypeCheckPass = false
                    break
                }
            }
        }

        if !staticChoicesTypeCheckPass {
            os_log(.error, "%{public}s", "hs.chooser:choices() table could not be parsed correctly.")
            chooser.currentStaticChoices = nil
        }

    default:
        os_log(.debug, "%{public}s", "ERROR: Unknown type passed to hs.chooser:choices(). This should not be possible")
    }

    chooser.updateChoices()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:hideCallback([fn]) -> hs.chooser object
/// Method
/// Sets/clears a callback for when the chooser window is hidden
///
/// Parameters:
///  * fn - An optional function that will be called when the chooser window is hidden. If this parameter is omitted, the existing callback will be removed.
///
/// Returns:
///  * The hs.chooser object
///
/// Notes:
///  * This callback is called *after* the chooser is hidden.
///  * This callback is called *after* hs.chooser.globalCallback.
private let chooserHideCallback: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.hideCallback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        chooser.hideCallback = L.ref(index: 2)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:showCallback([fn]) -> hs.chooser object
/// Method
/// Sets/clears a callback for when the chooser window is shown
///
/// Parameters:
///  * fn - An optional function that will be called when the chooser window is shown. If this parameter is omitted, the existing callback will be removed.
///
/// Returns:
///  * The hs.chooser object
///
/// Notes:
///  * This callback is called *after* the chooser is shown. To execute code just before it's shown (and/or after it's removed) see `hs.chooser.globalCallback`
private let chooserShowCallback: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.showCallback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        chooser.showCallback = L.ref(index: 2)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:refreshChoicesCallback([reload]) -> hs.chooser object
/// Method
/// Refreshes the choices data from a callback
///
/// Parameters:
///  * reload - An optional parameter that reloads the chooser results to take into account the current query string (defaults to `false`)
///
/// Returns:
///  * The `hs.chooser` object
///
/// Notes:
///  * This method will do nothing if you have not set a function with `hs.chooser:choices()`
private let chooserRefreshChoicesCallback: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    let reload = lua_toboolean(L, 2) != 0

    if chooser.choicesCallback != nil {
        chooser.clearChoices()
        _ = chooser.getChoices()
        chooser.updateChoices()
        if reload {
            chooser.controlTextDidChange(Notification(name: Notification.Name("Unused"), object: nil))
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:query([queryString]) -> hs.chooser object or string
/// Method
/// Sets/gets the search string
///
/// Parameters:
///  * queryString - An optional string to search for, or an explicit nil to clear the query. If omitted, the current contents of the search box are returned
///
/// Returns:
///  * The `hs.chooser` object or a string
///
/// Notes:
///  * You can provide an explicit nil or empty string to clear the current query string.
private let chooserSetQuery: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    if lua_gettop(L) == 1 {
        lua_pushany(L, chooser.queryField.stringValue as NSString)
    } else {
        switch lua_type(L, 2) {
        case LUA_TSTRING:
            chooser.queryField.stringValue = (lua_tovalue(L, at: 2) as? String) ?? ""
            lua_pushvalue(L, 1)

        case LUA_TNIL:
            chooser.queryField.stringValue = ""
            lua_pushvalue(L, 1)

        default:
            os_log(.error, "ERROR: Unknown type passed to hs.chooser:query(). This should not be possible")
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.chooser:placeholderText([placeholderText]) -> hs.chooser object or string
/// Method
/// Sets/gets placeholder text that is shown in the query text field when no other text is present
///
/// Parameters:
///  * placeholderText - An optional string for placeholder text. If this parameter is omitted, the existing placeholder text will be returned.
///
/// Returns:
///  * The hs.chooser object, or the existing placeholder text
private let chooserPlaceholder: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    if lua_gettop(L) == 1 {
        let placeholderString = chooser.queryField.placeholderString as NSString?
        lua_pushany(L, placeholderString)
    } else {
        chooser.queryField.placeholderString = lua_tovalue(L, at: 2) as? String
        lua_settop(L, 1)
    }
    return 1
}

/// hs.chooser:queryChangedCallback([fn]) -> hs.chooser object
/// Method
/// Sets/clears a callback for when the search query changes
///
/// Parameters:
///  * fn - An optional function that will be called whenever the search query changes. If this parameter is omitted, the existing callback will be removed.
///
/// Returns:
///  * The hs.chooser object
///
/// Notes:
///  * As the user is typing, the callback function will be called for every keypress. You may wish to do filtering on each call, or you may wish to use a delayed `hs.timer` object to only react when they have finished typing.
///  * The callback function should accept a single argument:
///   * A string containing the new search query
private let chooserQueryCallback: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.queryChangedCallback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        chooser.queryChangedCallback = L.ref(index: 2)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:rightClickCallback([fn]) -> hs.chooser object
/// Method
/// Sets/clears a callback for right clicking on choices
///
/// Parameters:
///  * fn - An optional function that will be called whenever the user right clicks on a choice. If this parameter is omitted, the existing callback will be removed.
///
/// Returns:
///  * The `hs.chooser` object
///
/// Notes:
///   * The callback may accept one argument, the row the right click occurred in or 0 if there is currently no selectable row where the right click occurred. To determine the location of the mouse pointer at the right click, see `hs.mouse`.
///   * To display a context menu, see `hs.menubar`, specifically the `:popupMenu()` method
private let chooserRightClickCallback: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.rightClickCallback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        chooser.rightClickCallback = L.ref(index: 2)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:invalidCallback([fn]) -> hs.chooser object
/// Method
/// Sets/clears a callback for invalid choices
///
/// Parameters:
///  * fn - An optional function that will be called whenever the user select an choice set as invalid. If this parameter is omitted, the existing callback will be removed.
///
/// Returns:
///  * The `hs.chooser` object
///
/// Notes:
///   * The callback may accept one argument, it will be a table containing whatever information you supplied for the item the user chose.
///   * To display a context menu, see `hs.menubar`, specifically the `:popupMenu()` method
private let chooserInvalidCallback: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.invalidCallback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        chooser.invalidCallback = L.ref(index: 2)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:delete()
/// Method
/// Deletes a chooser
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private let chooserDelete: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = get_objectFromUserdata(HSChooser.self, L, 1, USERDATA_TAG)
    chooser.hide()
    chooser.teardown()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:fgColor(color) -> hs.chooser object
/// Method
/// Sets the foreground color of the chooser
///
/// Parameters:
///  * color - An optional table containing a color specification (see `hs.drawing.color`), or nil to restore the default color. If this parameter is omitted, the existing color will be returned
///
/// Returns:
///  * The `hs.chooser` object or a color table
private let chooserSetFgColor: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TTABLE:
        chooser.fgColor = tableToNSColor(L, at: 2)
        lua_pushvalue(L, 1)

    case LUA_TNIL:
        chooser.fgColor = nil
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        pushNSColorOrNil(L, chooser.fgColor)

    default:
        os_log(.error, "ERROR: Unknown type in hs.chooser:fgColor(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:subTextColor(color) -> hs.chooser object or hs.color object
/// Method
/// Sets the sub-text color of the chooser
///
/// Parameters:
///  * color - An optional table containing a color specification (see `hs.drawing.color`), or nil to restore the default color. If this parameter is omitted, the existing color will be returned
///
/// Returns:
///  * The `hs.chooser` object or a color table
private let chooserSetSubTextColor: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TTABLE:
        chooser.subTextColor = tableToNSColor(L, at: 2)
        lua_pushvalue(L, 1)

    case LUA_TNIL:
        chooser.subTextColor = nil
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        pushNSColorOrNil(L, chooser.subTextColor)

    default:
        os_log(.error, "ERROR: Unknown type in hs.chooser:subTextColor(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:bgDark([beDark]) -> hs.chooser object or boolean
/// Method
/// Sets the background of the chooser between light and dark
///
/// Parameters:
///  * beDark - A optional boolean, true to be dark, false to be light. If this parameter is omitted, the current setting will be returned
///
/// Returns:
///  * The `hs.chooser` object or a boolean, true if the window is dark, false if it is light
///
/// Notes:
///  * The text colors will not automatically change when you toggle the darkness of the chooser window, you should also set appropriate colors with `hs.chooser:fgColor()` and `hs.chooser:subTextColor()`
private let chooserSetBgDark: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TNIL:
        chooser.setBgLightDark(Notification(name: Notification.Name("UNUSED"), object: nil))
        lua_pushvalue(L, 1)

    case LUA_TBOOLEAN:
        let beDark = lua_toboolean(L, 2) != 0
        chooser.setBgLightDark(Notification(name: Notification.Name("UNUSED"), object: NSNumber(value: beDark)))
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        L.push(chooser.isBgLightDark())

    default:
        os_log(.error, "ERROR: Unknown type in hs.chooser:bgDark(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:enableDefaultForQuery([]) -> hs.chooser object or boolean
/// Method
/// Gets/Sets whether the chooser should run the callback on a query when it does not match any on the list
///
/// Parameters:
///  * enableDefaultForQuery - An optional boolean, true to return query string, false to not. If this parameter is omitted, the current configuration value will be returned
///
/// Returns:
///  * the `hs.chooser` object if a value was set, or a boolean if no parameter was passed
///
/// Notes:
///  * This should be used before a chooser has been displayed
private let chooserSetEnableDefaultForQuery: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TBOOLEAN:
        chooser.enableDefaultForQuery = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        L.push(chooser.enableDefaultForQuery)
        return 1

    default:
        os_log(.error, "ERROR: Unknown type passed to hs.chooser:enableDefaultForQuery(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:searchSubText([searchSubText]) -> hs.chooser object or boolean
/// Method
/// Gets/Sets whether the chooser should search in the sub-text of each item
///
/// Parameters:
///  * searchSubText - An optional boolean, true to search sub-text, false to not search sub-text. If this parameter is omitted, the current configuration value will be returned
///
/// Returns:
///  * The `hs.chooser` object if a value was set, or a boolean if no parameter was passed
///
/// Notes:
///  * This should be used before a chooser has been displayed
private let chooserSetSearchSubText: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TBOOLEAN:
        chooser.searchSubText = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        L.push(chooser.searchSubText)
        return 1

    default:
        os_log(.error, "ERROR: Unknown type passed to hs.chooser:searchSubText(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:width([percent]) -> hs.chooser object or number
/// Method
/// Gets/Sets the width of the chooser
///
/// Parameters:
///  * percent - An optional number indicating the percentage of the width of the screen that the chooser should occupy. If this parameter is omitted, the current width will be returned
///
/// Returns:
///  * The `hs.chooser` object or a number
///
/// Notes:
///  * This should be used before a chooser has been displayed
private let chooserSetWidth: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TNUMBER:
        chooser.width = CGFloat(lua_tonumber(L, 2))
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        L.push(Double(chooser.width))

    default:
        os_log(.error, "ERROR: Unknown type passed to hs.chooser:width(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:rows([numRows]) -> hs.chooser object or number
/// Method
/// Gets/Sets the number of rows that will be shown
///
/// Parameters:
///  * numRows - An optional number of choices to show (i.e. the vertical height of the chooser window). If this parameter is omitted, the current value will be returned
///
/// Returns:
///  * The `hs.chooser` object or a number
private let chooserSetNumRows: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    switch lua_type(L, 2) {
    case LUA_TNUMBER:
        chooser.numRows = Int(lua_tointeger(L, 2))
        lua_pushvalue(L, 1)

    case LUA_TNONE:
        L.push(chooser.numRows)

    default:
        os_log(.error, "ERROR: Unknown type passed to hs.chooser:rows(). This should not be possible")
        lua_pushnil(L)
    }

    return 1
}

/// hs.chooser:selectedRow([row]) -> number
/// Method
/// Get or set the currently selected row
///
/// Parameters:
///  * `row` - an optional integer specifying the row to select.
///
/// Returns:
///  * If an argument is provided, returns the hs.chooser object; otherwise returns a number containing the row currently selected (i.e. the one highlighted in the UI)
private let chooserSelectedRow: LuaClosure = { L in

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    if lua_gettop(L) == 1 {
        let selectedRow = chooser.choicesTableView.selectedRow
        L.push(selectedRow + 1)
    } else {
        let maxRow = chooser.choicesTableView.numberOfRows - 1
        var newRow = Int(lua_tointeger(L, 2)) - 1
        newRow = max(0, min(newRow, maxRow))
        chooser.choicesTableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        chooser.choicesTableView.scrollRowToVisible(newRow)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.chooser:selectedRowContents([row]) -> table
/// Method
/// Returns the contents of the currently selected or specified row
///
/// Parameters:
///  * `row` - an optional integer specifying the specific row to return the contents of
///
/// Returns:
///  * a table containing whatever information was supplied for the row currently selected or an empty table if no row is selected or the specified row does not exist.
private let chooserSelectedRowContents: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)
    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    let selectedRow = (lua_gettop(L) == 1) ? chooser.choicesTableView.selectedRow : Int(lua_tointeger(L, 2) - 1)
    if selectedRow >= 0 && selectedRow < chooser.choicesTableView.numberOfRows {
        pushChooserChoice(L, chooser.getChoices()?[selectedRow])
    } else {
        lua_newtable(L)
    }
    return 1
}

/// hs.chooser:select([row]) -> hs.chooser object
/// Method
/// Closes the chooser by selecting the specified row, or the currently selected row if not given
///
/// Parameters:
///  * `row` - an optional integer specifying the row to select.
///
/// Returns:
///  * The `hs.chooser` object
private let chooserSelect: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    _ = try chooserSelectedRow(L)
    lua_pop(L, 1)

    chooser.queryDidPressEnter(nil)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.chooser:cancel() -> hs.chooser object
/// Method
/// Cancels the chooser
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.chooser` object
private let chooserCancel: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)
    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser

    chooser.cancel(nil)

    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

let pushHSChooser: @convention(c) (UnsafeMutablePointer<lua_State>?, Any?) -> Int32 = { L, obj in
    guard let chooser = obj as? HSChooser else { return 0 }
    chooser.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    valuePtr.storeBytes(of: Unmanaged.passRetained(chooser).toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private let toHSChooserFromLua: @convention(c) (UnsafeMutablePointer<lua_State>?, Int32) -> Any? = { L, idx in
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return get_objectFromUserdata(HSChooser.self, L, idx, USERDATA_TAG)
    } else {
        os_log(.error, "%{public}s", String(format: "expected %@ object, found %s", USERDATA_TAG,
                             lua_typename(L, lua_type(L, idx))))
    }
    return nil
}

private func pushNSColorOrNil(_ L: UnsafeMutablePointer<lua_State>!, _ color: NSColor?) {
    guard let color else {
        lua_pushnil(L)
        return
    }
    if !lua_pushNSColor(L, color) {
        lua_pushnil(L)
    }
}

func lua_toChooserChoiceValue(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> Any? {
    if lua_type(L, idx) == LUA_TUSERDATA {
        if let image = toNSImage(L, at: idx) { return image }
        if let styledText = toNSAttributedString(L, at: idx) { return styledText }
        return nil
    }
    return lua_tovalue(L, at: idx)
}

func lua_toChooserChoice(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSDictionary? {
    let absIdx = lua_absindex(L, idx)
    guard lua_type(L, absIdx) == LUA_TTABLE else { return nil }

    let choice = NSMutableDictionary()
    lua_pushnil(L)
    while lua_next(L, absIdx) != 0 {
        guard let key = lua_tovalue(L, at: -2) as? NSCopying,
              let value = lua_toChooserChoiceValue(L, at: -1) else {
            lua_pop(L, 2)
            return nil
        }
        choice.setObject(value, forKey: key)
        lua_pop(L, 1)
    }
    return choice
}

func lua_toChooserChoices(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSArray? {
    let absIdx = lua_absindex(L, idx)
    guard lua_type(L, absIdx) == LUA_TTABLE else { return nil }

    let choices = NSMutableArray()
    let count = Int(luaL_len(L, absIdx))
    if count == 0 { return choices }

    for i in 1...count {
        lua_rawgeti(L, absIdx, lua_Integer(i))
        guard let choice = lua_toChooserChoice(L, at: -1) else {
            lua_pop(L, 1)
            return nil
        }
        choices.add(choice)
        lua_pop(L, 1)
    }
    return choices
}

func pushChooserChoiceValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?) {
    switch value {
    case let image as NSImage:
        if NSImage_tolua(L, image) == 0 {
            lua_pushnil(L)
        }
    case let styledText as NSAttributedString:
        if NSAttributedString_toLua(L, obj: styledText) == 0 {
            lua_pushnil(L)
        }
    default:
        lua_pushany(L, value)
    }
}

func pushChooserChoice(_ L: UnsafeMutablePointer<lua_State>!, _ choice: Any?) {
    guard let choice = choice as? NSDictionary else {
        lua_pushany(L, choice)
        return
    }

    lua_newtable(L)
    for (key, value) in choice {
        lua_pushany(L, key)
        pushChooserChoiceValue(L, value)
        lua_settable(L, -3)
    }
}

// MARK: - Cosmic Hammer Infrastructure

private let userdata_tostring: LuaClosure = { L in
    let chooser: HSChooser = toHSChooserFromLua(L, 1) as! HSChooser
    lua_pushany(L, String(format: "%@: (%@)", USERDATA_TAG, chooser) as NSString)
    return 1
}

private let userdata_eq: LuaClosure = { L in
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let obj1 = toHSChooserFromLua(L, 1) as! HSChooser
        let obj2 = toHSChooserFromLua(L, 2) as! HSChooser
        L.push(obj1.isEqual(to: obj2))
    } else {
        L.push(false)
    }
    return 1
}

private let userdata_gc: LuaClosure = { L in
    luaL_checkudata(L, 1, USERDATA_TAG)

    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let rawPtr = ptr.load(as: UnsafeRawPointer.self)
    let chooser = Unmanaged<HSChooser>.fromOpaque(rawPtr).takeRetainedValue()

    chooser.selfRefCount -= 1
    if chooser.selfRefCount == 0 {
        chooser.teardown()
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

@_cdecl("luaopen_hs_libchooser")
public func luaopen_hs_libchooser(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(chooserShow)
        lua_setfield(L, -2, "show")
        L.push(chooserHide)
        lua_setfield(L, -2, "hide")
        L.push(chooserIsVisible)
        lua_setfield(L, -2, "isVisible")
        L.push(chooserSetChoices)
        lua_setfield(L, -2, "choices")
        L.push(chooserHideCallback)
        lua_setfield(L, -2, "hideCallback")
        L.push(chooserShowCallback)
        lua_setfield(L, -2, "showCallback")
        L.push(chooserQueryCallback)
        lua_setfield(L, -2, "queryChangedCallback")
        L.push(chooserSetQuery)
        lua_setfield(L, -2, "query")
        L.push(chooserDelete)
        lua_setfield(L, -2, "delete")
        L.push(chooserRefreshChoicesCallback)
        lua_setfield(L, -2, "refreshChoicesCallback")
        L.push(chooserRightClickCallback)
        lua_setfield(L, -2, "rightClickCallback")
        L.push(chooserInvalidCallback)
        lua_setfield(L, -2, "invalidCallback")
        L.push(chooserSelectedRow)
        lua_setfield(L, -2, "selectedRow")
        L.push(chooserSelectedRowContents)
        lua_setfield(L, -2, "selectedRowContents")
        L.push(chooserSelect)
        lua_setfield(L, -2, "select")
        L.push(chooserCancel)
        lua_setfield(L, -2, "cancel")
        L.push(chooserSetFgColor)
        lua_setfield(L, -2, "fgColor")
        L.push(chooserSetSubTextColor)
        lua_setfield(L, -2, "subTextColor")
        L.push(chooserSetBgDark)
        lua_setfield(L, -2, "bgDark")
        L.push(chooserPlaceholder)
        lua_setfield(L, -2, "placeholderText")
        L.push(chooserSetSearchSubText)
        lua_setfield(L, -2, "searchSubText")
        L.push(chooserSetEnableDefaultForQuery)
        lua_setfield(L, -2, "enableDefaultForQuery")
        L.push(chooserSetWidth)
        lua_setfield(L, -2, "width")
        L.push(chooserSetNumRows)
        lua_setfield(L, -2, "rows")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for type identification
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the registry name
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(chooserNew)
        lua_setfield(L, -2, "new")
    }
}
