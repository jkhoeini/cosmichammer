import Cocoa
import LuaSkin
import os.log

private let USERDATA_TAG = "hs.speech"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions

/// Lua treats strings (and therefore indexes within strings) as a sequence of bytes.  Objective-C's
/// NSString and NSAttributedString treat them as a sequence of characters.  This works fine until
/// Unicode characters are involved.
///
/// This function creates a dictionary mapping of this where the keys are the byte positions in the
/// Lua string and the values are the corresponding character positions in the NSString.
private func luaByteToObjCharMap(_ theString: String) -> [NSNumber: NSNumber] {
    var luaByteToObjChar: [NSNumber: NSNumber] = [:]
    guard let rawString = theString.data(using: .utf8) else { return luaByteToObjChar }

    var luaPos: UInt = 1
    var objCPos: UInt = 0

    while (luaPos - 1) < rawString.count {
        let thisByte = rawString[Data.Index(luaPos - 1)]
        luaByteToObjChar[NSNumber(value: luaPos)] = NSNumber(value: objCPos)
        if (thisByte >= 0x00 && thisByte <= 0x7F) || (thisByte >= 0xC0) {
            objCPos += 1
        }
        luaPos += 1
    }
    return luaByteToObjChar
}

/// All (that I've seen) voices start with "com.apple.speech.synthesis.voice."... this is annoying to type,
/// so this allows us to leave it off and will add it if necessary.
private let appleVoicePrefix = "com.apple.speech.synthesis.voice."

private func correctForVoiceShortCut(_ theVoice: String?) -> String? {
    guard let voice = theVoice else { return nil }
    if !voice.hasPrefix(appleVoicePrefix) {
        return appleVoicePrefix + voice
    }
    return voice
}

private func getVoiceShortCut(_ theVoice: String?) -> String? {
    guard let voice = theVoice else { return nil }
    if voice.hasPrefix(appleVoicePrefix) {
        return String(voice[voice.index(voice.startIndex, offsetBy: appleVoicePrefix.count)...])
    }
    return voice
}

// MARK: - HSSpeechSynthesizer Definition

private class HSSpeechSynthesizer: NSSpeechSynthesizer, NSSpeechSynthesizerDelegate {
    var callbackRef: Int32 = LUA_NOREF
    var selfRef: Int32 = LUA_NOREF
    var udReferenceCount: Int32 = 0

    override init?(voice: NSSpeechSynthesizer.VoiceName?) {
        super.init(voice: voice)
        self.callbackRef = LUA_NOREF
        self.selfRef = LUA_NOREF
        self.udReferenceCount = 0
        self.delegate = self
    }

    // MARK: - NSSpeechSynthesizerDelegate

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord wordToSpeak: NSRange, of text: String) {
        guard let synth = sender as? HSSpeechSynthesizer, synth.callbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        let _L = skin.l!
        _lua_stackguard_entry(_L)
        let charMap = luaByteToObjCharMap(text)

        skin.pushLuaRef(refTable, ref: synth.callbackRef)
        skin.pushNSObject(synth)
        lua_pushstring(_L, "willSpeakWord")

        let luaStart = charMap.allKeys(for: NSNumber(value: wordToSpeak.location))
            .sorted { $0.compare($1) == .orderedAscending }
        let luaEnd = charMap.allKeys(for: NSNumber(value: NSMaxRange(wordToSpeak)))
            .sorted { $0.compare($1) == .orderedAscending }
        lua_pushinteger(_L, lua_Integer(luaStart.last?.uintValue ?? 0))
        lua_pushinteger(_L, lua_Integer((luaEnd.last?.uintValue ?? 1)) - 1)

        skin.pushNSObject(text as NSString)
        skin.protectedCallAndError("hs.speech:willSpeakWord callback", nargs: 5, nresults: 0)
        _lua_stackguard_exit(_L)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakPhoneme phonemeOpcode: Int16) {
        guard let synth = sender as? HSSpeechSynthesizer, synth.callbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        let _L = skin.l!
        _lua_stackguard_entry(_L)

        skin.pushLuaRef(refTable, ref: synth.callbackRef)
        skin.pushNSObject(synth)
        lua_pushstring(_L, "willSpeakPhoneme")
        lua_pushinteger(_L, lua_Integer(phonemeOpcode))
        skin.protectedCallAndError("hs.speech:willSpeakPhoneme callback", nargs: 3, nresults: 0)
        _lua_stackguard_exit(_L)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didEncounterErrorAt characterIndex: Int, of text: String, message errorMessage: String) {
        os_log(.error, "In error delegate")
        guard let synth = sender as? HSSpeechSynthesizer, synth.callbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        let _L = skin.l!
        _lua_stackguard_entry(_L)
        let charMap = luaByteToObjCharMap(text)

        skin.pushLuaRef(refTable, ref: synth.callbackRef)
        skin.pushNSObject(synth)
        lua_pushstring(_L, "didEncounterError")

        let index = charMap.allKeys(for: NSNumber(value: characterIndex))
            .sorted { $0.compare($1) == .orderedAscending }
        lua_pushinteger(_L, lua_Integer(index.last?.uintValue ?? 0))

        skin.pushNSObject(text as NSString)
        skin.pushNSObject(errorMessage as NSString)
        skin.protectedCallAndError("hs.speech:didEncounterError callback", nargs: 5, nresults: 0)
        _lua_stackguard_exit(_L)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didEncounterSyncMessage errorMessage: String) {
        guard let synth = sender as? HSSpeechSynthesizer, synth.callbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        let _L = skin.l!
        _lua_stackguard_entry(_L)
        skin.pushLuaRef(refTable, ref: synth.callbackRef)
        skin.pushNSObject(synth)
        lua_pushstring(_L, "didEncounterSync")
        // "errorMessage" as a string seems to be broken or at least odd since at least as far back as 10.5:
        //      see https://openradar.appspot.com/6524554
        // We'll use "recentSync" property instead, though it does introduce the possibility of an error being generated.
        do {
            let syncValue = try sender.object(forProperty: NSSpeechSynthesizer.SpeechPropertyKey.recentSync)
            skin.pushNSObject(syncValue as? NSObject)
        } catch {
            skin.pushNSObject(nil as NSObject?)
            skin.logWarn("Error getting sync # for callback -> \(error.localizedDescription)")
        }
        skin.protectedCallAndError("hs.speech:didEncounterSync callback", nargs: 3, nresults: 0)
        _lua_stackguard_exit(_L)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking success: Bool) {
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        let synth = sender as! HSSpeechSynthesizer

        if synth.callbackRef != LUA_NOREF {
            let _L = skin.l!
            skin.pushLuaRef(refTable, ref: synth.callbackRef)
            skin.pushNSObject(synth)
            lua_pushstring(_L, "didFinish")
            lua_pushboolean(_L, success ? 1 : 0)
            skin.protectedCallAndError("hs.speech:didFinish callback", nargs: 3, nresults: 0)
        }
        if synth.selfRef != LUA_NOREF {
            synth.udReferenceCount -= 1
            synth.selfRef = skin.luaUnref(refTable, ref: synth.selfRef)
        }
        _lua_stackguard_exit(skin.l)
    }
}

// MARK: - Helpers

private func get_synthFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSSpeechSynthesizer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSSpeechSynthesizer>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_synthFromUserdata_transfer(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSSpeechSynthesizer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSSpeechSynthesizer>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
}

// MARK: - Module Functions

/// hs.speech.availableVoices([full]) -> array
/// Function
/// Returns a list of the currently installed voices for speech synthesis.
///
/// Parameters:
///  * full - an optional boolean flag indicating whether or not the full internal names should be returned, or if the shorter versions should be returned.  Defaults to false.
///
/// Returns:
///  * an array of the available voice names.
///
/// Notes:
///  * All of the names that have been encountered thus far follow this pattern for their full name:  `com.apple.speech.synthesis.voice.*name*`.  This prefix is normally suppressed unless you pass in true.
private func availableVoices(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let displayFullName = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) != 0) : false

    lua_newtable(L)
    for aVoice in NSSpeechSynthesizer.availableVoices {
        let voiceStr = aVoice.rawValue
        if displayFullName {
            skin.pushNSObject(voiceStr as NSString)
        } else {
            skin.pushNSObject((getVoiceShortCut(voiceStr) ?? voiceStr) as NSString)
        }
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

/// hs.speech.attributesForVoice(voice) -> table
/// Function
/// Returns a table containing a variety of properties describing and defining the specified voice.
///
/// Parameters:
///  * voice - the name of the voice to look up attributes for
///
/// Returns:
///  * a table containing key-value pairs which describe the voice specified.  These attributes may include (but is not limited to) information about specific characters recognized, sample text, gender, etc.
///
/// Notes:
///  * All of the names that have been encountered thus far follow this pattern for their full name:  `com.apple.speech.synthesis.voice.*name*`.  You can provide this suffix or not as you prefer when specifying a voice name.
private func attributesForVoice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER | LS_TNIL, LS_TBREAK)

    if lua_type(L, 1) != LUA_TNIL { _ = luaL_checkstring(L, 1) }
    let voiceName = skin.toNSObject(atIndex: 1) as? String
    let corrected = correctForVoiceShortCut(voiceName)
    let voiceNameObj = corrected.map { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
    skin.pushNSObject(NSSpeechSynthesizer.attributes(forVoice: voiceNameObj!) as NSDictionary)
    return 1
}

/// hs.speech.defaultVoice([full]) -> string
/// Function
/// Returns the name of the currently selected default voice for the user.  This voice is the voice selected in the System Preferences for Dictation & Speech as the System Voice.
///
/// Parameters:
///  * full - an optional boolean flag indicating whether or not the full internal name should be returned, or if the shorter version should be returned.  Defaults to false.
///
/// Returns:
///  * the name of the system voice.
///
/// Notes:
///  * All of the names that have been encountered thus far follow this pattern for their full name:  `com.apple.speech.synthesis.voice.*name*`.  This prefix is normally suppressed unless you pass in true.
private func defaultVoice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let displayFullName = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) != 0) : false

    let voiceName = NSSpeechSynthesizer.defaultVoice.rawValue
    if displayFullName {
        skin.pushNSObject(voiceName as NSString)
    } else {
        skin.pushNSObject((getVoiceShortCut(voiceName) ?? voiceName) as NSString)
    }
    return 1
}

/// hs.speech.isAnyApplicationSpeaking() -> boolean
/// Function
/// Returns whether or not the system is currently using a speech synthesizer in any application to generate speech.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not any application is currently generating speech with a synthesizer.
///
/// Notes:
///  * See also `hs.speech:speaking`.
private func isAnyApplicationSpeaking(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    lua_pushboolean(L, NSSpeechSynthesizer.isAnyApplicationSpeaking ? 1 : 0)
    return 1
}

/// hs.speech.new([voice]) -> synthesizerObject
/// Constructor
/// Creates a new speech synthesizer object for use by Cosmic Hammer.
///
/// Parameters:
///  * voice - an optional string specifying the voice the synthesizer should use for generating speech.  Defaults to the system voice.
///
/// Returns:
///  * a speech synthesizer object or nil, if the system was unable to create a new synthesizer.
///
/// Notes:
///  * All of the names that have been encountered thus far follow this pattern for their full name:  `com.apple.speech.synthesis.voice.*name*`.  You can provide this suffix or not as you prefer when specifying a voice name.
///  * You can change the voice later with the `hs.speech:voice` method.
private func newSpeechSynthesizer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    var voiceName: NSSpeechSynthesizer.VoiceName? = nil
    if lua_gettop(L) == 1 {
        _ = luaL_checkstring(L, 1)
        if let str = skin.toNSObject(atIndex: 1) as? String {
            if let corrected = correctForVoiceShortCut(str) {
                voiceName = NSSpeechSynthesizer.VoiceName(rawValue: corrected)
            } else {
                skin.logWarn("unable to identify voice from string, defaulting to system voice")
            }
        }
    }

    if let synth = HSSpeechSynthesizer(voice: voiceName) {
        skin.pushNSObject(synth)
    } else {
        skin.logDebug("unable to create synthesizer, returning nil")
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Module Object Methods

/// hs.speech:usesFeedbackWindow([flag]) -> synthesizerObject | boolean
/// Method
/// Gets or sets whether or not the synthesizer uses the speech feedback window.
private func usesFeedbackWindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    if lua_gettop(L) == 2 {
        synth.usesFeedbackWindow = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, synth.usesFeedbackWindow ? 1 : 0)
    }
    return 1
}

/// hs.speech:voice([full] | [voice]) -> synthesizerObject | voice
/// Method
/// Gets or sets the active voice for a synthesizer.
private func voice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TSTRING | LS_TNUMBER | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    if lua_gettop(L) == 2 && lua_type(L, 2) != LUA_TBOOLEAN {
        var voiceName: NSSpeechSynthesizer.VoiceName? = nil
        if lua_type(L, 2) != LUA_TNIL {
            _ = luaL_checkstring(L, 2)
            if let str = skin.toNSObject(atIndex: 2) as? String {
                if let corrected = correctForVoiceShortCut(str) {
                    voiceName = NSSpeechSynthesizer.VoiceName(rawValue: corrected)
                } else {
                    skin.logWarn("unable to identify voice from string, defaulting to system voice")
                }
            }
        }
        if synth.setVoice(voiceName) {
            lua_pushvalue(L, 1)
        } else {
            lua_pushnil(L)
        }
    } else {
        let displayFullName = lua_isboolean(L, 2) ? (lua_toboolean(L, 2) != 0) : false
        let currentVoice = synth.voice()?.rawValue
        if displayFullName {
            skin.pushNSObject(currentVoice as NSString?)
        } else {
            skin.pushNSObject(getVoiceShortCut(currentVoice) as NSString?)
        }
    }
    return 1
}

/// hs.speech:rate([rate]) -> synthesizerObject | rate
/// Method
/// Gets or sets the synthesizers speaking rate (words per minute).
private func rate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    if lua_gettop(L) == 2 {
        synth.rate = Float(lua_tonumber(L, 2))
        lua_pushvalue(L, 1)
    } else {
        lua_pushnumber(L, lua_Number(synth.rate))
    }
    return 1
}

/// hs.speech:volume([volume]) -> synthesizerObject | volume
/// Method
/// Gets or sets the synthesizers speaking volume.
private func volume(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    if lua_gettop(L) == 2 {
        let vol = Float(lua_tonumber(L, 2))
        if vol < 0.0 || vol > 1.0 {
            luaL_argerror(L, 2, "must be between 0.0 and 1.0 inclusive")
            return 0
        }
        synth.volume = vol
        lua_pushvalue(L, 1)
    } else {
        lua_pushnumber(L, lua_Number(synth.volume))
    }
    return 1
}

/// hs.speech:speaking() -> boolean
/// Method
/// Returns whether or not this synthesizer is currently generating speech.
private func speaking(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    lua_pushboolean(L, synth.isSpeaking ? 1 : 0)
    return 1
}

/// hs.speech:setCallback(fn) -> synthesizerObject
/// Method
/// Sets or removes a callback function for the synthesizer.
private func setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    synth.callbackRef = skin.luaUnref(refTable, ref: synth.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        synth.callbackRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech:speak(textToSpeak) -> synthesizerObject
/// Method
/// Starts speaking the provided text through the system's current audio device.
private func startSpeakingString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    _ = luaL_checkstring(L, 2)
    guard let theText = skin.toNSObject(atIndex: 2) as? String else {
        luaL_error(L, "invalid speech text, evaluates to nil")
        return 0
    }

    if synth.startSpeaking(theText) {
        lua_pushvalue(L, 1)
        if synth.selfRef == LUA_NOREF {
            synth.udReferenceCount += 1
            synth.selfRef = skin.luaRef(refTable)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.speech:speakToFile(textToSpeak, destination) -> synthesizerObject
/// Method
/// Starts speaking the provided text and saves the audio as an AIFF file.
private func startSpeakingStringToURL(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER, LS_TSTRING | LS_TNUMBER, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    _ = luaL_checkstring(L, 2)
    _ = luaL_checkstring(L, 3)
    guard let theText = skin.toNSObject(atIndex: 2) as? String else {
        luaL_error(L, "invalid speech text, evaluates to nil")
        return 0
    }
    guard let theFile = skin.toNSObject(atIndex: 3) as? String else {
        luaL_error(L, "invalid file name, evaluates to nil")
        return 0
    }

    let url = URL(fileURLWithPath: (theFile as NSString).expandingTildeInPath, isDirectory: false)
    if synth.startSpeaking(theText, to: url) {
        lua_pushvalue(L, 1)
        if synth.selfRef == LUA_NOREF {
            synth.udReferenceCount += 1
            synth.selfRef = skin.luaRef(refTable)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func parseBoundary(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32, skin: LuaSkin, label: String) -> NSSpeechSynthesizer.Boundary {
    var boundary = NSSpeechSynthesizer.Boundary.immediateBoundary
    if lua_gettop(L) >= idx {
        _ = luaL_checkstring(L, idx)
        if let where_ = skin.toNSObject(atIndex: idx) as? String {
            switch where_ {
            case "immediate": boundary = .immediateBoundary
            case "word":      boundary = .wordBoundary
            case "sentence":  boundary = .sentenceBoundary
            default: skin.logWarn("invalid boundary; \(label) immediately")
            }
        }
    }
    return boundary
}

/// hs.speech:pause([where]) -> synthesizerObject
/// Method
/// Pauses the output of the speech synthesizer.
private func pauseSpeakingAtBoundary(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    let boundary = parseBoundary(L, at: 2, skin: skin, label: "pausing")
    synth.pauseSpeaking(at: boundary)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech:stop([where]) -> synthesizerObject
/// Method
/// Stops the output of the speech synthesizer.
private func stopSpeakingAtBoundary(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    let boundary = parseBoundary(L, at: 2, skin: skin, label: "stopping")
    synth.stopSpeaking(at: boundary)
    if synth.selfRef != LUA_NOREF {
        synth.udReferenceCount -= 1
        synth.selfRef = skin.luaUnref(refTable, ref: synth.selfRef)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech:continue() -> synthesizerObject
/// Method
/// Resumes a paused speech synthesizer.
private func continueSpeaking(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    synth.continueSpeaking()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.speech:phonemes(text) -> string
/// Method
/// Returns the phonemes which would be spoken if the text were to be synthesized.
private func phonemesFromText(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    _ = luaL_checkstring(L, 2)
    guard let theText = skin.toNSObject(atIndex: 2) as? String else {
        luaL_error(L, "invalid speech text, evaluates to nil")
        return 0
    }
    skin.pushNSObject(synth.phonemes(from: theText) as NSString)
    return 1
}

/// hs.speech:isSpeaking() -> boolean | nil
/// Method
/// Returns whether or not the synthesizer is currently speaking, either to an audio device or to a file.
private func isSpeaking(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    do {
        let status = try synth.object(forProperty: .status) as? NSDictionary
        if let result = status?[NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputBusy] as? NSNumber {
            lua_pushboolean(L, result.boolValue ? 1 : 0)
        } else {
            skin.logInfo("Key \"\(NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputBusy)\" missing from synthesizer status")
            lua_pushnil(L)
        }
    } catch {
        skin.logInfo("Unable to query synthesizer status -> \(error.localizedDescription)")
        lua_pushnil(L)
    }
    return 1
}

/// hs.speech:isPaused() -> boolean | nil
/// Method
/// Returns whether or not the synthesizer is currently paused.
private func isPaused(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    do {
        let status = try synth.object(forProperty: .status) as? NSDictionary
        if let result = status?[NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputPaused] as? NSNumber {
            lua_pushboolean(L, result.boolValue ? 1 : 0)
        } else {
            skin.logInfo("Key \"\(NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputPaused)\" missing from synthesizer status")
            lua_pushnil(L)
        }
    } catch {
        skin.logInfo("Unable to query synthesizer status -> \(error.localizedDescription)")
        lua_pushnil(L)
    }
    return 1
}

/// hs.speech:phoneticSymbols() -> array | nil
/// Method
/// Returns an array of the phonetic symbols recognized by the synthesizer for the current voice.
private func phoneticSymbols(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    do {
        let phoneticList = try synth.object(forProperty: .phonemeSymbols)
        skin.pushNSObject(phoneticList as? NSObject)
    } catch {
        skin.logInfo("Unable to query synthesizer for phonetic symbols -> \(error.localizedDescription)")
        lua_pushnil(L)
    }
    return 1
}

/// hs.speech:pitch([pitch]) -> synthesizerObject | pitch | nil
/// Method
/// Gets or sets the base pitch for the synthesizer's voice.
private func pitchBase(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    if lua_gettop(L) == 2 {
        do {
            try synth.setObject(NSNumber(value: lua_tonumber(L, 2)), forProperty: .pitchBase)
            lua_pushvalue(L, 1)
        } catch {
            skin.logWarn("Error setting pitchBase -> \(error.localizedDescription)")
            lua_pushnil(L)
        }
    } else {
        do {
            let value = try synth.object(forProperty: .pitchBase)
            skin.pushNSObject(value as? NSObject)
        } catch {
            skin.pushNSObject(nil as NSObject?)
            skin.logInfo("Error getting pitchBase -> \(error.localizedDescription)")
        }
    }
    return 1
}

/// hs.speech:modulation([modulation]) -> synthesizerObject | modulation | nil
/// Method
/// Gets or sets the pitch modulation for the synthesizer's voice.
private func pitchMod(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    if lua_gettop(L) == 2 {
        do {
            try synth.setObject(NSNumber(value: lua_tonumber(L, 2)), forProperty: .pitchMod)
            lua_pushvalue(L, 1)
        } catch {
            skin.logWarn("Error setting pitchMod -> \(error.localizedDescription)")
            lua_pushnil(L)
        }
    } else {
        do {
            let value = try synth.object(forProperty: .pitchMod)
            skin.pushNSObject(value as? NSObject)
        } catch {
            skin.pushNSObject(nil as NSObject?)
            skin.logInfo("Error getting pitchMod -> \(error.localizedDescription)")
        }
    }
    return 1
}

/// hs.speech:reset() -> synthesizerObject | nil
/// Method
/// Reset a synthesizer back to its default state.
private func reset(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let synth = get_synthFromUserdata(L, at: 1)

    do {
        try synth.setObject(nil, forProperty: .reset)
        lua_pushvalue(L, 1)
    } catch {
        skin.logWarn("Error resetting synthesizer -> \(error.localizedDescription)")
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSSpeechSynthesizer(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let synth = obj as! HSSpeechSynthesizer
    synth.udReferenceCount += 1
    let synthPtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    synthPtr.storeBytes(of: Unmanaged.passRetained(synth).toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

// MARK: - Cosmic Hammer Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let synth = get_synthFromUserdata(L, at: 1)
    let skin = LuaSkin.skin(with: L)
    let voiceName = synth.voice()?.rawValue ?? "unknown"
    let ptr = Unmanaged.passUnretained(synth).toOpaque()
    lua_pushstring(L, "\(USERDATA_TAG): \(voiceName) (\(ptr))")
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let synth1 = get_synthFromUserdata(L, at: 1)
        let synth2 = get_synthFromUserdata(L, at: 2)
        lua_pushboolean(L, synth1.isEqual(to: synth2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let synth = get_synthFromUserdata_transfer(L, at: 1)
    let skin = LuaSkin.skin(with: L)
    synth.udReferenceCount -= 1

    if synth.udReferenceCount == 0 {
        synth.callbackRef = skin.luaUnref(refTable, ref: synth.callbackRef)
        if synth.selfRef != LUA_NOREF {
            synth.selfRef = skin.luaUnref(refTable, ref: synth.selfRef)
        }
        synth.delegate = nil
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - luaL_Reg tables

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("usesFeedbackWindow"), func: usesFeedbackWindow),
    luaL_Reg(name: strdup("voice"), func: voice),
    luaL_Reg(name: strdup("rate"), func: rate),
    luaL_Reg(name: strdup("volume"), func: volume),
    luaL_Reg(name: strdup("speaking"), func: speaking),
    luaL_Reg(name: strdup("setCallback"), func: setCallback),
    luaL_Reg(name: strdup("speak"), func: startSpeakingString),
    luaL_Reg(name: strdup("speakToFile"), func: startSpeakingStringToURL),
    luaL_Reg(name: strdup("pause"), func: pauseSpeakingAtBoundary),
    luaL_Reg(name: strdup("continue"), func: continueSpeaking),
    luaL_Reg(name: strdup("stop"), func: stopSpeakingAtBoundary),
    luaL_Reg(name: strdup("phonemes"), func: phonemesFromText),
    luaL_Reg(name: strdup("isSpeaking"), func: isSpeaking),
    luaL_Reg(name: strdup("isPaused"), func: isPaused),
    luaL_Reg(name: strdup("phoneticSymbols"), func: phoneticSymbols),
    luaL_Reg(name: strdup("pitch"), func: pitchBase),
    luaL_Reg(name: strdup("modulation"), func: pitchMod),
    luaL_Reg(name: strdup("reset"), func: reset),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil)
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("availableVoices"), func: availableVoices),
    luaL_Reg(name: strdup("attributesForVoice"), func: attributesForVoice),
    luaL_Reg(name: strdup("defaultVoice"), func: defaultVoice),
    luaL_Reg(name: strdup("isAnyApplicationSpeaking"), func: isAnyApplicationSpeaking),
    luaL_Reg(name: strdup("new"), func: newSpeechSynthesizer),
    luaL_Reg(name: nil, func: nil)
]

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspeech")
public func luaopen_hs_libspeech(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    return 1
}

// MARK: - Dictionary helper for allKeys(for:)

private extension Dictionary where Key == NSNumber, Value == NSNumber {
    func allKeys(for value: NSNumber) -> [NSNumber] {
        return self.filter { $0.value == value }.map { $0.key }
    }
}
