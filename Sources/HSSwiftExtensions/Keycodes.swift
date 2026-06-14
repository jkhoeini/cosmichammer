import Cocoa
import CLua
import Lua
import Carbon

private let USERDATA_TAG = "hs.keycodes.callback"
private var refTable: Int32 = LUA_NOREF

// MARK: - Keycode Helpers

private func pushkeycode(_ L: UnsafeMutablePointer<lua_State>!, _ code: Int, _ key: String) {
    // t[key] = code
    L.push(lua_Integer(code))
    lua_setfield(L, -2, key)

    // t[code] = key
    L.push(key)
    lua_rawseti(L, -2, lua_Integer(code))
}

@_cdecl("keycodes_cachemap")
public func keycodes_cachemap(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)

    let relocatableKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_B), UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_D), UInt16(kVK_ANSI_E), UInt16(kVK_ANSI_F),
        UInt16(kVK_ANSI_G), UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_I), UInt16(kVK_ANSI_J), UInt16(kVK_ANSI_K), UInt16(kVK_ANSI_L),
        UInt16(kVK_ANSI_M), UInt16(kVK_ANSI_N), UInt16(kVK_ANSI_O), UInt16(kVK_ANSI_P), UInt16(kVK_ANSI_Q), UInt16(kVK_ANSI_R),
        UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_T), UInt16(kVK_ANSI_U), UInt16(kVK_ANSI_V), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_X),
        UInt16(kVK_ANSI_Y), UInt16(kVK_ANSI_Z), UInt16(kVK_ANSI_0), UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
        UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
        UInt16(kVK_ANSI_Grave), UInt16(kVK_ANSI_Equal), UInt16(kVK_ANSI_Minus), UInt16(kVK_ANSI_RightBracket),
        UInt16(kVK_ANSI_LeftBracket), UInt16(kVK_ANSI_Quote), UInt16(kVK_ANSI_Semicolon), UInt16(kVK_ANSI_Backslash),
        UInt16(kVK_ANSI_Comma), UInt16(kVK_ANSI_Slash), UInt16(kVK_ANSI_Period), UInt16(kVK_ISO_Section),
        UInt16(kVK_JIS_Yen), UInt16(kVK_JIS_Underscore), UInt16(kVK_JIS_KeypadComma), UInt16(kVK_JIS_Eisu), UInt16(kVK_JIS_Kana),
    ]

    // NOTE: It appears that TISCopyCurrentKeyboardInputSources() can return NULL
    let currentKeyboard = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let layoutDataRef = currentKeyboard.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
    let layoutData = layoutDataRef.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }

    if let layoutData = layoutData {
        layoutData.withUnsafeBytes { rawBuf in
            let keyboardLayout = rawBuf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            var keysDown: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var realLength: Int = 0

            for i in 0..<relocatableKeyCodes.count {
                let status = UCKeyTranslate(
                    keyboardLayout,
                    relocatableKeyCodes[i],
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &keysDown,
                    chars.count,
                    &realLength,
                    &chars
                )
                if status == noErr && realLength > 0 {
                    let name = String(NSString(characters: &chars, length: 1))
                    // Ugly hack to work around an unexplained change in macOS12
                    if relocatableKeyCodes[i] != 93 && relocatableKeyCodes[i] != 94 {
                        pushkeycode(L, Int(relocatableKeyCodes[i]), name)
                    }
                }
            }
        }
    } else {
        pushkeycode(L, Int(kVK_ANSI_A), "a")
        pushkeycode(L, Int(kVK_ANSI_B), "b")
        pushkeycode(L, Int(kVK_ANSI_C), "c")
        pushkeycode(L, Int(kVK_ANSI_D), "d")
        pushkeycode(L, Int(kVK_ANSI_E), "e")
        pushkeycode(L, Int(kVK_ANSI_F), "f")
        pushkeycode(L, Int(kVK_ANSI_G), "g")
        pushkeycode(L, Int(kVK_ANSI_H), "h")
        pushkeycode(L, Int(kVK_ANSI_I), "i")
        pushkeycode(L, Int(kVK_ANSI_J), "j")
        pushkeycode(L, Int(kVK_ANSI_K), "k")
        pushkeycode(L, Int(kVK_ANSI_L), "l")
        pushkeycode(L, Int(kVK_ANSI_M), "m")
        pushkeycode(L, Int(kVK_ANSI_N), "n")
        pushkeycode(L, Int(kVK_ANSI_O), "o")
        pushkeycode(L, Int(kVK_ANSI_P), "p")
        pushkeycode(L, Int(kVK_ANSI_Q), "q")
        pushkeycode(L, Int(kVK_ANSI_R), "r")
        pushkeycode(L, Int(kVK_ANSI_S), "s")
        pushkeycode(L, Int(kVK_ANSI_T), "t")
        pushkeycode(L, Int(kVK_ANSI_U), "u")
        pushkeycode(L, Int(kVK_ANSI_V), "v")
        pushkeycode(L, Int(kVK_ANSI_W), "w")
        pushkeycode(L, Int(kVK_ANSI_X), "x")
        pushkeycode(L, Int(kVK_ANSI_Y), "y")
        pushkeycode(L, Int(kVK_ANSI_Z), "z")
        pushkeycode(L, Int(kVK_ANSI_0), "0")
        pushkeycode(L, Int(kVK_ANSI_1), "1")
        pushkeycode(L, Int(kVK_ANSI_2), "2")
        pushkeycode(L, Int(kVK_ANSI_3), "3")
        pushkeycode(L, Int(kVK_ANSI_4), "4")
        pushkeycode(L, Int(kVK_ANSI_5), "5")
        pushkeycode(L, Int(kVK_ANSI_6), "6")
        pushkeycode(L, Int(kVK_ANSI_7), "7")
        pushkeycode(L, Int(kVK_ANSI_8), "8")
        pushkeycode(L, Int(kVK_ANSI_9), "9")
        pushkeycode(L, Int(kVK_ANSI_Grave), "`")
        pushkeycode(L, Int(kVK_ANSI_Equal), "=")
        pushkeycode(L, Int(kVK_ANSI_Minus), "-")
        pushkeycode(L, Int(kVK_ANSI_RightBracket), "]")
        pushkeycode(L, Int(kVK_ANSI_LeftBracket), "[")
        pushkeycode(L, Int(kVK_ANSI_Quote), "'")
        pushkeycode(L, Int(kVK_ANSI_Semicolon), ";")
        pushkeycode(L, Int(kVK_ANSI_Backslash), "\\")
        pushkeycode(L, Int(kVK_ANSI_Comma), ",")
        pushkeycode(L, Int(kVK_ANSI_Slash), "/")
        pushkeycode(L, Int(kVK_ANSI_Period), ".")
        pushkeycode(L, Int(kVK_ISO_Section), "\u{00A7}") // section sign
    }

    // Function keys
    pushkeycode(L, Int(kVK_F1), "f1")
    pushkeycode(L, Int(kVK_F2), "f2")
    pushkeycode(L, Int(kVK_F3), "f3")
    pushkeycode(L, Int(kVK_F4), "f4")
    pushkeycode(L, Int(kVK_F5), "f5")
    pushkeycode(L, Int(kVK_F6), "f6")
    pushkeycode(L, Int(kVK_F7), "f7")
    pushkeycode(L, Int(kVK_F8), "f8")
    pushkeycode(L, Int(kVK_F9), "f9")
    pushkeycode(L, Int(kVK_F10), "f10")
    pushkeycode(L, Int(kVK_F11), "f11")
    pushkeycode(L, Int(kVK_F12), "f12")
    pushkeycode(L, Int(kVK_F13), "f13")
    pushkeycode(L, Int(kVK_F14), "f14")
    pushkeycode(L, Int(kVK_F15), "f15")
    pushkeycode(L, Int(kVK_F16), "f16")
    pushkeycode(L, Int(kVK_F17), "f17")
    pushkeycode(L, Int(kVK_F18), "f18")
    pushkeycode(L, Int(kVK_F19), "f19")
    pushkeycode(L, Int(kVK_F20), "f20")

    // Keypad
    pushkeycode(L, Int(kVK_ANSI_KeypadDecimal), "pad.")
    pushkeycode(L, Int(kVK_ANSI_KeypadMultiply), "pad*")
    pushkeycode(L, Int(kVK_ANSI_KeypadPlus), "pad+")
    pushkeycode(L, Int(kVK_ANSI_KeypadDivide), "pad/")
    pushkeycode(L, Int(kVK_ANSI_KeypadMinus), "pad-")
    pushkeycode(L, Int(kVK_ANSI_KeypadEquals), "pad=")
    pushkeycode(L, Int(kVK_ANSI_Keypad0), "pad0")
    pushkeycode(L, Int(kVK_ANSI_Keypad1), "pad1")
    pushkeycode(L, Int(kVK_ANSI_Keypad2), "pad2")
    pushkeycode(L, Int(kVK_ANSI_Keypad3), "pad3")
    pushkeycode(L, Int(kVK_ANSI_Keypad4), "pad4")
    pushkeycode(L, Int(kVK_ANSI_Keypad5), "pad5")
    pushkeycode(L, Int(kVK_ANSI_Keypad6), "pad6")
    pushkeycode(L, Int(kVK_ANSI_Keypad7), "pad7")
    pushkeycode(L, Int(kVK_ANSI_Keypad8), "pad8")
    pushkeycode(L, Int(kVK_ANSI_Keypad9), "pad9")
    pushkeycode(L, Int(kVK_ANSI_KeypadClear), "padclear")
    pushkeycode(L, Int(kVK_ANSI_KeypadEnter), "padenter")

    // Navigation / special keys
    pushkeycode(L, Int(kVK_Return), "return")
    pushkeycode(L, Int(kVK_Tab), "tab")
    pushkeycode(L, Int(kVK_Space), "space")
    pushkeycode(L, Int(kVK_Delete), "delete")
    pushkeycode(L, Int(kVK_Escape), "escape")
    pushkeycode(L, Int(kVK_Help), "help")
    pushkeycode(L, Int(kVK_Home), "home")
    pushkeycode(L, Int(kVK_PageUp), "pageup")
    pushkeycode(L, Int(kVK_ForwardDelete), "forwarddelete")
    pushkeycode(L, Int(kVK_End), "end")
    pushkeycode(L, Int(kVK_PageDown), "pagedown")
    pushkeycode(L, Int(kVK_LeftArrow), "left")
    pushkeycode(L, Int(kVK_RightArrow), "right")
    pushkeycode(L, Int(kVK_DownArrow), "down")
    pushkeycode(L, Int(kVK_UpArrow), "up")

    // Modifier keys
    pushkeycode(L, Int(kVK_Command), "cmd")
    pushkeycode(L, Int(kVK_RightCommand), "rightcmd")
    pushkeycode(L, Int(kVK_Shift), "shift")
    pushkeycode(L, Int(kVK_CapsLock), "capslock")
    pushkeycode(L, Int(kVK_Option), "alt")
    pushkeycode(L, Int(kVK_Control), "ctrl")
    pushkeycode(L, Int(kVK_RightShift), "rightshift")
    pushkeycode(L, Int(kVK_RightOption), "rightalt")
    pushkeycode(L, Int(kVK_RightControl), "rightctrl")
    pushkeycode(L, Int(kVK_Function), "fn")

    // JIS keys
    pushkeycode(L, Int(kVK_JIS_Yen), "yen")
    pushkeycode(L, Int(kVK_JIS_Underscore), "underscore")
    pushkeycode(L, Int(kVK_JIS_KeypadComma), "pad,")
    pushkeycode(L, Int(kVK_JIS_Eisu), "eisu")
    pushkeycode(L, Int(kVK_JIS_Kana), "kana")

    return 1
}

// MARK: - Keycodes Observer

class MJKeycodesObserver: NSObject, LuaTeardownable {
    var ref: Int32 = LUA_NOREF
    var lsCanary: UInt64 = UInt64()
    private var running = false
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if running {
            running = false
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil
            )
        }
        if ref != LUA_NOREF {
            if let L = lua_getCurrentState() {
                luaL_unref(L, LUA_REGISTRYINDEX_VALUE, ref)
            }
            ref = LUA_NOREF
        }
    }

    @objc func inputSourceChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.ref != LUA_NOREF else { return }
            let L = lua_getCurrentState()!
            guard lua_isStateGenerationValid(self.lsCanary) else { return }
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(self.ref))
            if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputSourceChanged(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    func stop() {
        guard running else { return }
        running = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }
}

// MARK: - Callback Functions (migrated to idiomatic LuaSwift)

// MARK: - Layout Helper Functions

@_cdecl("getLayoutName")
public func getLayoutName(_ layout: TISInputSource!) -> Unmanaged<NSString>? {
    guard let layout = layout else { return nil }
    guard let rawName = TISGetInputSourceProperty(layout, kTISPropertyLocalizedName) else { return nil }
    let name = Unmanaged<NSString>.fromOpaque(rawName).takeUnretainedValue()
    return Unmanaged.passRetained(name)
}

private func getLayoutNameSwift(_ layout: TISInputSource) -> String? {
    guard let rawName = TISGetInputSourceProperty(layout, kTISPropertyLocalizedName) else { return nil }
    return Unmanaged<NSString>.fromOpaque(rawName).takeUnretainedValue() as String
}

@_cdecl("pushSourceIcon")
public func pushSourceIcon(_ L: UnsafeMutablePointer<lua_State>!, _ source: TISInputSource!) {
    guard let source = source,
          let iconRef = TISGetInputSourceProperty(source, kTISPropertyIconRef) else {
        lua_pushnil(L)
        return
    }
    let icon = iconRef.assumingMemoryBound(to: OpaquePointer.self).pointee
    let image = NSImage(iconRef: icon)
    lua_pushany(L, image)
}

private func getAllLayouts() -> [TISInputSource]? {
    let properties: [String: Any] = [
        kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
        kTISPropertyInputSourceIsSelectCapable as String: true,
    ]
    guard let list = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() else {
        return nil
    }
    return list as? [TISInputSource]
}

private func getAllInputMethods() -> [TISInputSource]? {
    let properties: [String: Any] = [
        kTISPropertyInputSourceType as String: kTISTypeKeyboardInputMode as String,
        kTISPropertyInputSourceIsSelectCapable as String: true,
    ]
    guard let list = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() else {
        return nil
    }
    return list as? [TISInputSource]
}

// MARK: - Module Functions

/// hs.keycodes.currentSourceID([sourceID]) -> string | boolean
/// Function
/// Get or set the source id for the keyboard input source
///
/// Parameters:
///  * sourceID - an optional string specifying the input source to set for keyboard input
///
/// Returns:
///  * If no parameter is provided, returns a string containing the source id for the current keyboard layout or input method; if a parameter is provided, returns true or false specifying whether or not the input source was able to be changed.
private func keycodes_sourceID(_ L: LuaState) throws -> CInt {

    if lua_gettop(L) == 0 {
        let layout = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
        let sourceID = Unmanaged<NSString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue()
        lua_pushany(L, sourceID)
    } else {
        var found = false
        let sourceID = lua_tovalue(L, at: 1) as! String
        let prop: [String: Any] = [
            kTISPropertyInputSourceID as String: sourceID,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        if let sources = TISCreateInputSourceList(prop as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
           !sources.isEmpty {
            found = TISSelectInputSource(sources[0]) == noErr
        }
        L.push(found)
    }
    return 1
}

/// hs.keycodes.currentLayout() -> string
/// Function
/// Gets the name of the current keyboard layout
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the current keyboard layout
private func keycodes_currentLayout(_ L: LuaState) throws -> CInt {
    let layout = TISCopyCurrentKeyboardLayoutInputSource()!.takeRetainedValue()
    lua_pushany(L, getLayoutNameSwift(layout) as NSString?)
    return 1
}

/// hs.keycodes.currentLayoutIcon() -> hs.image object
/// Function
/// Gets the icon of the current keyboard layout
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.image object containing the icon, if available
private func keycodes_currentLayoutIcon(_ L: LuaState) throws -> CInt {
    let layout = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
    pushSourceIcon(L, layout)
    return 1
}

/// hs.keycodes.layouts([sourceID]) -> table
/// Function
/// Gets all of the enabled keyboard layouts that the keyboard input source can be switched to
///
/// Parameters:
///  * sourceID - an optional boolean, default false, indicating whether the keyboard layout names should be returned (false) or their source IDs (true).
///
/// Returns:
///  * A table containing a list of keyboard layouts enabled in System Preferences
///
/// Notes:
///  * Only those layouts which can be explicitly switched to will be included in the table.  Keyboard layouts which are part of input methods are not included.  See `hs.keycodes.methods`.
private func keycodes_layouts(_ L: LuaState) throws -> CInt {
    let sourceIDsOnly = lua_gettop(L) == 1 ? (lua_toboolean(L, 1) != 0) : false
    let layouts = getAllLayouts()

    lua_newtable(L)
    if let layouts = layouts {
        for layout in layouts {
            if sourceIDsOnly {
                let sid = Unmanaged<NSString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue()
                lua_pushany(L, sid)
            } else {
                lua_pushany(L, getLayoutNameSwift(layout) as NSString?)
            }
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    return 1
}

/// hs.keycodes.methods([sourceID]) -> table
/// Function
/// Gets all of the enabled input methods that the keyboard input source can be switched to
///
/// Parameters:
///  * sourceID - an optional boolean, default false, indicating whether the keyboard input method names should be returned (false) or their source IDs (true).
///
/// Returns:
///  * A table containing a list of input methods enabled in System Preferences
///
/// Notes:
///  * Keyboard layouts which are not part of an input method are not included in this table.  See `hs.keycodes.layouts`.
private func keycodes_methods(_ L: LuaState) throws -> CInt {
    let sourceIDsOnly = lua_gettop(L) == 1 ? (lua_toboolean(L, 1) != 0) : false
    let methods = getAllInputMethods()

    lua_newtable(L)
    if let methods = methods {
        for method in methods {
            if sourceIDsOnly {
                let sid = Unmanaged<NSString>.fromOpaque(TISGetInputSourceProperty(method, kTISPropertyInputSourceID)).takeUnretainedValue()
                lua_pushany(L, sid)
            } else {
                lua_pushany(L, getLayoutNameSwift(method) as NSString?)
            }
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    return 1
}

/// hs.keycodes.currentMethod() -> string
/// Function
/// Get current input method
///
/// Parameters:
///  * None
///
/// Returns:
///  * Name of current input method, or nil
private func keycodes_currentMethod(_ L: LuaState) throws -> CInt {
    var currentMethod: String? = nil

    if let methods = getAllInputMethods() {
        for method in methods {
            let selected = TISGetInputSourceProperty(method, kTISPropertyInputSourceIsSelected)
            if let selected = selected {
                let boolVal = Unmanaged<CFBoolean>.fromOpaque(selected).takeUnretainedValue()
                if CFBooleanGetValue(boolVal) {
                    currentMethod = getLayoutNameSwift(method)
                    break
                }
            }
        }
    }
    lua_pushany(L, currentMethod as NSString?)
    return 1
}

/// hs.keycodes.setLayout(layoutName) -> boolean
/// Function
/// Changes the system keyboard layout
///
/// Parameters:
///  * layoutName - A string containing the name of an enabled keyboard layout
///
/// Returns:
///  * A boolean, true if the layout was successfully changed, otherwise false
private func keycodes_setLayout(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let desiredLayout = lua_tovalue(L, at: 1) as! String
    var found = false

    if let layouts = getAllLayouts() {
        for layout in layouts {
            if let layoutName = getLayoutNameSwift(layout),
               layoutName == desiredLayout,
               TISSelectInputSource(layout) == noErr {
                found = true
            }
        }
    }
    L.push(found)
    return 1
}

/// hs.keycodes.setMethod(methodName) -> boolean
/// Function
/// Changes the system input method
///
/// Parameters:
///  * methodName - A string containing the name of an enabled input method
///
/// Returns:
///  * A boolean, true if the method was successfully changed, otherwise false
private func keycodes_setMethod(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let desiredLayout = lua_tovalue(L, at: 1) as! String
    var found = false

    if let methods = getAllInputMethods() {
        for method in methods {
            if let layoutName = getLayoutNameSwift(method),
               layoutName == desiredLayout,
               TISSelectInputSource(method) == noErr {
                found = true
            }
        }
    }
    L.push(found)
    return 1
}

/// hs.keycodes.iconForLayoutOrMethod(sourceName) -> hs.image object
/// Function
/// Gets an hs.image object for a given keyboard layout or input method
///
/// Parameters:
///  * sourceName - A string containing the name of an input method or keyboard layout
///
/// Returns:
///  * An hs.image object, or nil if no image could be found
///
/// Notes:
///  * Not all layouts/methods have icons, so you should assume this will return nil at some point
private func keycodes_getIcon(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let sourceName = lua_tovalue(L, at: 1) as! String
    let layouts = getAllLayouts()
    let methods = getAllInputMethods()
    var found = false

    if let layouts = layouts {
        for layout in layouts {
            if let layoutName = getLayoutNameSwift(layout), layoutName == sourceName {
                pushSourceIcon(L, layout)
                found = true
                break
            }
        }
    }
    if !found {
        if let methods = methods {
            for method in methods {
                if let layoutName = getLayoutNameSwift(method), layoutName == sourceName {
                    pushSourceIcon(L, method)
                    found = true
                    break
                }
            }
        }
    }

    if !found {
        lua_pushnil(L)
    }

    return 1
}

@_cdecl("luaopen_hs_libkeycodes")
public func luaopen_hs_libkeycodes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register idiomatic Metatable<MJKeycodesObserver> with LuaSwift
        L.register(Metatable<MJKeycodesObserver>(
            fields: [
                "_stop": .closure { L in
                    let observer: MJKeycodesObserver = try L.checkArgument(1)
                    lua_settop(L, 1)
                    observer.stop()
                    return 1
                },
            ],
            tostring: .closure { L in
                let _: MJKeycodesObserver = try L.checkArgument(1)
                let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
                L.push(desc)
                return 1
            }
        ))
        installMetatableBoilerplate(L, for: MJKeycodesObserver.self, tag: USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 11)

        // _newcallback constructor
        L.push { (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)

            lua_pushvalue(L, 1)
            let ref = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

            let observer = MJKeycodesObserver()
            observer.ref = ref
            observer.lsCanary = lua_currentStateGeneration()
            observer.start()

            L.push(userdata: observer)
            return 1
        }
        lua_setfield(L, -2, "_newcallback")

        lua_pushcclosure(L, keycodes_cachemap, 0)
        lua_setfield(L, -2, "_cachemap")
        L.push(keycodes_currentLayout)
        lua_setfield(L, -2, "currentLayout")
        L.push(keycodes_currentLayoutIcon)
        lua_setfield(L, -2, "currentLayoutIcon")
        L.push(keycodes_currentMethod)
        lua_setfield(L, -2, "currentMethod")
        L.push(keycodes_layouts)
        lua_setfield(L, -2, "layouts")
        L.push(keycodes_methods)
        lua_setfield(L, -2, "methods")
        L.push(keycodes_setLayout)
        lua_setfield(L, -2, "setLayout")
        L.push(keycodes_setMethod)
        lua_setfield(L, -2, "setMethod")
        L.push(keycodes_getIcon)
        lua_setfield(L, -2, "iconForLayoutOrMethod")
        L.push(keycodes_sourceID)
        lua_setfield(L, -2, "currentSourceID")
    }
}
