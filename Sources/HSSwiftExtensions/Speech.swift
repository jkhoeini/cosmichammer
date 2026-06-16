import Cocoa
import CLua
import Lua
import HSDSTCore
import os.log

private let USERDATA_TAG = "hs.speech"

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
    var callback: LuaValue?
    /// Self-reference kept alive during speech to prevent GC while speaking.
    var selfRefValue: LuaValue?
    var generation: UInt64 = 0
    private var tornDown = false

    override init?(voice: NSSpeechSynthesizer.VoiceName?) {
        super.init(voice: voice)
        self.delegate = self
    }

    /// Idempotent teardown: stop speaking, drop Lua refs, clear delegate.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopSpeaking()
        callback = nil
        selfRefValue = nil
        delegate = nil
    }

    // MARK: - NSSpeechSynthesizerDelegate

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord wordToSpeak: NSRange, of text: String) {
        guard let synth = sender as? HSSpeechSynthesizer, !synth.tornDown else { return }
        guard lua_isStateGenerationValid(synth.generation) else {
            synth.teardown()
            return
        }
        guard let cb = synth.callback else { return }
        let _L = lua_getCurrentState()!
        let charMap = luaByteToObjCharMap(text)

        cb.push(onto: _L)
        _L.push(userdata: synth)
        _L.push("willSpeakWord")

        let luaStart = charMap.allKeys(for: NSNumber(value: wordToSpeak.location))
            .sorted { $0.compare($1) == .orderedAscending }
        let luaEnd = charMap.allKeys(for: NSNumber(value: NSMaxRange(wordToSpeak)))
            .sorted { $0.compare($1) == .orderedAscending }
        _L.push(lua_Integer(luaStart.last?.uintValue ?? 0))
        _L.push(lua_Integer((luaEnd.last?.uintValue ?? 1)) - 1)

        lua_pushany(_L, text as NSString)
        if lua_pcall(_L, 5, 0, 0) != LUA_OK { lua_pop(_L, 1) }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakPhoneme phonemeOpcode: Int16) {
        guard let synth = sender as? HSSpeechSynthesizer, !synth.tornDown else { return }
        guard lua_isStateGenerationValid(synth.generation) else {
            synth.teardown()
            return
        }
        guard let cb = synth.callback else { return }
        let _L = lua_getCurrentState()!

        cb.push(onto: _L)
        _L.push(userdata: synth)
        _L.push("willSpeakPhoneme")
        _L.push(lua_Integer(phonemeOpcode))
        if lua_pcall(_L, 3, 0, 0) != LUA_OK { lua_pop(_L, 1) }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didEncounterErrorAt characterIndex: Int, of text: String, message errorMessage: String) {
        os_log(.error, "In error delegate")
        guard let synth = sender as? HSSpeechSynthesizer, !synth.tornDown else { return }
        guard lua_isStateGenerationValid(synth.generation) else {
            synth.teardown()
            return
        }
        guard let cb = synth.callback else { return }
        let _L = lua_getCurrentState()!
        let charMap = luaByteToObjCharMap(text)

        cb.push(onto: _L)
        _L.push(userdata: synth)
        _L.push("didEncounterError")

        let index = charMap.allKeys(for: NSNumber(value: characterIndex))
            .sorted { $0.compare($1) == .orderedAscending }
        _L.push(lua_Integer(index.last?.uintValue ?? 0))

        lua_pushany(_L, text as NSString)
        lua_pushany(_L, errorMessage as NSString)
        if lua_pcall(_L, 5, 0, 0) != LUA_OK { lua_pop(_L, 1) }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didEncounterSyncMessage errorMessage: String) {
        guard let synth = sender as? HSSpeechSynthesizer, !synth.tornDown else { return }
        guard lua_isStateGenerationValid(synth.generation) else {
            synth.teardown()
            return
        }
        guard let cb = synth.callback else { return }
        let _L = lua_getCurrentState()!
        cb.push(onto: _L)
        _L.push(userdata: synth)
        _L.push("didEncounterSync")
        // "errorMessage" as a string seems to be broken or at least odd since at least as far back as 10.5:
        //      see https://openradar.appspot.com/6524554
        // We'll use "recentSync" property instead, though it does introduce the possibility of an error being generated.
        do {
            let syncValue = try sender.object(forProperty: NSSpeechSynthesizer.SpeechPropertyKey.recentSync)
            lua_pushany(_L, syncValue as? NSObject)
        } catch {
            lua_pushany(_L, nil as NSObject?)
            os_log(.info, "%{public}s", "Error getting sync # for callback -> \(error.localizedDescription)")
        }
        if lua_pcall(_L, 3, 0, 0) != LUA_OK { lua_pop(_L, 1) }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking success: Bool) {
        let synth = sender as! HSSpeechSynthesizer

        if !synth.tornDown, lua_isStateGenerationValid(synth.generation) {
            let _L = lua_getCurrentState()!
            if let cb = synth.callback {
                cb.push(onto: _L)
                _L.push(userdata: synth)
                _L.push("didFinish")
                _L.push(success)
                if lua_pcall(_L, 3, 0, 0) != LUA_OK { lua_pop(_L, 1) }
            }
        }
        // Release the self-reference that was keeping us alive during speech
        synth.selfRefValue = nil
    }
}

private func parseBoundary(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32, label: String) -> NSSpeechSynthesizer.Boundary {
    var boundary = NSSpeechSynthesizer.Boundary.immediateBoundary
    if lua_gettop(L) >= idx {
        _ = luaL_checkstring(L, idx)
        if let where_ = lua_tovalue(L, at: idx) as? String {
            switch where_ {
            case "immediate": boundary = .immediateBoundary
            case "word":      boundary = .wordBoundary
            case "sentence":  boundary = .sentenceBoundary
            default: os_log(.info, "%{public}s", "invalid boundary; \(label) immediately")
            }
        }
    }
    return boundary
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
    let displayFullName = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) != 0) : false
    let speech = environmentGet(L).speech

    lua_newtable(L)
    for voiceInfo in speech.availableVoices() {
        let voiceStr = voiceInfo.id
        if displayFullName {
            lua_pushany(L, voiceStr as NSString)
        } else {
            lua_pushany(L, (getVoiceShortCut(voiceStr) ?? voiceStr) as NSString)
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
    if lua_type(L, 1) != LUA_TNIL { _ = luaL_checkstring(L, 1) }
    let voiceName = lua_tovalue(L, at: 1) as? String
    let corrected = correctForVoiceShortCut(voiceName)
    let voiceNameObj = corrected.map { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
    lua_pushany(L, NSSpeechSynthesizer.attributes(forVoice: voiceNameObj!) as NSDictionary)
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
    let displayFullName = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) != 0) : false

    let voiceName = NSSpeechSynthesizer.defaultVoice.rawValue
    if displayFullName {
        lua_pushany(L, voiceName as NSString)
    } else {
        lua_pushany(L, (getVoiceShortCut(voiceName) ?? voiceName) as NSString)
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
    L.push(NSSpeechSynthesizer.isAnyApplicationSpeaking)
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
    var voiceName: NSSpeechSynthesizer.VoiceName? = nil
    if lua_gettop(L) == 1 {
        _ = luaL_checkstring(L, 1)
        if let str = lua_tovalue(L, at: 1) as? String {
            if let corrected = correctForVoiceShortCut(str) {
                voiceName = NSSpeechSynthesizer.VoiceName(rawValue: corrected)
            } else {
                os_log(.info, "%{public}s", "unable to identify voice from string, defaulting to system voice")
            }
        }
    }

    if let synth = HSSpeechSynthesizer(voice: voiceName) {
        synth.generation = lua_currentStateGeneration()
        L.push(userdata: synth)
    } else {
        os_log(.debug, "%{public}s", "unable to create synthesizer, returning nil")
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspeech")
public func luaopen_hs_libspeech(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSSpeechSynthesizer>
    L.register(Metatable<HSSpeechSynthesizer>(
        fields: [
            "usesFeedbackWindow": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    synth.usesFeedbackWindow = lua_toboolean(L, 2) != 0
                    lua_pushvalue(L, 1)
                } else {
                    L.push(synth.usesFeedbackWindow)
                }
                return 1
            },
            "voice": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 && lua_type(L, 2) != LUA_TBOOLEAN {
                    var voiceName: NSSpeechSynthesizer.VoiceName? = nil
                    if lua_type(L, 2) != LUA_TNIL {
                        _ = luaL_checkstring(L, 2)
                        if let str = lua_tovalue(L, at: 2) as? String {
                            if let corrected = correctForVoiceShortCut(str) {
                                voiceName = NSSpeechSynthesizer.VoiceName(rawValue: corrected)
                            } else {
                                os_log(.info, "%{public}s", "unable to identify voice from string, defaulting to system voice")
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
                        lua_pushany(L, currentVoice as NSString?)
                    } else {
                        lua_pushany(L, getVoiceShortCut(currentVoice) as NSString?)
                    }
                }
                return 1
            },
            "rate": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    synth.rate = Float(lua_tonumber(L, 2))
                    lua_pushvalue(L, 1)
                } else {
                    L.push(lua_Number(synth.rate))
                }
                return 1
            },
            "volume": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    let vol = Float(lua_tonumber(L, 2))
                    if vol < 0.0 || vol > 1.0 {
                        throw LuaCallError("bad argument #2 (must be between 0.0 and 1.0 inclusive)")
                    }
                    synth.volume = vol
                    lua_pushvalue(L, 1)
                } else {
                    L.push(lua_Number(synth.volume))
                }
                return 1
            },
            "speaking": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                L.push(synth.isSpeaking)
                return 1
            },
            "setCallback": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_type(L, 2) == LUA_TFUNCTION {
                    synth.callback = L.ref(index: 2)
                } else {
                    synth.callback = nil
                }
                lua_pushvalue(L, 1)
                return 1
            },
            "speak": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                _ = luaL_checkstring(L, 2)
                guard let theText = lua_tovalue(L, at: 2) as? String else {
                    throw LuaCallError("invalid speech text, evaluates to nil")
                }
                if synth.startSpeaking(theText) {
                    // Keep a self-reference to prevent GC during speech
                    if synth.selfRefValue == nil {
                        lua_pushvalue(L, 1)
                        synth.selfRefValue = L.ref(index: -1)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "speakToFile": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                _ = luaL_checkstring(L, 2)
                _ = luaL_checkstring(L, 3)
                guard let theText = lua_tovalue(L, at: 2) as? String else {
                    throw LuaCallError("invalid speech text, evaluates to nil")
                }
                guard let theFile = lua_tovalue(L, at: 3) as? String else {
                    throw LuaCallError("invalid file name, evaluates to nil")
                }
                let url = URL(fileURLWithPath: (theFile as NSString).expandingTildeInPath, isDirectory: false)
                if synth.startSpeaking(theText, to: url) {
                    if synth.selfRefValue == nil {
                        lua_pushvalue(L, 1)
                        synth.selfRefValue = L.ref(index: -1)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "pause": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                let boundary = parseBoundary(L, at: 2, label: "pausing")
                synth.pauseSpeaking(at: boundary)
                lua_pushvalue(L, 1)
                return 1
            },
            "continue": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                synth.continueSpeaking()
                lua_pushvalue(L, 1)
                return 1
            },
            "stop": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                let boundary = parseBoundary(L, at: 2, label: "stopping")
                synth.stopSpeaking(at: boundary)
                synth.selfRefValue = nil
                lua_pushvalue(L, 1)
                return 1
            },
            "phonemes": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                _ = luaL_checkstring(L, 2)
                guard let theText = lua_tovalue(L, at: 2) as? String else {
                    throw LuaCallError("invalid speech text, evaluates to nil")
                }
                lua_pushany(L, synth.phonemes(from: theText) as NSString)
                return 1
            },
            "isSpeaking": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                do {
                    let status = try synth.object(forProperty: .status) as? NSDictionary
                    if let result = status?[NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputBusy] as? NSNumber {
                        L.push(result.boolValue)
                    } else {
                        os_log(.info, "%{public}s", "Key \"\(NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputBusy)\" missing from synthesizer status")
                        lua_pushnil(L)
                    }
                } catch {
                    os_log(.info, "%{public}s", "Unable to query synthesizer status -> \(error.localizedDescription)")
                    lua_pushnil(L)
                }
                return 1
            },
            "isPaused": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                do {
                    let status = try synth.object(forProperty: .status) as? NSDictionary
                    if let result = status?[NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputPaused] as? NSNumber {
                        L.push(result.boolValue)
                    } else {
                        os_log(.info, "%{public}s", "Key \"\(NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputPaused)\" missing from synthesizer status")
                        lua_pushnil(L)
                    }
                } catch {
                    os_log(.info, "%{public}s", "Unable to query synthesizer status -> \(error.localizedDescription)")
                    lua_pushnil(L)
                }
                return 1
            },
            "phoneticSymbols": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                do {
                    let phoneticList = try synth.object(forProperty: .phonemeSymbols)
                    lua_pushany(L, phoneticList as? NSObject)
                } catch {
                    os_log(.info, "%{public}s", "Unable to query synthesizer for phonetic symbols -> \(error.localizedDescription)")
                    lua_pushnil(L)
                }
                return 1
            },
            "pitch": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    do {
                        try synth.setObject(NSNumber(value: lua_tonumber(L, 2)), forProperty: .pitchBase)
                        lua_pushvalue(L, 1)
                    } catch {
                        os_log(.info, "%{public}s", "Error setting pitchBase -> \(error.localizedDescription)")
                        lua_pushnil(L)
                    }
                } else {
                    do {
                        let value = try synth.object(forProperty: .pitchBase)
                        lua_pushany(L, value as? NSObject)
                    } catch {
                        lua_pushany(L, nil as NSObject?)
                        os_log(.info, "%{public}s", "Error getting pitchBase -> \(error.localizedDescription)")
                    }
                }
                return 1
            },
            "modulation": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    do {
                        try synth.setObject(NSNumber(value: lua_tonumber(L, 2)), forProperty: .pitchMod)
                        lua_pushvalue(L, 1)
                    } catch {
                        os_log(.info, "%{public}s", "Error setting pitchMod -> \(error.localizedDescription)")
                        lua_pushnil(L)
                    }
                } else {
                    do {
                        let value = try synth.object(forProperty: .pitchMod)
                        lua_pushany(L, value as? NSObject)
                    } catch {
                        lua_pushany(L, nil as NSObject?)
                        os_log(.info, "%{public}s", "Error getting pitchMod -> \(error.localizedDescription)")
                    }
                }
                return 1
            },
            "reset": .closure { L in
                let synth: HSSpeechSynthesizer = try L.checkArgument(1)
                do {
                    try synth.setObject(nil, forProperty: .reset)
                    lua_pushvalue(L, 1)
                } catch {
                    os_log(.info, "%{public}s", "Error resetting synthesizer -> \(error.localizedDescription)")
                    lua_pushnil(L)
                }
                return 1
            },
        ],
        tostring: .closure { L in
            let synth: HSSpeechSynthesizer = try L.checkArgument(1)
            let voiceName = synth.voice()?.rawValue ?? "unknown"
            L.push("\(USERDATA_TAG): \(voiceName) (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // Post-registration metatable patching
    L.pushMetatable(for: HSSpeechSynthesizer.self)

    // Replace __gc with explicit teardown + deinitialize
    L.push({ (L: LuaState!) -> CInt in
        if let synth: HSSpeechSynthesizer = L.touserdata(1) {
            synth.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    })
    lua_setfield(L, -2, "__gc")

    // __eq: compare the underlying objects
    L.push({ (L: LuaState!) -> CInt in
        if let synth1: HSSpeechSynthesizer = L.touserdata(1),
           let synth2: HSSpeechSynthesizer = L.touserdata(2) {
            L.push(synth1.isEqual(to: synth2))
        } else {
            L.push(false)
        }
        return 1
    })
    lua_setfield(L, -2, "__eq")

    // Set __type and __name
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 5)
    L.push(availableVoices)
    lua_setfield(L, -2, "availableVoices")
    L.push(attributesForVoice)
    lua_setfield(L, -2, "attributesForVoice")
    L.push(defaultVoice)
    lua_setfield(L, -2, "defaultVoice")
    L.push(isAnyApplicationSpeaking)
    lua_setfield(L, -2, "isAnyApplicationSpeaking")
    L.push(newSpeechSynthesizer)
    lua_setfield(L, -2, "new")

    return 1
}

// MARK: - Dictionary helper for allKeys(for:)

private extension Dictionary where Key == NSNumber, Value == NSNumber {
    func allKeys(for value: NSNumber) -> [NSNumber] {
        return self.filter { $0.value == value }.map { $0.key }
    }
}
