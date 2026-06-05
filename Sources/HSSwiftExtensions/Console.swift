import Cocoa
import CLua
import os.log

private var refTable: Int32 = LUA_NOREF

// MARK: - Runtime access to MJConsoleWindowController (lives in HSExtensions, not visible at compile time)

private let HSConsoleDarkModeKey = "HSConsoleDarkModeKey"

private func consoleDarkModeEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: HSConsoleDarkModeKey)
}

private func consoleDarkModeSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: HSConsoleDarkModeKey)
}

/// Returns the MJConsoleWindowController singleton via runtime lookup.
private func consoleController() -> NSObject {
    let cls: AnyClass = NSClassFromString("MJConsoleWindowController")!
    let sel = NSSelectorFromString("singleton")
    let result = (cls as AnyObject).perform(sel)!
    return result.takeUnretainedValue() as! NSObject
}

/// Returns the console NSWindow.
private func consoleWindow() -> NSWindow {
    consoleController().value(forKey: "window") as! NSWindow
}

/// Returns the output NSTextView.
private func consoleOutputView() -> NSTextView {
    consoleController().value(forKey: "outputView") as! NSTextView
}

/// Returns the input NSTextField.
private func consoleInputField() -> NSTextField {
    consoleController().value(forKey: "inputField") as! NSTextField
}

/// Returns the console font.
private func consoleFont() -> NSFont {
    consoleController().value(forKey: "consoleFont") as! NSFont
}

/// Returns the stdout color.
private func consoleColorForStdout() -> NSColor {
    consoleController().value(forKey: "MJColorForStdout") as! NSColor
}

/// Returns the command color.
private func consoleColorForCommand() -> NSColor {
    consoleController().value(forKey: "MJColorForCommand") as! NSColor
}

/// Returns the result color.
private func consoleColorForResult() -> NSColor {
    consoleController().value(forKey: "MJColorForResult") as! NSColor
}

/// Returns the history mutable array.
private func consoleHistory() -> NSMutableArray {
    consoleController().value(forKey: "history") as! NSMutableArray
}

/// Returns the max console output history.
private func consoleMaxOutputHistory() -> NSNumber {
    consoleController().value(forKey: "maxConsoleOutputHistory") as! NSNumber
}

private func consoleColorFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSColor? {
    guard lua_type(L, index) == LUA_TTABLE else { return nil }
    return table_toNSColor(L, index) as? NSColor
}

private func consolePushColor(_ L: UnsafeMutablePointer<lua_State>!, _ color: NSColor?) {
    guard let color else {
        lua_pushnil(L)
        return
    }
    NSColor_tolua(L, color)
}

private func consolePushFont(_ L: UnsafeMutablePointer<lua_State>!, _ font: NSFont?) {
    guard let font else {
        lua_pushnil(L)
        return
    }
    lua_pushNSFont(L, font)
}

private func consoleStyledTextFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSAttributedString? {
    guard lua_type(L, index) == LUA_TUSERDATA, luaL_testudata(L, index, "hs.styledtext") != nil else {
        return nil
    }
    return toNSAttributedString(L, at: index)
}

private func consoleHistoryFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSMutableArray? {
    guard lua_type(L, index) == LUA_TTABLE else { return nil }
    let absIndex = lua_absindex(L, index)
    let length = Int(luaL_len(L, absIndex))
    var seenIndexes = Set<Int>()

    lua_pushnil(L)
    while lua_next(L, absIndex) != 0 {
        let validKey: Bool
        if lua_type(L, -2) == LUA_TNUMBER, lua_isinteger(L, -2) != 0 {
            let key = Int(lua_tointeger(L, -2))
            validKey = key >= 1 && key <= length
            if validKey { seenIndexes.insert(key) }
        } else {
            validKey = false
        }
        lua_pop(L, 1)
        if !validKey {
            lua_pop(L, 1)
            return nil
        }
    }

    guard seenIndexes.count == length else { return nil }

    let history = NSMutableArray(capacity: length)
    guard length > 0 else { return history }

    for index in 1...length {
        lua_rawgeti(L, absIndex, lua_Integer(index))
        let valueType = lua_type(L, -1)
        guard valueType == LUA_TSTRING || valueType == LUA_TNUMBER else {
            lua_pop(L, 1)
            return nil
        }
        luaL_tolstring(L, -1, nil)
        guard let text = lua_tostringValue(L, at: -1) else {
            lua_pop(L, 2)
            return nil
        }
        history.add(text)
        lua_pop(L, 2)
    }

    return history
}

// MARK: - Lua Functions

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
private func consoleDarkMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_isboolean(L, 1) {
        consoleDarkModeSetEnabled(lua_toboolean(L, 1) != 0)
        let ctrl = consoleController()
        ctrl.perform(NSSelectorFromString("reflectDefaults"))
    }

    lua_pushboolean(L, consoleDarkModeEnabled() ? 1 : 0)
    return 1
}

/// hs.console.consolePrintColor([color]) -> color
/// Function
/// Get or set the color that regular output displayed in the Cosmic Hammer console is displayed with.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current color.
private func console_consolePrintColor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ctrl = consoleController()

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        guard let color = consoleColorFromLua(L, at: 1) else {
            return luaL_argerror(L, 1, "expected color table")
        }
        ctrl.setValue(color, forKey: "MJColorForStdout")
    }

    consolePushColor(L, consoleColorForStdout())
    return 1
}

/// hs.console.maxOutputHistory([length]) -> number
/// Function
/// Get or set the max length of the Cosmic Hammer console's scrollback history.
///
/// Parameters:
///  * length - an optional number containing the maximum size in bytes of the Cosmic Hammer console history.
///
/// Returns:
///  * the current maximum size of the console history
///
/// Notes:
///  * A length value of zero will allow the history to grow infinitely
///  * The default console history is 100,000 characters
private func console_maxOutputHistory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if lua_type(L, 1) != LUA_TNONE {
        let size = NSNumber(value: Int32(lua_tointeger(L, 1)))
        consoleController().setValue(size, forKey: "maxConsoleOutputHistory")
    }

    lua_pushinteger(L, lua_Integer(consoleMaxOutputHistory().intValue))
    return 1
}

/// hs.console.consoleFont([font]) -> fontTable
/// Function
/// Get or set the font used in the Cosmic Hammer console.
///
/// Parameters:
///  * font - an optional string or table describing the font to use in the console. If a string is specified, then the default system font size will be used.  If a table is specified, it should contain a `name` key-value pair and a `size` key-value pair describing the font to be used.
///
/// Returns:
///  * the current font setting as a table containing a `name` key and a `size` key.
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current font.
private func console_consoleFont(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if lua_type(L, 1) != LUA_TNONE {
        guard let newFont = tableToNSFont(L, at: 1) else {
            return luaL_argerror(L, 1, "expected font name string or font table")
        }
        consoleController().setValue(newFont, forKey: "consoleFont")
    }

    consolePushFont(L, consoleFont())
    return 1
}

/// hs.console.consoleCommandColor([color]) -> color
/// Function
/// Get or set the color that commands displayed in the Cosmic Hammer console are displayed with.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current color.
private func console_consoleCommandColor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ctrl = consoleController()

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        guard let color = consoleColorFromLua(L, at: 1) else {
            return luaL_argerror(L, 1, "expected color table")
        }
        ctrl.setValue(color, forKey: "MJColorForCommand")
    }

    consolePushColor(L, consoleColorForCommand())
    return 1
}

/// hs.console.consoleResultColor([color]) -> color
/// Function
/// Get or set the color that function results displayed in the Cosmic Hammer console are displayed with.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
///  * Note this only affects future output -- anything already in the console will remain its current color.
private func console_consoleResultColor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ctrl = consoleController()

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        guard let color = consoleColorFromLua(L, at: 1) else {
            return luaL_argerror(L, 1, "expected color table")
        }
        ctrl.setValue(color, forKey: "MJColorForResult")
    }

    consolePushColor(L, consoleColorForResult())
    return 1
}

/// hs.console.hswindow() -> hs.window object
/// Function
/// Get an hs.window object which represents the Cosmic Hammer console window
///
/// Parameters:
///  * None
///
/// Returns:
///  * an hs.window object
private func console_asWindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let console = consoleWindow()

    let windowID = CGWindowID(console.windowNumber)
    lua_getglobal(L, "require")

    lua_pushstring(L, "hs.window")

    lua_pcall(L, 1, 1, 0)
    lua_getfield(L, -1, "windowForID")
    lua_pushinteger(L, lua_Integer(windowID))
    lua_call(L, 1, 1)
    return 1
}

/// hs.console.windowBackgroundColor([color]) -> color
/// Function
/// Get or set the color for the background of the Cosmic Hammer Console's window.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
private func console_backgroundColor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let console = consoleWindow()

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        guard let color = consoleColorFromLua(L, at: 1) else {
            return luaL_argerror(L, 1, "expected color table")
        }
        console.backgroundColor = color
    }

    consolePushColor(L, console.backgroundColor)
    return 1
}

/// hs.console.outputBackgroundColor([color]) -> color
/// Function
/// Get or set the color for the background of the Cosmic Hammer Console's output view.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
private func console_outputBackgroundColor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let output = consoleOutputView()

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        guard let color = consoleColorFromLua(L, at: 1) else {
            return luaL_argerror(L, 1, "expected color table")
        }
        output.backgroundColor = color
    }

    consolePushColor(L, output.backgroundColor)
    return 1
}

/// hs.console.inputBackgroundColor([color]) -> color
/// Function
/// Get or set the color for the background of the Cosmic Hammer Console's input field.
///
/// Parameters:
///  * color - an optional table containing color keys as described in `hs.drawing.color`
///
/// Returns:
///  * the current color setting as a table
///
/// Notes:
///  * See the `hs.drawing.color` entry in the Dash documentation, or type `help.hs.drawing.color` in the Cosmic Hammer console to get more information on how to specify a color.
private func console_inputBackgroundColor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let input = consoleInputField()

    if lua_type(L, 1) != LUA_TNONE {
        luaL_checktype(L, 1, LUA_TTABLE)
        guard let color = consoleColorFromLua(L, at: 1) else {
            return luaL_argerror(L, 1, "expected color table")
        }
        input.backgroundColor = color
    }

    consolePushColor(L, input.backgroundColor)
    return 1
}

/// hs.console.smartInsertDeleteEnabled([flag]) -> bool
/// Function
/// Determine whether or not objects copied from the console window insert or delete space around selected words to preserve proper spacing and punctuation.
///
/// Parameters:
///  * flag - an optional boolean value indicating whether or not "smart" space behavior is enabled when copying from the Cosmic Hammer console.
///
/// Returns:
///  * the current value
///
/// Notes:
///  * this only applies to future copy operations from the Cosmic Hammer console -- anything already in the clipboard is not affected.
private func console_smartInsertDeleteEnabled(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let output = consoleOutputView()

    if lua_type(L, 1) != LUA_TNONE {
        output.smartInsertDeleteEnabled = lua_toboolean(L, 1) != 0
    }

    lua_pushboolean(L, output.smartInsertDeleteEnabled ? 1 : 0)
    return 1
}

/// hs.console.getHistory() -> array
/// Function
/// Get the Cosmic Hammer console command history as an array.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array containing the history of commands entered into the Cosmic Hammer console.
private func console_getHistory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    lua_pushany(L, consoleHistory())
    return 1
}

/// hs.console.setConsole([styledText]) -> none
/// Function
/// Clear the Cosmic Hammer console output window.
///
/// Parameters:
///  * styledText - an optional `hs.styledtext` object containing the text you wish to replace the Cosmic Hammer console output with.  If you do not provide an argument, the console is cleared of all content.
///
/// Returns:
///  * None
///
/// Notes:
///  * You can specify the console content as a string or as an `hs.styledtext` object in either userdata or table format.
private func console_setConsole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ctrl = consoleController()
    let outputView = consoleOutputView()

    if lua_gettop(L) == 0 {
        if let error: String = catchingObjCException({
            outputView.textStorage?.performSelector(
                onMainThread: #selector(NSMutableAttributedString.setAttributedString(_:)),
                with: NSMutableAttributedString(),
                waitUntilDone: true
            )
        }) {
            os_log(.error, "caught ObjC exception: \(error, privacy: .public)")
        }
    } else {
        let theStr: NSAttributedString
        if lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.styledtext") != nil {
            guard let styledText = consoleStyledTextFromLua(L, at: 1) else {
                return luaL_argerror(L, 1, "expected hs.styledtext userdata")
            }
            theStr = styledText
        } else {
            let consoleAttrs: [NSAttributedString.Key: Any] = [
                .font: consoleFont(),
                .foregroundColor: consoleColorForStdout(),
            ]
            luaL_tolstring(L, 1, nil)
            let text = lua_tostringValue(L, at: -1) ?? ""
            theStr = NSAttributedString(
                string: text,
                attributes: consoleAttrs
            )
            lua_pop(L, 1)
        }
        if let error: String = catchingObjCException({
            outputView.textStorage?.performSelector(
                onMainThread: #selector(NSMutableAttributedString.setAttributedString(_:)),
                with: theStr,
                waitUntilDone: true
            )
        }) {
            os_log(.error, "caught ObjC exception: \(error, privacy: .public)")
        }
    }
    outputView.scrollToEndOfDocument(ctrl)
    return 0
}

/// hs.console.getConsole([styled]) -> text | styledText
/// Function
/// Get the text of the Cosmic Hammer console output window.
///
/// Parameters:
///  * styled - an optional boolean indicating whether the console text is returned as a string or a styledText object.  Defaults to false.
///
/// Returns:
///  * The text currently in the Cosmic Hammer console output window as either a string or an `hs.styledtext` object.
///
/// Notes:
///  * If the text of the console is retrieved as a string, no color or style information in the console output is retrieved - only the raw text.
private func console_getConsole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let outputView = consoleOutputView()
    let styled = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) != 0) : false

    if styled {
        lua_pushany(L, outputView.textStorage?.copy())
    } else {
        lua_pushany(L, outputView.textStorage?.string)
    }

    return 1
}

/// hs.console.setHistory(array) -> nil
/// Function
/// Set the Cosmic Hammer console command history to the items specified in the given array.
///
/// Parameters:
///  * array - the list of commands to set the Cosmic Hammer console history to.
///
/// Returns:
///  * None
///
/// Notes:
///  * You can clear the console history by using an empty array (e.g. `hs.console.setHistory({})`
private func console_setHistory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TTABLE)
    let ctrl = consoleController()

    guard let newHistory = consoleHistoryFromLua(L, at: 1) else {
        return luaL_argerror(L, 1, "expected array of history strings")
    }
    ctrl.setValue(newHistory, forKey: "history")
    ctrl.setValue(newHistory.count, forKey: "historyIndex")
    lua_pushnil(L)
    return 1
}

/// hs.console.printStyledtext(...) -> none
/// Function
/// A print function which recognizes `hs.styledtext` objects and renders them as such in the Cosmic Hammer console.
///
/// Parameters:
///  * Any number of arguments can be specified, just like the builtin Lua `print` command.  If an argument matches the userdata type of `hs.styledtext`, the text is rendered as defined by its style attributes in the Cosmic Hammer console; otherwise it is rendered as it would be via the traditional `print` command within Cosmic Hammer.
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
private func console_printStyledText(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ctrl = consoleController()
    let outputView = consoleOutputView()
    let consoleAttrs: [NSAttributedString.Key: Any] = [
        .font: consoleFont(),
        .foregroundColor: consoleColorForStdout(),
    ]

    let theStr = NSMutableAttributedString()
    let top = lua_gettop(L)
    for i: Int32 in 1...top {
        if i > 1 {
            theStr.append(NSAttributedString(string: "\t", attributes: consoleAttrs))
        }
        if lua_type(L, i) == LUA_TUSERDATA && luaL_testudata(L, i, "hs.styledtext") != nil {
            guard let styledText = consoleStyledTextFromLua(L, at: i) else {
                return luaL_argerror(L, i, "expected hs.styledtext userdata")
            }
            theStr.append(styledText)
        } else {
            luaL_tolstring(L, i, nil)
            let text = lua_tostringValue(L, at: -1) ?? ""
            theStr.append(NSAttributedString(
                string: text,
                attributes: consoleAttrs
            ))
            lua_pop(L, 1)
        }
    }
    theStr.append(NSAttributedString(string: "\n", attributes: consoleAttrs))

    if let error: String = catchingObjCException({
        outputView.textStorage?.performSelector(
            onMainThread: #selector(NSMutableAttributedString.append(_:)),
            with: theStr,
            waitUntilDone: true
        )
    }) {
        os_log(.error, "caught ObjC exception: \(error, privacy: .public)")
    }
    outputView.scrollToEndOfDocument(ctrl)
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
private func console_level(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let console = consoleWindow()

    if lua_gettop(L) == 1 {
        let targetLevel = lua_tointeger(L, 1)
        let minLevel = lua_Integer(CGWindowLevelForKey(.minimumWindow))
        let maxLevel = lua_Integer(CGWindowLevelForKey(.maximumWindow))

        if targetLevel >= minLevel && targetLevel <= maxLevel {
            console.level = NSWindow.Level(rawValue: Int(targetLevel))
        } else {
            return luaL_error(L, "window level must be between \(minLevel) and \(maxLevel) inclusive")
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
///  * `alpha` - an optional number between 0.0 and 1.0 specifying the new alpha level for the Cosmic Hammer console.
///
/// Returns:
///  * the current, possibly new, value.
private func console_alpha(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let console = consoleWindow()

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
///  * `behavior` - an optional number representing the desired window behaviors for the Cosmic Hammer console.
///
/// Returns:
///  * the current, possibly new, value.
///
/// Notes:
///  * Window behaviors determine how the webview object is handled by Spaces and Exposé. See `hs.drawing.windowBehaviors` for more information.
private func console_behavior(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let console = consoleWindow()

    if lua_gettop(L) == 1 {
        let newLevel = lua_tointeger(L, 1)
        console.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
    }
    lua_pushinteger(L, lua_Integer(console.collectionBehavior.rawValue))
    return 1
}

/// hs.console.titleVisibility([state]) -> current value
/// Function
/// Get or set whether or not the "Cosmic Hammer Console" text appears in the Cosmic Hammer console titlebar.
///
/// Parameters:
///  * state - an optional string containing the text "visible" or "hidden", specifying whether or not the console window's title text appears.
///
/// Returns:
///  * a string of "visible" or "hidden" specifying the current (possibly changed) state of the window title's visibility.
///
/// Notes:
///  * When a toolbar is attached to the Cosmic Hammer console (see the `hs.webview.toolbar` module documentation), this function can be used to specify whether the Toolbar appears underneath the console window's title ("visible") or in the window's title bar itself, as seen in applications like Safari ("hidden"). When the title is hidden, the toolbar will only display the toolbar items as icons without labels, and ignores changes made with `hs.webview.toolbar:displayMode`.
///
///  * If a toolbar is attached to the console, you can achieve the same effect as this function with `hs.console.toolbar():inTitleBar(boolean)`
private func console_titleVisibility(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let console = consoleWindow()
    let mapping: [String: NSWindow.TitleVisibility] = [
        "visible": .visible,
        "hidden": .hidden,
    ]

    if lua_gettop(L) == 1 {
        let key = lua_tovalue(L, at: 1) as! String
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
        lua_pushany(L, value)
    } else {
        os_log(.info, "%{public}s", "unrecognized titleVisibility \(titleVisibility.rawValue) -- notify developers")
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
public func luaopen_hs_libconsole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Create module table
    lua_createtable(L, 0, Int32(extrasLib.count - 1))
    luaL_setfuncs(L, &extrasLib, 0)

    return 1
}
