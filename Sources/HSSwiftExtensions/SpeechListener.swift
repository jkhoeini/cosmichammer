import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.speech.listener"
private var refTable: Int32 = LUA_NOREF

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

    override init?() {
        super.init()
        self.callbackRef = LUA_NOREF
        self.selfRef = LUA_NOREF
        self.isListeningFlag = false
        self.delegate = self
    }

    // MARK: - NSSpeechRecognizerDelegate

    func speechRecognizer(_ sender: NSSpeechRecognizer, didRecognizeCommand command: String) {
        guard let recognizer = sender as? HSSpeechRecognizer, recognizer.callbackRef != LUA_NOREF else { return }
        let L = lua_getCurrentState()!

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(recognizer.callbackRef))
        pushHSSpeechRecognizer(L, obj: recognizer)
        lua_pushany(L, command as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
}

// MARK: - Helpers

private func get_recognizerFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSSpeechRecognizer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSSpeechRecognizer>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_recognizerFromUserdata_transfer(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSSpeechRecognizer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSSpeechRecognizer>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
}

// MARK: - Module Functions

/// hs.speech.listener.new([title]) -> recognizerObject
/// Constructor
/// Creates a new speech recognizer object for use by Cosmic Hammer.
///
/// Parameters:
///  * title - an optional parameter specifying the title under which commands assigned to this speech recognizer will be listed in the Dictation Commands display when it is visible.  Defaults to "Cosmic Hammer".
///
/// Returns:
///  * a speech recognizer object or nil, if the system was unable to create a new recognizer.
///
/// Notes:
///  * You can change the title later with the `hs.speech.listener:title` method.
private func newSpeechRecognizer(_ L: LuaState) throws -> CInt {
    var theTitle: String? = nil
    if lua_gettop(L) == 1 {
        _ = luaL_checkstring(L, 1)
        theTitle = lua_tovalue(L, at: 1) as? String
        if theTitle == nil { os_log(.info, "%{public}s", "unable to identify title from string, defaulting to \"Cosmic Hammer\"") }
    }

    guard let recognizer = HSSpeechRecognizer() else {
        lua_pushnil(L)
        return 1
    }
    if let title = theTitle {
        recognizer.displayedCommandsTitle = title
    }
    pushHSSpeechRecognizer(L, obj: recognizer)
    return 1
}

// MARK: - Module Object Methods

/// hs.speech.listener:commands([commandsArray]) -> recognizerObject | current value
/// Method
/// Get or set the commands this speech recognizer will listen for.
private func commands(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    if lua_gettop(L) == 2 {
        var theCommands: [String] = []
        let len = luaL_len(L, 2)
        for i in 0..<len {
            let type = lua_rawgeti(L, 2, i + 1)
            if type == LUA_TSTRING || type == LUA_TNUMBER {
                _ = luaL_checkstring(L, -1)
                if let cmd = lua_tovalue(L, at: -1) as? String {
                    theCommands.append(cmd)
                } else {
                    os_log(.info, "%{public}s", "invalid string evaluates to nil, skipping")
                }
            } else {
                os_log(.info, "%{public}s", "not a string or number value, skipping")
            }
            lua_pop(L, 1)
        }
        recognizer.commands = theCommands
        lua_pushvalue(L, 1)
    } else {
        lua_pushany(L, recognizer.commands as NSArray?)
    }
    return 1
}

/// hs.speech.listener:title([title]) -> recognizerObject | current value
/// Method
/// Get or set the title for a speech recognizer.
private func displayedCommandsTitle(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    if lua_gettop(L) == 2 {
        var theTitle: String? = nil
        if lua_type(L, 2) != LUA_TNIL {
            _ = luaL_checkstring(L, 2)
            theTitle = lua_tovalue(L, at: 2) as? String
        }
        recognizer.displayedCommandsTitle = theTitle ?? "Cosmic Hammer"
        lua_pushvalue(L, 1)
    } else {
        lua_pushany(L, recognizer.displayedCommandsTitle as NSString?)
    }
    return 1
}

/// hs.speech.listener:foregroundOnly([flag]) -> recognizerObject | current value
/// Method
/// Get or set whether or not the speech recognizer is active only when the Cosmic Hammer application is active.
private func listensInForegroundOnly(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    luaL_checkudata(L, 1, USERDATA_TAG)
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
private func blocksOtherRecognizers(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    luaL_checkudata(L, 1, USERDATA_TAG)
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
private func startListening(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    luaL_checkudata(L, 1, USERDATA_TAG)
    recognizer.startListening()
    recognizer.isListeningFlag = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech.listener:stop() -> recognizerObject
/// Method
/// Disables the speech recognizer.
private func stopListening(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    luaL_checkudata(L, 1, USERDATA_TAG)
    recognizer.stopListening()
    recognizer.isListeningFlag = false
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech.listener:isListening() -> boolean
/// Method
/// Returns a boolean value indicating whether or not the recognizer is currently enabled (started).
private func isListening(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    luaL_checkudata(L, 1, USERDATA_TAG)
    lua_pushboolean(L, recognizer.isListeningFlag ? 1 : 0)
    return 1
}

/// hs.speech.listener:setCallback(fn) -> recognizerObject
/// Method
/// Sets or removes a callback function for the speech recognizer.
private func setCallback(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    luaL_checkudata(L, 1, USERDATA_TAG)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, recognizer.callbackRef)

    recognizer.callbackRef = LUA_NOREF
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        recognizer.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

@discardableResult
private func pushHSSpeechRecognizer(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let recognizer = obj as! HSSpeechRecognizer

    if recognizer.selfRef == LUA_NOREF {
        let recognizerPtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
        recognizerPtr.storeBytes(of: Unmanaged.passRetained(recognizer).toOpaque(), as: UnsafeRawPointer.self)
        luaL_getmetatable(L, USERDATA_TAG)
        lua_setmetatable(L, -2)
        recognizer.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(recognizer.selfRef))
    return 1
}

// MARK: - Cosmic Hammer Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata(L, at: 1)
    let title = recognizer.displayedCommandsTitle ?? "Cosmic Hammer"
    let ptr = Unmanaged.passUnretained(recognizer).toOpaque()
    lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(ptr))")
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
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
private func userdata_gc(_ L: LuaState) throws -> CInt {
    let recognizer = get_recognizerFromUserdata_transfer(L, at: 1)

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, recognizer.callbackRef)


    recognizer.callbackRef = LUA_NOREF
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, recognizer.selfRef)

    recognizer.selfRef = LUA_NOREF
    recognizer.stopListening()
    recognizer.delegate = nil

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspeechlistener")
public func luaopen_hs_libspeechlistener(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(commands)
        lua_setfield(L, -2, "commands")
        L.push(displayedCommandsTitle)
        lua_setfield(L, -2, "title")
        L.push(listensInForegroundOnly)
        lua_setfield(L, -2, "foregroundOnly")
        L.push(blocksOtherRecognizers)
        lua_setfield(L, -2, "blocksOtherRecognizers")
        L.push(startListening)
        lua_setfield(L, -2, "start")
        L.push(stopListening)
        lua_setfield(L, -2, "stop")
        L.push(isListening)
        lua_setfield(L, -2, "isListening")
        L.push(setCallback)
        lua_setfield(L, -2, "setCallback")
        L.push(userdata_gc)
        lua_setfield(L, -2, "delete")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        lua_createtable(L, 0, 1)
        L.push(newSpeechRecognizer)
        lua_setfield(L, -2, "new")
    }
}
