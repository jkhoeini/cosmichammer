import Cocoa
import CLua
import Lua
import HSDSTCore
import os.log

private let USERDATA_TAG = "hs.speech.listener"

// MARK: - HSSpeechRecognizer Definition

/// Handle wrapper for a speech recognizer managed by SpeechProtocol.
/// Does NOT subclass NSSpeechRecognizer -- the real recognizer lives
/// inside the protocol implementation (ProductionSpeech / SimulatedSpeech).
private class HSSpeechRecognizer: NSObject {
    /// Protocol handle. Zero until :start() creates the listener.
    var handle: UInt64 = 0
    var callback: LuaValue?
    var selfRefValue: LuaValue?
    var isListeningFlag: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    // Deferred configuration (set before :start() creates the protocol listener)
    var storedTitle: String = "Cosmic Hammer"
    var storedCommands: [String] = []
    var storedForegroundOnly: Bool = true
    var storedBlocksOtherRecognizers: Bool = false

    override init() {
        super.init()
    }

    /// Idempotent teardown: stop listening, drop Lua refs.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if handle != 0, let env = environmentGetGlobalOrNil() {
            _ = env.speech.stopListening(listenerID: handle)
            handle = 0
        }
        callback = nil
        selfRefValue = nil
    }

    var isTornDown: Bool { tornDown }
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
private func newSpeechRecognizer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var theTitle: String? = nil
    if lua_gettop(L) == 1 {
        _ = luaL_checkstring(L, 1)
        theTitle = lua_tovalue(L, at: 1) as? String
        if theTitle == nil { os_log(.info, "%{public}s", "unable to identify title from string, defaulting to \"Cosmic Hammer\"") }
    }

    let recognizer = HSSpeechRecognizer()
    if let title = theTitle {
        recognizer.storedTitle = title
    }
    recognizer.generation = lua_currentStateGeneration()
    L.push(userdata: recognizer)
    return 1
}

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspeechlistener")
public func luaopen_hs_libspeechlistener(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSSpeechRecognizer>
    L.register(Metatable<HSSpeechRecognizer>(
        fields: [
            "commands": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                let speech = environmentGet(L).speech
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
                    recognizer.storedCommands = theCommands
                    if recognizer.handle != 0 {
                        speech.listenerSetCommands(listenerID: recognizer.handle,
                                                   commands: theCommands)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    if recognizer.handle != 0,
                       let cmds = speech.listenerCommands(listenerID: recognizer.handle) {
                        lua_pushany(L, cmds as NSArray)
                    } else {
                        lua_pushany(L, recognizer.storedCommands as NSArray?)
                    }
                }
                return 1
            },
            "title": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                let speech = environmentGet(L).speech
                if lua_gettop(L) == 2 {
                    var theTitle: String? = nil
                    if lua_type(L, 2) != LUA_TNIL {
                        _ = luaL_checkstring(L, 2)
                        theTitle = lua_tovalue(L, at: 2) as? String
                    }
                    let title = theTitle ?? "Cosmic Hammer"
                    recognizer.storedTitle = title
                    if recognizer.handle != 0 {
                        speech.listenerSetTitle(listenerID: recognizer.handle, title: title)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    if recognizer.handle != 0 {
                        let title = speech.listenerTitle(listenerID: recognizer.handle)
                        lua_pushany(L, (title ?? recognizer.storedTitle) as NSString?)
                    } else {
                        lua_pushany(L, recognizer.storedTitle as NSString?)
                    }
                }
                return 1
            },
            "foregroundOnly": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                let speech = environmentGet(L).speech
                if lua_gettop(L) == 2 {
                    let value = lua_toboolean(L, 2) != 0
                    recognizer.storedForegroundOnly = value
                    if recognizer.handle != 0 {
                        speech.listenerSetForegroundOnly(listenerID: recognizer.handle,
                                                         value: value)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    if recognizer.handle != 0 {
                        L.push(speech.listenerForegroundOnly(listenerID: recognizer.handle))
                    } else {
                        L.push(recognizer.storedForegroundOnly)
                    }
                }
                return 1
            },
            "blocksOtherRecognizers": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                let speech = environmentGet(L).speech
                if lua_gettop(L) == 2 {
                    let value = lua_toboolean(L, 2) != 0
                    recognizer.storedBlocksOtherRecognizers = value
                    if recognizer.handle != 0 {
                        speech.listenerSetBlocksOtherRecognizers(
                            listenerID: recognizer.handle, value: value)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    if recognizer.handle != 0 {
                        L.push(speech.listenerBlocksOtherRecognizers(
                            listenerID: recognizer.handle))
                    } else {
                        L.push(recognizer.storedBlocksOtherRecognizers)
                    }
                }
                return 1
            },
            "start": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                let speech = environmentGet(L).speech

                // If we already have a live handle, stop it first
                if recognizer.handle != 0 {
                    _ = speech.stopListening(listenerID: recognizer.handle)
                    recognizer.handle = 0
                }

                // Create a new listener through the protocol
                let callback: (String) -> Void = { [weak recognizer] command in
                    guard let recognizer = recognizer, !recognizer.isTornDown else { return }
                    guard lua_isStateGenerationValid(recognizer.generation) else {
                        recognizer.teardown()
                        return
                    }
                    guard let cb = recognizer.callback else { return }
                    let _L = lua_getCurrentState()!
                    cb.push(onto: _L)
                    _L.push(userdata: recognizer)
                    lua_pushany(_L, command as NSString)
                    if luaTelemetryPCall(
                        _L,
                        nargs: 2,
                        nresults: 0,
                        callbackName: "hs.speech.listener",
                        attributes: [
                            "speech.command.count": recognizer.storedCommands.count,
                            "speech.command.length": command.count,
                        ]
                    ) != LUA_OK { lua_pop(_L, 1) }
                }

                guard let handle = speech.startListening(
                    commands: recognizer.storedCommands,
                    callback: callback) else {
                    lua_pushnil(L)
                    return 1
                }

                recognizer.handle = handle
                recognizer.isListeningFlag = true

                // Apply deferred config
                speech.listenerSetTitle(listenerID: handle, title: recognizer.storedTitle)
                speech.listenerSetForegroundOnly(listenerID: handle,
                                                  value: recognizer.storedForegroundOnly)
                speech.listenerSetBlocksOtherRecognizers(
                    listenerID: handle, value: recognizer.storedBlocksOtherRecognizers)

                // Hold a self-reference while actively listening
                if recognizer.selfRefValue == nil {
                    lua_pushvalue(L, 1)
                    recognizer.selfRefValue = L.ref(index: -1)
                    lua_pop(L, 1)
                }
                lua_pushvalue(L, 1)
                return 1
            },
            "stop": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                let speech = environmentGet(L).speech
                if recognizer.handle != 0 {
                    _ = speech.stopListening(listenerID: recognizer.handle)
                    recognizer.handle = 0
                }
                recognizer.isListeningFlag = false
                recognizer.selfRefValue = nil
                lua_pushvalue(L, 1)
                return 1
            },
            "isListening": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                L.push(recognizer.isListeningFlag)
                return 1
            },
            "setCallback": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                if lua_type(L, 2) == LUA_TFUNCTION {
                    recognizer.callback = L.ref(index: 2)
                } else {
                    recognizer.callback = nil
                }
                lua_pushvalue(L, 1)
                return 1
            },
            "delete": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                recognizer.teardown()
                return 0
            },
        ],
        tostring: .closure { L in
            let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
            L.push("\(USERDATA_TAG): \(recognizer.storedTitle) (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // Post-registration metatable patching
    L.pushMetatable(for: HSSpeechRecognizer.self)

    // Replace __gc with explicit teardown + deinitialize
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let recognizer: HSSpeechRecognizer = L.touserdata(1) {
            recognizer.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // __eq: compare the underlying handles
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let rec1: HSSpeechRecognizer = L.touserdata(1),
           let rec2: HSSpeechRecognizer = L.touserdata(2) {
            L.push(rec1 === rec2)
        } else {
            L.push(false)
        }
        return 1
    }, 0)
    lua_setfield(L, -2, "__eq")

    // Set __type and __name
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 1)
    L.push(newSpeechRecognizer)
    lua_setfield(L, -2, "new")

    return 1
}
