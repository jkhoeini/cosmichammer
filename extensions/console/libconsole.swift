import Cocoa
import LuaSkin

private var refTable: LSRefTable = LUA_NOREF

/// hs.console.darkMode([state]) -> bool
/// Function
/// Set or display whether or not the Console window should display in dark mode.
///
/// Parameters:
///  * state - an optional boolean which will set whether or not the Console window should display in dark mode.
///
/// Returns:
///  * A boolean, true if dark mode is enabled otherwise false.
///
/// Notes:
///  * Enabling Dark Mode for the Console only affects the window background, and doesn't automatically change the Console's Background Color, so you will need to add something similar to:
///    ```lua
///    if hs.console.darkMode() then
///        hs.console.outputBackgroundColor{ white = 0 }
///        hs.console.consoleCommandColor{ white = 1 }
///        hs.console.alpha(.8)
///    end
///.   ```
private func consoleDarkMode(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    if lua_isboolean(L, 1) != 0 {
        ConsoleDarkModeSetEnabled(lua_toboolean(L, 1) != 0)
        MJConsoleWindowController.singleton().reflectDefaults()
    }

    lua_pushboolean(L, ConsoleDarkModeEnabled() ? 1 : 0)
    return 1
}

/// hs.console.consolePrintColor([color]) -> color
/// Function
/// Get or set the color that regular output displayed in the Hammerspoon console is displayed with.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current color.
private func console_consolePrintColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        MJConsoleWindowController.singleton().mjColorForStdout =
            skin.luaObjectAtIndex(1, toClass: "NSColor") as! NSColor
    }

    skin.pushNSObject(MJConsoleWindowController.singleton().mjColorForStdout)
    return 1
}

/// hs.console.maxOutputHistory([length]) -> number
/// Function
/// Get or set the max length of the Hammerspoon console's scrollback history.
///
/// Parameters:
///  * length - an optional number containing the maximum size in bytes of the Hammerspoon console history.
///
/// Returns:
///  * the current maximum size of the console history
///
/// Notes:
///  * A length value of zero will allow the history to grow infinitely
///  * The default console history is 100,000 characters
private func console_maxOutputHistory(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    if lua_type(L, 1) != LUA_TNONE {
        let size = NSNumber(value: Int32(lua_tointeger(L, 1)))
        MJConsoleWindowController.singleton().maxConsoleOutputHistory = size
    }

    lua_pushinteger(L, lua_Integer(MJConsoleWindowController.singleton().maxConsoleOutputHistory.intValue))
    return 1
}

/// hs.console.consoleFont([font]) -> fontTable
/// Function
/// Get or set the font used in the Hammerspoon console.
///
/// Parameters:
///  * font - an optional string or table describing the font to use in the console. If a string is specified, then the default system font size will be used.  If a table is specified, it should contain a `name` key-value pair and a `size` key-value pair describing the font to be used.
///
/// Returns:
///  * the current font setting as a table containing a `name` key and a `size` key.
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current font.
private func console_consoleFont(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    if lua_type(L, 1) != LUA_TNONE {
        if let newFont = skin.luaObjectAtIndex(1, toClass: "NSFont") as? NSFont {
            MJConsoleWindowController.singleton().consoleFont = newFont
        }
    }

    skin.pushNSObject(MJConsoleWindowController.singleton().consoleFont)
    return 1
}

/// hs.console.consoleCommandColor([color]) -> color
/// Function
/// Get or set the color that commands displayed in the Hammerspoon console are displayed with.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current color.
private func console_consoleCommandColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        MJConsoleWindowController.singleton().mjColorForCommand =
            skin.luaObjectAtIndex(1, toClass: "NSColor") as! NSColor
    }

    skin.pushNSObject(MJConsoleWindowController.singleton().mjColorForCommand)
    return 1
}

/// hs.console.consoleResultColor([color]) -> color
/// Function
/// Get or set the color that function results displayed in the Hammerspoon console are displayed with.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current color.
private func console_consoleResultColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        MJConsoleWindowController.singleton().mjColorForResult =
            skin.luaObjectAtIndex(1, toClass: "NSColor") as! NSColor
    }

    skin.pushNSObject(MJConsoleWindowController.singleton().mjColorForResult)
    return 1
}

/// hs.console.hswindow() -> hs.window object
/// Function
/// Get an hs.window object which represents the Hammerspoon console window
///
/// Parameters:
///  * None
///
/// Returns:
///  * an hs.window object
private func console_asWindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let console = MJConsoleWindowController.singleton().window!

    let windowID = CGWindowID(console.windowNumber)
    skin.requireModule("hs.window")
    lua_getfield(L, -1, "windowForID")
    lua_pushinteger(L, lua_Integer(windowID))
    lua_call(L, 1, 1)
    return 1
}

/// hs.console.windowBackgroundColor([color]) -> color
/// Function
/// Get or set the color for the background of the Hammerspoon Console's window.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
private func console_backgroundColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let console = MJConsoleWindowController.singleton().window!

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        console.backgroundColor = skin.luaObjectAtIndex(1, toClass: "NSColor") as! NSColor
    }

    skin.pushNSObject(console.backgroundColor)
    return 1
}

/// hs.console.outputBackgroundColor([color]) -> color
/// Function
/// Get or set the color for the background of the Hammerspoon Console's output view.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
private func console_outputBackgroundColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let output = MJConsoleWindowController.singleton().outputView!

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        output.backgroundColor = skin.luaObjectAtIndex(1, toClass: "NSColor") as! NSColor
    }

    skin.pushNSObject(output.backgroundColor)
    return 1
}

/// hs.console.inputBackgroundColor([color]) -> color
/// Function
/// Get or set the color for the background of the Hammerspoon Console's input field.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Hammerspoon console to get more information on how to specify a color.
private func console_inputBackgroundColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let input = MJConsoleWindowController.singleton().inputField!

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        input.backgroundColor = skin.luaObjectAtIndex(1, toClass: "NSColor") as! NSColor
    }

    skin.pushNSObject(input.backgroundColor)
    return 1
}

/// hs.console.smartInsertDeleteEnabled([flag]) -> bool
/// Function
/// Determine whether or not objects copied from the console window insert or delete space around selected words to preserve proper spacing and punctuation.
///
/// Parameters:
///  * flag - an optional boolean value indicating whether or not "smart" space behavior is enabled when copying from the Hammerspoon console.
///
/// Returns:
///  * the current value
///
/// Notes:
///  * this only applies to future copy operations from the Hammerspoon console -- anything already in the clipboard is not affected.
private func console_smartInsertDeleteEnabled(_ L: OpaquePointer!) -> Int32 {
    let output = MJConsoleWindowController.singleton().outputView!

    if lua_type(L, 1) != LUA_TNONE {
        output.smartInsertDeleteEnabled = lua_toboolean(L, 1) != 0
    }

    lua_pushboolean(L, output.smartInsertDeleteEnabled ? 1 : 0)
    return 1
}

/// hs.console.getHistory() -> array
/// Function
/// Get the Hammerspoon console command history as an array.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array containing the history of commands entered into the Hammerspoon console.
private func console_getHistory(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)
    let console = MJConsoleWindowController.singleton()

    skin.pushNSObject(console.history)
    return 1
}

/// hs.console.setConsole([styledText]) -> none
/// Function
/// Clear the Hammerspoon console output window.
///
/// Parameters:
///  * styledText - an optional `hs.styledtext` object containing the text you wish to replace the Hammerspoon console output with.  If you do not provide an argument, the console is cleared of all content.
///
/// Returns:
///  * None
///
/// Notes:
///  * You can specify the console content as a string or as an `hs.styledtext` object in either userdata or table format.
private func console_setConsole(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let console = MJConsoleWindowController.singleton()

    if lua_gettop(L) == 0 {
        console.outputView.textStorage?.performSelector(
            onMainThread: #selector(NSMutableAttributedString.setAttributedString(_:)),
            with: NSMutableAttributedString(),
            waitUntilDone: true
        )
    } else {
        let theStr: NSAttributedString
        if lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.styledtext") != nil {
            theStr = skin.luaObjectAtIndex(1, toClass: "NSAttributedString") as! NSAttributedString
        } else {
            let consoleAttrs: [NSAttributedString.Key: Any] = [
                .font: MJConsoleWindowController.singleton().consoleFont!,
                .foregroundColor: MJConsoleWindowController.singleton().mjColorForStdout!,
            ]
            luaL_tolstring(L, 1, nil)
            theStr = NSAttributedString(
                string: skin.toNSObject(atIndex: -1) as! String,
                attributes: consoleAttrs
            )
            lua_pop(L, 1)
        }
        console.outputView.textStorage?.performSelector(
            onMainThread: #selector(NSMutableAttributedString.setAttributedString(_:)),
            with: theStr,
            waitUntilDone: true
        )
    }
    console.outputView.scrollToEndOfDocument(console)
    return 0
}

/// hs.console.getConsole([styled]) -> text | styledText
/// Function
/// Get the text of the Hammerspoon console output window.
///
/// Parameters:
///  * styled - an optional boolean indicating whether the console text is returned as a string or a styledText object.  Defaults to false.
///
/// Returns:
///  * The text currently in the Hammerspoon console output window as either a string or an `hs.styledtext` object.
///
/// Notes:
///  * If the text of the console is retrieved as a string, no color or style information in the console output is retrieved - only the raw text.
private func console_getConsole(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let console = MJConsoleWindowController.singleton()
    let styled = lua_isboolean(L, 1) != 0 ? (lua_toboolean(L, 1) != 0) : false

    if styled {
        skin.pushNSObject(console.outputView.textStorage?.copy())
    } else {
        skin.pushNSObject(console.outputView.textStorage?.string)
    }

    return 1
}

/// hs.console.setHistory(array) -> nil
/// Function
/// Set the Hammerspoon console command history to the items specified in the given array.
///
/// Parameters:
///  * array - the list of commands to set the Hammerspoon console history to.
///
/// Returns:
///  * None
///
/// Notes:
///  * You can clear the console history by using an empty array (e.g. `hs.console.setHistory({})`
private func console_setHistory(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TTABLE, LS_TBREAK)
    let console = MJConsoleWindowController.singleton()

    console.history = skin.toNSObject(atIndex: 1) as! NSMutableArray
    console.historyIndex = console.history.count
    lua_pushnil(L)
    return 1
}

/// hs.console.printStyledtext(...) -> none
/// Function
/// A print function which recognizes `hs.styledtext` objects and renders them as such in the Hammerspoon console.
///
/// Parameters:
///  * Any number of arguments can be specified, just like the builtin Lua `print` command.  If an argument matches the userdata type of `hs.styledtext`, the text is rendered as defined by its style attributes in the Hammerspoon console; otherwise it is rendered as it would be via the traditional `print` command within Hammerspoon.
///
/// Returns:
///  * None
///
/// Notes:
///  * This has been made as close to the Lua `print` command as possible.  You can replace the existing print command with this by adding the following to your `init.lua` file:
///
/// ~~~
///    print = function(...)
///        hs.rawprint(...)
///        hs.console.printStyledtext(...)
///    end
/// ~~~
private func console_printStyledText(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let console = MJConsoleWindowController.singleton()
    let consoleAttrs: [NSAttributedString.Key: Any] = [
        .font: MJConsoleWindowController.singleton().consoleFont!,
        .foregroundColor: MJConsoleWindowController.singleton().mjColorForStdout!,
    ]

    let theStr = NSMutableAttributedString()
    let top = lua_gettop(L)
    for i: Int32 in 1...top {
        if i > 1 {
            theStr.append(NSAttributedString(string: "\t", attributes: consoleAttrs))
        }
        if lua_type(L, i) == LUA_TUSERDATA && luaL_testudata(L, i, "hs.styledtext") != nil {
            theStr.append(skin.luaObjectAtIndex(i, toClass: "NSAttributedString") as! NSAttributedString)
        } else {
            luaL_tolstring(L, i, nil)
            theStr.append(NSAttributedString(
                string: skin.toNSObject(atIndex: -1) as! String,
                attributes: consoleAttrs
            ))
            lua_pop(L, 1)
        }
    }
    theStr.append(NSAttributedString(string: "\n", attributes: consoleAttrs))

    console.outputView.textStorage?.performSelector(
        onMainThread: #selector(NSMutableAttributedString.append(_:)),
        with: theStr,
        waitUntilDone: true
    )
    console.outputView.scrollToEndOfDocument(console)
    return 0
}

/// hs.console.level([theLevel]) -> currentValue
/// Function
/// Get or set the console window level
///
/// Parameters:
///  * `theLevel` - an optional parameter specifying the desired level as an integer, which can be obtained from `hs.drawing.windowLevels`.
///
/// Returns:
///  * the current, possibly new, value
///
/// Notes:
///  * see the notes for `hs.drawing.windowLevels`
private func console_level(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let console = MJConsoleWindowController.singleton().window!

    if lua_gettop(L) == 1 {
        let targetLevel = lua_tointeger(L, 1)
        let minLevel = lua_Integer(CGWindowLevelForKey(.minimumWindow))
        let maxLevel = lua_Integer(CGWindowLevelForKey(.maximumWindow))

        if targetLevel >= minLevel && targetLevel <= maxLevel {
            console.level = NSWindow.Level(rawValue: Int(targetLevel))
        } else {
            return luaL_error(L, "window level must be between %d and %d inclusive", minLevel, maxLevel)
        }
    }
    lua_pushinteger(L, lua_Integer(console.level.rawValue))
    return 1
}

/// hs.console.alpha([alpha]) -> currentValue
/// Function
/// Get or set the alpha level of the console window.
///
/// Parameters:
///  * `alpha` - an optional number between 0.0 and 1.0 specifying the new alpha level for the Hammerspoon console.
///
/// Returns:
///  * the current, possibly new, value.
private func console_alpha(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let console = MJConsoleWindowController.singleton().window!

    if lua_gettop(L) == 1 {
        let newLevel = CGFloat(luaL_checknumber(L, 1))
        console.alphaValue = min(max(newLevel, 0.0), 1.0)
    }
    lua_pushnumber(L, lua_Number(console.alphaValue))
    return 1
}

/// hs.console.behavior([behavior]) -> currentValue
/// Method
/// Get or set the window behavior settings for the console.
///
/// Parameters:
///  * `behavior` - an optional number representing the desired window behaviors for the Hammerspoon console.
///
/// Returns:
///  * the current, possibly new, value.
///
/// Notes:
///  * Window behaviors determine how the webview object is handled by Spaces and Exposé. See `hs.drawing.windowBehaviors` for more information.
private func console_behavior(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    let console = MJConsoleWindowController.singleton().window!

    if lua_gettop(L) == 1 {
        skin.checkArgs(LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
        let newLevel = lua_tointeger(L, 1)
        console.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
    }
    lua_pushinteger(L, lua_Integer(console.collectionBehavior.rawValue))
    return 1
}

/// hs.console.titleVisibility([state]) -> current value
/// Function
/// Get or set whether or not the "Hammerspoon Console" text appears in the Hammerspoon console titlebar.
///
/// Parameters:
///  * state - an optional string containing the text "visible" or "hidden", specifying whether or not the console window's title text appears.
///
/// Returns:
///  * a string of "visible" or "hidden" specifying the current (possibly changed) state of the window title's visibility.
///
/// Notes:
///  * When a toolbar is attached to the Hammerspoon console (see the `hs.webview.toolbar` module documentation), this function can be used to specify whether the Toolbar appears underneath the console window's title ("visible") or in the window's title bar itself, as seen in applications like Safari ("hidden"). When the title is hidden, the toolbar will only display the toolbar items as icons without labels, and ignores changes made with `hs.webview.toolbar:displayMode`.
///
///  * If a toolbar is attached to the console, you can achieve the same effect as this function with `hs.console.toolbar():inTitleBar(boolean)`
private func console_titleVisibility(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let console = MJConsoleWindowController.singleton().window!
    let mapping: [String: NSWindow.TitleVisibility] = [
        "visible": .visible,
        "hidden": .hidden,
    ]

    if lua_gettop(L) == 1 {
        let key = skin.toNSObject(atIndex: 1) as! String
        if let value = mapping[key] {
            console.titleVisibility = value
            lua_pushvalue(L, 1)
        } else {
            let keys = mapping.keys.joined(separator: "', '")
            return luaL_argerror(L, 2, "must be one of '\(keys)'")
        }
    }

    let titleVisibility = console.titleVisibility
    if let value = mapping.first(where: { $0.value == titleVisibility })?.key {
        skin.pushNSObject(value)
    } else {
        skin.logWarn("unrecognized titleVisibility \(titleVisibility.rawValue) -- notify developers")
        lua_pushnil(L)
    }
    return 1
}

private var extrasLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("darkMode"), func: consoleDarkMode),
    luaL_Reg(name: strdup("hswindow"), func: console_asWindow),
    luaL_Reg(name: strdup("windowBackgroundColor"), func: console_backgroundColor),
    luaL_Reg(name: strdup("inputBackgroundColor"), func: console_inputBackgroundColor),
    luaL_Reg(name: strdup("outputBackgroundColor"), func: console_outputBackgroundColor),
    luaL_Reg(name: strdup("smartInsertDeleteEnabled"), func: console_smartInsertDeleteEnabled),
    luaL_Reg(name: strdup("getHistory"), func: console_getHistory),
    luaL_Reg(name: strdup("setHistory"), func: console_setHistory),
    luaL_Reg(name: strdup("maxOutputHistory"), func: console_maxOutputHistory),
    luaL_Reg(name: strdup("getConsole"), func: console_getConsole),
    luaL_Reg(name: strdup("setConsole"), func: console_setConsole),
    luaL_Reg(name: strdup("consoleCommandColor"), func: console_consoleCommandColor),
    luaL_Reg(name: strdup("consoleResultColor"), func: console_consoleResultColor),
    luaL_Reg(name: strdup("consolePrintColor"), func: console_consolePrintColor),
    luaL_Reg(name: strdup("consoleFont"), func: console_consoleFont),
    luaL_Reg(name: strdup("titleVisibility"), func: console_titleVisibility),
    luaL_Reg(name: strdup("level"), func: console_level),
    luaL_Reg(name: strdup("alpha"), func: console_alpha),
    luaL_Reg(name: strdup("behavior"), func: console_behavior),
    luaL_Reg(name: strdup("printStyledtext"), func: console_printStyledText),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libconsole")
public func luaopen_hs_libconsole(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary("hs.console", functions: &extrasLib, metaFunctions: nil)
    return 1
}
