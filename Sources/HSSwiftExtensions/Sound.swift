import Cocoa
import CLua
import Lua
import os.log
import AVFoundation

private let USERDATA_TAG = "hs.sound"

/// TigerStyle: maximum audio components to enumerate before bailing out.
private let kMaxAudioComponents = 1_000

/// TigerStyle: maximum sound file entries to enumerate per directory search.
private let kMaxSoundFileEntries = 10_000

// MARK: - Support Functions and Classes

private class HSSoundObject: NSObject, NSSoundDelegate {
    var soundObject: NSSound?
    var callback: LuaValue?
    var selfRef: Int32 = LUA_NOREF
    var stopOnRelease: Bool = true
    var generation: UInt64 = 0
    private var tornDown = false

    init(sound: NSSound) {
        self.soundObject = sound
        super.init()
        self.soundObject?.delegate = self
    }

    /// Idempotent teardown: stop the sound, drop callback, release self-ref.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        callback = nil
        soundObject?.delegate = nil
        if stopOnRelease { soundObject?.stop() }
        soundObject = nil
    }

    // MARK: - NSSoundDelegate methods

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard lua_isStateGenerationValid(self.generation) else {
                self.teardown()
                return
            }
            let L = lua_getCurrentState()!

            if let cb = self.callback {
                cb.push(onto: L)
                L.push(flag)
                // Push the selfRef userdata so the Lua callback receives the same identity
                if self.selfRef != LUA_NOREF {
                    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(self.selfRef))
                } else {
                    lua_pushnil(L)
                }
                if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
            }
            // a completed song should rely solely on user saved userdata values to prevent __gc
            // since there will be no other way to access it once this point is reached if it hasn't
            // been saved in a variable somewhere.
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, self.selfRef)
            self.selfRef = LUA_NOREF
        }
    }
}

// MARK: - Module Functions

/// hs.sound.getAudioEffectNames() -> table
/// Function
/// Gets a table of installed Audio Units Effect names.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the names of all installed Audio Units Effects.
///
/// Notes:
///  * Example usage: `hs.inspect(hs.audiounit.getAudioEffectNames())`
private func sound_getAudioEffectNames(_ L: LuaState) throws -> CInt {
    var description = AudioComponentDescription()
    description.componentType = kAudioUnitType_Effect
    description.componentSubType = 0
    description.componentManufacturer = 0
    description.componentFlags = 0
    description.componentFlagsMask = 0

    var component: AudioComponent? = nil
    var count: Int32 = 1

    lua_newtable(L)
    // TigerStyle: bounded loop — cap iterations to prevent unbounded enumeration
    var componentIter = 0
    while true {
        component = AudioComponentFindNext(component, &description)
        guard let comp = component else { break }
        componentIter += 1
        if componentIter > kMaxAudioComponents {
            os_log(.error, "hs.sound: audio component enumeration exceeded %d entries — breaking", kMaxAudioComponents)
            break
        }
        var name: Unmanaged<CFString>?
        AudioComponentCopyName(comp, &name)
        if let theName = name?.takeRetainedValue() as String? {
            L.push(theName)
            lua_rawseti(L, -2, lua_Integer(count))
            count += 1
        }
    }
    return 1
}

/// hs.sound.getByName(name) -> sound or nil
/// Constructor
/// Creates an `hs.sound` object from a named sound
///
/// Parameters:
///  * name - A string containing the name of a sound
///
/// Returns:
///  * An `hs.sound` object or nil if no matching sound could be found
///
/// Notes:
///  * Sounds can only be loaded by name if they are System Sounds (i.e. those found in ~/Library/Sounds, /Library/Sounds, /Network/Library/Sounds and /System/Library/Sounds) or are sound files that have previously been loaded and named
private func sound_byname(_ L: LuaState) throws -> CInt {
    _ = luaL_checkstring(L, 1) // force number to be a string
    if let theSound = NSSound(named: NSSound.Name(lua_tovalue(L, at: 1) as! String)) {
        let value = HSSoundObject(sound: theSound)
        value.generation = lua_currentStateGeneration()
        L.push(userdata: value)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sound.getByFile(path) -> sound or nil
/// Constructor
/// Creates an `hs.sound` object from a file
///
/// Parameters:
///  * path - A string containing the path to a sound file
///
/// Returns:
///  * An `hs.sound` object or nil if the file could not be loaded
private func sound_byfile(_ L: LuaState) throws -> CInt {
    _ = luaL_checkstring(L, 1) // force number to be a string
    if let theSound = NSSound(contentsOfFile: lua_tovalue(L, at: 1) as! String, byReference: false) {
        let value = HSSoundObject(sound: theSound)
        value.generation = lua_currentStateGeneration()
        L.push(userdata: value)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sound.systemSounds() -> table
/// Function
/// Gets a table of available system sounds
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing all of the available sound files (i.e. those found in ~/Library/Sounds, /Library/Sounds, /Network/Library/Sounds and /System/Library/Sounds)
///
/// Notes:
///  * The sounds listed by this function can be loaded using `hs.sound.getByName()`
private func sound_systemSounds(_ L: LuaState) throws -> CInt {
    var i: Int32 = 0

    lua_newtable(L)
    let librarySources = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .allDomainsMask, true)
    for sourcePath in librarySources {
        let soundsPath = (sourcePath as NSString).appendingPathComponent("Sounds")
        if let soundSource = FileManager.default.enumerator(atPath: soundsPath) {
            // TigerStyle: bounded directory traversal
            var soundEntryCount = 0
            while let soundFile = soundSource.nextObject() as? String {
                soundEntryCount += 1
                if soundEntryCount > kMaxSoundFileEntries {
                    os_log(.error, "hs.sound: sound file enumeration exceeded %d entries in %{public}s — breaking", kMaxSoundFileEntries, soundsPath)
                    break
                }
                let soundName = (soundFile as NSString).deletingPathExtension
                if NSSound(named: NSSound.Name(soundName)) != nil {
                    lua_pushany(L, soundName as NSString)
                    i += 1
                    lua_rawseti(L, -2, lua_Integer(i))
                }
            }
        }
    }
    return 1
}

/// hs.sound.soundTypes() -> table
/// Function
/// Gets the supported UTI sound file formats
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the UTI sound formats that are supported by the system
private func sound_soundUnfilteredTypes(_ L: LuaState) throws -> CInt {
    lua_pushany(L, NSSound.soundUnfilteredTypes as NSArray)
    return 1
}

/// hs.sound.soundFileTypes() -> table
/// Function
/// Gets the supported sound file types
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the sound file filename extensions that are supported by the system
///
/// Notes:
///  * This function is unlikely to be tremendously useful, as filename extensions are essentially meaningless. The data returned by `hs.sound.soundTypes()` is far more valuable
private func sound_soundUnfilteredFileTypes(_ L: LuaState) throws -> CInt {
    if NSSound.responds(to: Selector(("soundUnfilteredFileTypes"))) {
        if let types = catchingObjCException({
            NSSound.perform(Selector(("soundUnfilteredFileTypes")))?.takeUnretainedValue() as? NSArray
        }) {
            lua_pushany(L, types)
        } else {
            L.push("Deprecated selector soundUnfilteredFileTypes not supported in this OS X version.  Please use `hs.sound.soundTypes` instead.")
        }
    } else {
        L.push("Deprecated selector soundUnfilteredFileTypes not supported in this OS X version.  Please use `hs.sound.soundTypes` instead.")
    }
    return 1
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libsound")
public func luaopen_hs_libsound(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSSoundObject> with LuaSwift.
    L.register(Metatable<HSSoundObject>(
        fields: [
            "play": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if obj.soundObject?.play() == true {
                    lua_pushvalue(L, 1)
                    if obj.selfRef == LUA_NOREF {
                        lua_pushvalue(L, 1)
                        obj.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
                    }
                } else {
                    L.push(false)
                }
                return 1
            },
            "pause": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if obj.soundObject?.pause() == true {
                    lua_pushvalue(L, 1)
                } else {
                    L.push(false)
                }
                return 1
            },
            "resume": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if obj.soundObject?.resume() == true {
                    lua_pushvalue(L, 1)
                } else {
                    L.push(false)
                }
                return 1
            },
            "stop": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if obj.soundObject?.stop() == true {
                    // Release selfRef so a stopped sound can be GC'd
                    // (looping sounds never fire didFinishPlaying)
                    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.selfRef)
                    obj.selfRef = LUA_NOREF
                    lua_pushvalue(L, 1)
                } else {
                    L.push(false)
                }
                return 1
            },
            "loopSound": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    obj.soundObject?.loops = lua_toboolean(L, 2) != 0
                    lua_pushvalue(L, 1)
                } else {
                    L.push(obj.soundObject?.loops == true)
                }
                return 1
            },
            "stopOnReload": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    if obj.soundObject?.name != nil {
                        obj.stopOnRelease = lua_toboolean(L, 2) != 0
                        lua_pushvalue(L, 1)
                    } else {
                        throw LuaCallError("you must first assign a name to this sound in order to change this attribute")
                    }
                } else {
                    L.push(obj.stopOnRelease)
                }
                return 1
            },
            "name": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    if lua_isnil(L, 2) {
                        obj.soundObject?.setName(nil)
                        obj.stopOnRelease = true
                    } else {
                        obj.soundObject?.setName(NSSound.Name(lua_tovalue(L, at: 2) as! String))
                    }
                    lua_pushvalue(L, 1)
                } else {
                    if let name = obj.soundObject?.name {
                        lua_pushany(L, name as NSString)
                    } else {
                        lua_pushnil(L)
                    }
                }
                return 1
            },
            "device": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                guard let sound = obj.soundObject else {
                    lua_pushnil(L)
                    return 1
                }
                if lua_gettop(L) == 2 {
                    if lua_type(L, 2) == LUA_TNIL {
                        sound.playbackDeviceIdentifier = nil
                    } else {
                        _ = luaL_checkstring(L, 2)
                        sound.playbackDeviceIdentifier = NSSound.PlaybackDeviceIdentifier(lua_tovalue(L, at: 2) as! String)
                    }
                    lua_pushvalue(L, 1)
                } else {
                    if let identifier = sound.playbackDeviceIdentifier {
                        lua_pushany(L, identifier as NSString)
                    } else {
                        lua_pushnil(L)
                    }
                }
                return 1
            },
            "currentTime": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                guard let sound = obj.soundObject else {
                    lua_pushnil(L)
                    return 1
                }
                if lua_gettop(L) == 2 {
                    sound.currentTime = luaL_checknumber(L, 2)
                    lua_pushvalue(L, 1)
                } else {
                    L.push(sound.currentTime)
                }
                return 1
            },
            "duration": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                L.push(obj.soundObject?.duration ?? 0)
                return 1
            },
            "volume": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                guard let sound = obj.soundObject else {
                    lua_pushnil(L)
                    return 1
                }
                if lua_gettop(L) == 2 {
                    sound.volume = Float(luaL_checknumber(L, 2))
                    lua_pushvalue(L, 1)
                } else {
                    L.push(lua_Number(sound.volume))
                }
                return 1
            },
            "isPlaying": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                L.push(obj.soundObject?.isPlaying == true)
                return 1
            },
            "setCallback": .closure { L in
                let obj: HSSoundObject = try L.checkArgument(1)
                if lua_type(L, 2) == LUA_TFUNCTION {
                    obj.callback = L.ref(index: 2)
                    if obj.selfRef == LUA_NOREF {
                        lua_pushvalue(L, 1)
                        obj.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
                    }
                } else {
                    obj.callback = nil
                    if obj.soundObject?.isPlaying != true {
                        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.selfRef)
                        obj.selfRef = LUA_NOREF
                    }
                }
                lua_pushvalue(L, 1)
                return 1
            },
        ],
        eq: .closure { L in
            let obj1: HSSoundObject = try L.checkArgument(1)
            let obj2: HSSoundObject = try L.checkArgument(2)
            L.push(obj1.isEqual(obj2))
            return 1
        },
        tostring: .closure { L in
            let obj: HSSoundObject = try L.checkArgument(1)
            let title = obj.soundObject?.name ?? "(unnamed sound)" as NSSound.Name
            lua_pushany(L, "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))" as NSString)
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // Replace LuaSwift's default __gc with custom teardown + deinitialize
    L.pushMetatable(for: HSSoundObject.self)

    L.push({ (L: LuaState!) -> CInt in
        if let obj: HSSoundObject = L.touserdata(1) {
            // Release the self-ref while L is still alive
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.selfRef)
            obj.selfRef = LUA_NOREF
            obj.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        rawptr.assumingMemoryBound(to: Any.self).deinitialize(count: 1)
        return 0
    })
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertions
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Registry alias so core_getObjectMetatable("hs.sound") resolves
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 6)
    L.push(sound_soundUnfilteredTypes)
    lua_setfield(L, -2, "soundTypes")
    L.push(sound_soundUnfilteredFileTypes)
    lua_setfield(L, -2, "soundFileTypes")
    L.push(sound_byname)
    lua_setfield(L, -2, "getByName")
    L.push(sound_byfile)
    lua_setfield(L, -2, "getByFile")
    L.push(sound_systemSounds)
    lua_setfield(L, -2, "systemSounds")
    L.push(sound_getAudioEffectNames)
    lua_setfield(L, -2, "getAudioEffectNames")

    return 1
}
