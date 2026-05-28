import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.keycodes.callback"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Keycode Helpers

private func pushkeycode(_ L: UnsafeMutablePointer<lua_State>!, _ code: Int, _ key: String) {
    // t[key] = code
    lua_pushinteger(L, lua_Integer(code))
    lua_setfield(L, -2, key)

    // t[code] = key
    lua_pushstring(L, key)
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

class MJKeycodesObserver: NSObject {
    var ref: Int32 = LUA_NOREF
    var lsCanary: LSGCCanary = LSGCCanary()

    @objc func inputSourceChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.ref != LUA_NOREF else { return }
            let skin = LuaSkin.skin(with: nil)
            guard skin.check(self.lsCanary) else { return }
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: self.ref)
            skin.protectedCallAndError("hs.keycodes.inputSourceChanged", nargs: 0, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputSourceChanged(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }
}

// MARK: - Callback Functions

private func keycodes_newcallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    luaL_checktype(L, 1, LUA_TFUNCTION)

    lua_pushvalue(L, 1)
    let ref = skin.luaRef(refTable)

    let observer = MJKeycodesObserver()
    observer.ref = ref
    observer.lsCanary = skin.createGCCanary()
    observer.start()

    let ud = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    ud.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = Unmanaged.passRetained(observer).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

private func keycodes_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = lua_topointer(L, 1)
    let str = "\(USERDATA_TAG): (0x\(String(Int(bitPattern: ptr), radix: 16)))"
    lua_pushstring(L, str)
    return 1
}

private func keycodes_callback_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let observer = Unmanaged<MJKeycodesObserver>.fromOpaque(ptr.pointee!).takeRetainedValue()

    var tmpCanary = observer.lsCanary
    skin.destroy(&tmpCanary)
    observer.lsCanary = tmpCanary

    observer.stop()
    observer.ref = skin.luaUnref(refTable, ref: observer.ref)
    return 0
}

private func keycodes_callback_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let observer = Unmanaged<MJKeycodesObserver>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    observer.stop()
    return 0
}

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
    let skin = LuaSkin.skin(with: L)
    guard let source = source,
          let iconRef = TISGetInputSourceProperty(source, kTISPropertyIconRef) else {
        lua_pushnil(L)
        return
    }
    let icon = iconRef.assumingMemoryBound(to: OpaquePointer.self).pointee
    let image = NSImage(iconRef: icon)
    skin.pushNSObject(image)
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
private func keycodes_sourceID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    if lua_gettop(L) == 0 {
        let layout = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
        let sourceID = Unmanaged<NSString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue()
        skin.pushNSObject(sourceID)
    } else {
        var found = false
        let sourceID = skin.toNSObject(atIndex: 1) as! String
        let prop: [String: Any] = [
            kTISPropertyInputSourceID as String: sourceID,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        if let sources = TISCreateInputSourceList(prop as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
           !sources.isEmpty {
            found = TISSelectInputSource(sources[0]) == noErr
        }
        lua_pushboolean(L, found ? 1 : 0)
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
private func keycodes_currentLayout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let layout = TISCopyCurrentKeyboardLayoutInputSource()!.takeRetainedValue()
    skin.pushNSObject(getLayoutNameSwift(layout) as NSString?)
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
private func keycodes_currentLayoutIcon(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func keycodes_layouts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let sourceIDsOnly = lua_gettop(L) == 1 ? (lua_toboolean(L, 1) != 0) : false
    let layouts = getAllLayouts()

    lua_newtable(L)
    if let layouts = layouts {
        for layout in layouts {
            if sourceIDsOnly {
                let sid = Unmanaged<NSString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue()
                skin.pushNSObject(sid)
            } else {
                skin.pushNSObject(getLayoutNameSwift(layout) as NSString?)
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
private func keycodes_methods(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let sourceIDsOnly = lua_gettop(L) == 1 ? (lua_toboolean(L, 1) != 0) : false
    let methods = getAllInputMethods()

    lua_newtable(L)
    if let methods = methods {
        for method in methods {
            if sourceIDsOnly {
                let sid = Unmanaged<NSString>.fromOpaque(TISGetInputSourceProperty(method, kTISPropertyInputSourceID)).takeUnretainedValue()
                skin.pushNSObject(sid)
            } else {
                skin.pushNSObject(getLayoutNameSwift(method) as NSString?)
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
private func keycodes_currentMethod(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
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
    skin.pushNSObject(currentMethod as NSString?)
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
private func keycodes_setLayout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let desiredLayout = skin.toNSObject(atIndex: 1) as! String
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
    lua_pushboolean(L, found ? 1 : 0)
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
private func keycodes_setMethod(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let desiredLayout = skin.toNSObject(atIndex: 1) as! String
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
    lua_pushboolean(L, found ? 1 : 0)
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
private func keycodes_getIcon(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let sourceName = skin.toNSObject(atIndex: 1) as! String
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

// MARK: - C-callable wrappers

private let keycodes_newcallback_wrapper: lua_CFunction = { L in keycodes_newcallback(L) }
private let keycodes_userdata_tostring_wrapper: lua_CFunction = { L in keycodes_userdata_tostring(L) }
private let keycodes_callback_gc_wrapper: lua_CFunction = { L in keycodes_callback_gc(L) }
private let keycodes_callback_stop_wrapper: lua_CFunction = { L in keycodes_callback_stop(L) }
private let keycodes_cachemap_wrapper: lua_CFunction = { L in keycodes_cachemap(L) }
private let keycodes_currentLayout_wrapper: lua_CFunction = { L in keycodes_currentLayout(L) }
private let keycodes_currentLayoutIcon_wrapper: lua_CFunction = { L in keycodes_currentLayoutIcon(L) }
private let keycodes_currentMethod_wrapper: lua_CFunction = { L in keycodes_currentMethod(L) }
private let keycodes_layouts_wrapper: lua_CFunction = { L in keycodes_layouts(L) }
private let keycodes_methods_wrapper: lua_CFunction = { L in keycodes_methods(L) }
private let keycodes_setLayout_wrapper: lua_CFunction = { L in keycodes_setLayout(L) }
private let keycodes_setMethod_wrapper: lua_CFunction = { L in keycodes_setMethod(L) }
private let keycodes_getIcon_wrapper: lua_CFunction = { L in keycodes_getIcon(L) }
private let keycodes_sourceID_wrapper: lua_CFunction = { L in keycodes_sourceID(L) }

// MARK: - Registration Tables

private var callbacklib: [luaL_Reg] = [
    // instance methods
    luaL_Reg(name: strdup("_stop"), func: keycodes_callback_stop_wrapper),
    // metamethods
    luaL_Reg(name: strdup("__tostring"), func: keycodes_userdata_tostring_wrapper),
    luaL_Reg(name: strdup("__gc"), func: keycodes_callback_gc_wrapper),
    luaL_Reg(name: nil, func: nil),
]

private var keycodeslib: [luaL_Reg] = [
    // module methods
    luaL_Reg(name: strdup("_newcallback"), func: keycodes_newcallback_wrapper),
    luaL_Reg(name: strdup("_cachemap"), func: keycodes_cachemap_wrapper),
    luaL_Reg(name: strdup("currentLayout"), func: keycodes_currentLayout_wrapper),
    luaL_Reg(name: strdup("currentLayoutIcon"), func: keycodes_currentLayoutIcon_wrapper),
    luaL_Reg(name: strdup("currentMethod"), func: keycodes_currentMethod_wrapper),
    luaL_Reg(name: strdup("layouts"), func: keycodes_layouts_wrapper),
    luaL_Reg(name: strdup("methods"), func: keycodes_methods_wrapper),
    luaL_Reg(name: strdup("setLayout"), func: keycodes_setLayout_wrapper),
    luaL_Reg(name: strdup("setMethod"), func: keycodes_setMethod_wrapper),
    luaL_Reg(name: strdup("iconForLayoutOrMethod"), func: keycodes_getIcon_wrapper),
    luaL_Reg(name: strdup("currentSourceID"), func: keycodes_sourceID_wrapper),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libkeycodes")
public func luaopen_hs_libkeycodes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &callbacklib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(keycodeslib.count - 1))
    luaL_setfuncs(L, &keycodeslib, 0)

    return 1
}
