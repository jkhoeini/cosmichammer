import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.speech.listener"

// MARK: - HSSpeechRecognizer Definition

private class HSSpeechRecognizer: NSSpeechRecognizer, NSSpeechRecognizerDelegate {
    var callback: LuaValue?
    var selfRefValue: LuaValue?
    var isListeningFlag: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    override init?() {
        super.init()
        self.isListeningFlag = false
        self.delegate = self
    }

    /// Idempotent teardown: stop listening, drop Lua refs, clear delegate.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopListening()
        callback = nil
        selfRefValue = nil
        delegate = nil
    }

    // MARK: - NSSpeechRecognizerDelegate

    func speechRecognizer(_ sender: NSSpeechRecognizer, didRecognizeCommand command: String) {
        guard let recognizer = sender as? HSSpeechRecognizer else { return }
        guard !recognizer.tornDown else { return }
        guard lua_isStateGenerationValid(recognizer.generation) else {
            recognizer.teardown()
            return
        }
        guard let cb = recognizer.callback else { return }
        let L = lua_getCurrentState()!

        cb.push(onto: L)
        L.push(userdata: recognizer)
        lua_pushany(L, command as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
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

    guard let recognizer = HSSpeechRecognizer() else {
        lua_pushnil(L)
        return 1
    }
    if let title = theTitle {
        recognizer.displayedCommandsTitle = title
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
            },
            "title": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
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
            },
            "foregroundOnly": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    recognizer.listensInForegroundOnly = lua_toboolean(L, 2) != 0
                    lua_pushvalue(L, 1)
                } else {
                    lua_pushboolean(L, recognizer.listensInForegroundOnly ? 1 : 0)
                }
                return 1
            },
            "blocksOtherRecognizers": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    recognizer.blocksOtherRecognizers = lua_toboolean(L, 2) != 0
                    lua_pushvalue(L, 1)
                } else {
                    lua_pushboolean(L, recognizer.blocksOtherRecognizers ? 1 : 0)
                }
                return 1
            },
            "start": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                recognizer.startListening()
                recognizer.isListeningFlag = true
                // Hold a self-reference while actively listening to
                // prevent GC from collecting the recognizer.
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
                recognizer.stopListening()
                recognizer.isListeningFlag = false
                // Release self-reference so the object can be GC'd
                recognizer.selfRefValue = nil
                lua_pushvalue(L, 1)
                return 1
            },
            "isListening": .closure { L in
                let recognizer: HSSpeechRecognizer = try L.checkArgument(1)
                lua_pushboolean(L, recognizer.isListeningFlag ? 1 : 0)
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
            let title = recognizer.displayedCommandsTitle ?? "Cosmic Hammer"
            lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
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

    // __eq: compare the underlying objects
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let rec1: HSSpeechRecognizer = L.touserdata(1),
           let rec2: HSSpeechRecognizer = L.touserdata(2) {
            lua_pushboolean(L, rec1.isEqual(to: rec2) ? 1 : 0)
        } else {
            lua_pushboolean(L, 0)
        }
        return 1
    }, 0)
    lua_setfield(L, -2, "__eq")

    // Set __type and __name
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 1)
    L.push(newSpeechRecognizer)
    lua_setfield(L, -2, "new")

    return 1
}
