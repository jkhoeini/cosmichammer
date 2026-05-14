import Cocoa
import LuaSkin

private let USERDATA_TAG = "hs.speech.listener"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - HSSpeechRecognizer Definition

private class HSSpeechRecognizer: NSSpeechRecognizer, NSSpeechRecognizerDelegate {
    var callbackRef: Int32 = LUA_NOREF
    var isListeningFlag: Bool = false
    // We don't use the same trick as we do for synthesizer because a recognizer also exists in
    // the dictation scope (it's visual components) and, if we opened it because we're the only
    // listener, it will only go away when we explicitly remove *all* of our references to it.
    // This means aggressive garbage collection or making sure all possible lua references
    // are in fact the same pointer to the reference, and not just pointers to the same reference.
    var selfRef: Int32 = LUA_NOREF

    override init() {
        super.init()
        self.callbackRef = LUA_NOREF
        self.selfRef = LUA_NOREF
        self.isListeningFlag = false
        self.delegate = self
    }

    // MARK: - NSSpeechRecognizerDelegate

    func speechRecognizer(_ sender: NSSpeechRecognizer, didRecognizeCommand command: String) {
        guard let recognizer = sender as? HSSpeechRecognizer, recognizer.callbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.shared(withState: nil)
        _lua_stackguard_entry(skin.L)

        skin.pushLuaRef(refTable, ref: recognizer.callbackRef)
        skin.pushNSObject(recognizer)
        skin.pushNSObject(command as NSString)
        skin.protectedCallAndError("hs.speech.listener callback", nargs: 2, nresults: 0)
        _lua_stackguard_exit(skin.L)
    }
}

// MARK: - Helpers

private func get_recognizerFromUserdata(_ L: OpaquePointer!, at idx: Int32) -> HSSpeechRecognizer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSSpeechRecognizer>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_recognizerFromUserdata_transfer(_ L: OpaquePointer!, at idx: Int32) -> HSSpeechRecognizer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSSpeechRecognizer>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
}

// MARK: - Module Functions

/// hs.speech.listener.new([title]) -> recognizerObject
/// Constructor
/// Creates a new speech recognizer object for use by Hammerspoon.
///
/// Parameters:
///  * title - an optional parameter specifying the title under which commands assigned to this speech recognizer will be listed in the Dictation Commands display when it is visible.  Defaults to "Hammerspoon".
///
/// Returns:
///  * a speech recognizer object or nil, if the system was unable to create a new recognizer.
///
/// Notes:
///  * You can change the title later with the `hs.speech.listener:title` method.
private func newSpeechRecognizer(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    var theTitle: String? = nil
    if lua_gettop(L) == 1 {
        luaL_checkstring(L, 1)
        theTitle = skin.toNSObject(atIndex: 1) as? String
        if theTitle == nil { skin.logWarn("unable to identify title from string, defaulting to \"Hammerspoon\"") }
    }

    let recognizer = HSSpeechRecognizer()
    if let title = theTitle {
        recognizer.displayedCommandsTitle = title
    }
    skin.pushNSObject(recognizer)
    return 1
}

// MARK: - Module Object Methods

/// hs.speech.listener:commands([commandsArray]) -> recognizerObject | current value
/// Method
/// Get or set the commands this speech recognizer will listen for.
private func commands(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    if lua_gettop(L) == 2 {
        var theCommands: [String] = []
        let len = luaL_len(L, 2)
        for i in 0..<len {
            let type = lua_rawgeti(L, 2, i + 1)
            if type == LUA_TSTRING || type == LUA_TNUMBER {
                luaL_checkstring(L, -1)
                if let cmd = skin.toNSObject(atIndex: -1) as? String {
                    theCommands.append(cmd)
                } else {
                    skin.logWarn("invalid string evaluates to nil, skipping")
                }
            } else {
                skin.logWarn("not a string or number value, skipping")
            }
            lua_pop(L, 1)
        }
        recognizer.commands = theCommands
        lua_pushvalue(L, 1)
    } else {
        skin.pushNSObject(recognizer.commands as NSArray?)
    }
    return 1
}

/// hs.speech.listener:title([title]) -> recognizerObject | current value
/// Method
/// Get or set the title for a speech recognizer.
private func displayedCommandsTitle(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    if lua_gettop(L) == 2 {
        var theTitle: String? = nil
        if lua_type(L, 2) != LUA_TNIL {
            luaL_checkstring(L, 2)
            theTitle = skin.toNSObject(atIndex: 2) as? String
        }
        recognizer.displayedCommandsTitle = theTitle ?? "Hammerspoon"
        lua_pushvalue(L, 1)
    } else {
        skin.pushNSObject(recognizer.displayedCommandsTitle as NSString?)
    }
    return 1
}

/// hs.speech.listener:foregroundOnly([flag]) -> recognizerObject | current value
/// Method
/// Get or set whether or not the speech recognizer is active only when the Hammerspoon application is active.
private func listensInForegroundOnly(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    if lua_gettop(L) == 2 {
        recognizer.listensInForegroundOnly = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, recognizer.listensInForegroundOnly ? 1 : 0)
    }
    return 1
}

/// hs.speech.listener:blocksOtherRecognizers([flag]) -> recognizerObject | current value
/// Method
/// Get or set whether or not the speech recognizer should block other recognizers when it is active.
private func blocksOtherRecognizers(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    if lua_gettop(L) == 2 {
        recognizer.blocksOtherRecognizers = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, recognizer.blocksOtherRecognizers ? 1 : 0)
    }
    return 1
}

/// hs.speech.listener:start() -> recognizerObject
/// Method
/// Make the speech recognizer active.
private func startListening(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    recognizer.startListening()
    recognizer.isListeningFlag = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech.listener:stop() -> recognizerObject
/// Method
/// Disables the speech recognizer.
private func stopListening(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    recognizer.stopListening()
    recognizer.isListeningFlag = false
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech.listener:isListening() -> boolean
/// Method
/// Returns a boolean value indicating whether or not the recognizer is currently enabled (started).
private func isListening(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    lua_pushboolean(L, recognizer.isListeningFlag ? 1 : 0)
    return 1
}

/// hs.speech.listener:setCallback(fn) -> recognizerObject
/// Method
/// Sets or removes a callback function for the speech recognizer.
private func setCallback(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    recognizer.callbackRef = skin.luaUnref(refTable, ref: recognizer.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        recognizer.callbackRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSSpeechRecognizer(_ L: OpaquePointer!, obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let recognizer = obj as! HSSpeechRecognizer

    if recognizer.selfRef == LUA_NOREF {
        let recognizerPtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
        recognizerPtr.storeBytes(of: Unmanaged.passRetained(recognizer).toOpaque(), as: UnsafeRawPointer.self)
        luaL_getmetatable(L, USERDATA_TAG)
        lua_setmetatable(L, -2)
        recognizer.selfRef = skin.luaRef(refTable)
    }

    skin.pushLuaRef(refTable, ref: recognizer.selfRef)
    return 1
}

// MARK: - Hammerspoon Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let skin = LuaSkin.shared(withState: L)
    skin.pushNSObject(NSString(format: "%s: %@ (%p)", USERDATA_TAG, (recognizer.displayedCommandsTitle ?? "Hammerspoon") as NSString, Unmanaged.passUnretained(recognizer).toOpaque()))
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let rec1 = get_recognizerFromUserdata(L, at: 1)
        let rec2 = get_recognizerFromUserdata(L, at: 2)
        lua_pushboolean(L, rec1.isEqual(to: rec2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.speech.listener:delete() -> recognizerObject
/// Method
/// Disables the speech recognizer and removes it from the possible available speech recognizers.
private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let recognizer = get_recognizerFromUserdata_transfer(L, at: 1)
    let skin = LuaSkin.shared(withState: L)

    recognizer.callbackRef = skin.luaUnref(refTable, ref: recognizer.callbackRef)
    recognizer.selfRef = skin.luaUnref(refTable, ref: recognizer.selfRef)
    recognizer.stopListening()
    recognizer.delegate = nil

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - luaL_Reg tables

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("commands"), func: commands),
    luaL_Reg(name: strdup("title"), func: displayedCommandsTitle),
    luaL_Reg(name: strdup("foregroundOnly"), func: listensInForegroundOnly),
    luaL_Reg(name: strdup("blocksOtherRecognizers"), func: blocksOtherRecognizers),
    luaL_Reg(name: strdup("start"), func: startListening),
    luaL_Reg(name: strdup("stop"), func: stopListening),
    luaL_Reg(name: strdup("isListening"), func: isListening),
    luaL_Reg(name: strdup("setCallback"), func: setCallback),
    luaL_Reg(name: strdup("delete"), func: userdata_gc),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil)
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: newSpeechRecognizer),
    luaL_Reg(name: nil, func: nil)
]

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspeechlistener")
public func luaopen_hs_libspeechlistener(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushHSSpeechRecognizer, forClass: "HSSpeechRecognizer")

    return 1
}
