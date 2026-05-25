import Cocoa
import LuaSkin
import AVFoundation

private let USERDATA_TAG = "hs.sound"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions and Classes

private class HSSoundObject: NSObject, NSSoundDelegate {
    var soundObject: NSSound?
    var callbackRef: Int32 = LUA_NOREF
    var selfRef: Int32 = LUA_NOREF
    var stopOnRelease: Bool = true

    init(sound: NSSound) {
        self.soundObject = sound
        super.init()
        self.soundObject?.delegate = self
    }

    // MARK: - NSSoundDelegate methods

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)

            if self.callbackRef != LUA_NOREF {
                skin.pushLuaRef(refTable, ref: self.callbackRef)
                lua_pushboolean(L, flag ? 1 : 0)
                skin.pushNSObject(self)
                skin.protectedCallAndError("hs.sound:didFinishPlaying callback", nargs: 2, nresults: 0)
            }
            // a completed song should rely solely on user saved userdata values to prevent __gc
            // since there will be no other way to access it once this point is reached if it hasn't
            // been saved in a variable somewhere.
            self.selfRef = skin.luaUnref(refTable, ref: self.selfRef)
            _lua_stackguard_exit(L)
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
private func sound_getAudioEffectNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var description = AudioComponentDescription()
    description.componentType = kAudioUnitType_Effect
    description.componentSubType = 0
    description.componentManufacturer = 0
    description.componentFlags = 0
    description.componentFlagsMask = 0

    var component: AudioComponent? = nil
    var count: Int32 = 1

    lua_newtable(L)
    while true {
        component = AudioComponentFindNext(component, &description)
        guard let comp = component else { break }
        var name: Unmanaged<CFString>?
        AudioComponentCopyName(comp, &name)
        if let theName = name?.takeRetainedValue() as String? {
            lua_pushstring(L, theName)
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
private func sound_byname(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER, LS_TBREAK)
    luaL_checkstring(L, 1) // force number to be a string
    if let theSound = NSSound(named: NSSound.Name(skin.toNSObject(at: 1) as! String)) {
        skin.pushNSObject(theSound)
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
private func sound_byfile(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TNUMBER, LS_TBREAK)
    luaL_checkstring(L, 1) // force number to be a string
    if let theSound = NSSound(contentsOfFile: skin.toNSObject(at: 1) as! String, byReference: false) {
        skin.pushNSObject(theSound)
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
private func sound_systemSounds(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    var i: Int32 = 0

    lua_newtable(L)
    let librarySources = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .allDomainsMask, true)
    for sourcePath in librarySources {
        let soundsPath = (sourcePath as NSString).appendingPathComponent("Sounds")
        if let soundSource = FileManager.default.enumerator(atPath: soundsPath) {
            while let soundFile = soundSource.nextObject() as? String {
                let soundName = (soundFile as NSString).deletingPathExtension
                if NSSound(named: NSSound.Name(soundName)) != nil {
                    skin.pushNSObject(soundName as NSString)
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
private func sound_soundUnfilteredTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(NSSound.soundUnfilteredTypes as NSArray)
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
private func sound_soundUnfilteredFileTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    if NSSound.responds(to: Selector(("soundUnfilteredFileTypes"))) {
        if let types = NSSound.perform(Selector(("soundUnfilteredFileTypes")))?.takeUnretainedValue() as? NSArray {
            skin.pushNSObject(types)
        } else {
            lua_pushstring(L, "Deprecated selector soundUnfilteredFileTypes not supported in this OS X version.  Please use `hs.sound.soundTypes` instead.")
        }
    } else {
        lua_pushstring(L, "Deprecated selector soundUnfilteredFileTypes not supported in this OS X version.  Please use `hs.sound.soundTypes` instead.")
    }
    return 1
}

// MARK: - Module Methods

/// hs.sound:play() -> soundObject | bool
/// Method
/// Plays an `hs.sound` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.sound` object if the command was successful, otherwise false.
private func sound_play(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "HSSoundObject") as! HSSoundObject
    if obj.soundObject?.play() == true {
        lua_pushvalue(L, 1)
        if obj.selfRef == LUA_NOREF {
            lua_pushvalue(L, 1)
            obj.selfRef = skin.luaRef(refTable)
        }
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.sound:pause() -> soundObject | bool
/// Method
/// Pauses an `hs.sound` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.sound` object if the command was successful, otherwise false.
private func sound_pause(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if obj.pause() {
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.sound:resume() -> soundObject | bool
/// Method
/// Resumes playing a paused `hs.sound` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.sound` object if the command was successful, otherwise false.
private func sound_resume(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if obj.resume() {
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.sound:stop() -> soundObject | bool
/// Method
/// Stops playing an `hs.sound` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.sound` object if the command was successful, otherwise false.
private func sound_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if obj.stop() {
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.sound:loopSound([loop]) -> soundObject | bool
/// Method
/// Get or set the looping behaviour of an `hs.sound` object
///
/// Parameters:
///  * loop - An optional boolean, true to loop playback, false to not loop
///
/// Returns:
///  * If a parameter is provided, returns the sound object; otherwise returns the current setting.
///
/// Notes:
///  * If you have registered a callback function for completion of a sound's playback, it will not be called when the sound loops
private func sound_loopSound(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if lua_gettop(L) == 2 {
        obj.loops = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, obj.loops ? 1 : 0)
    }
    return 1
}

/// hs.sound:stopOnReload([stopOnReload]) -> soundObject | bool
/// Method
/// Get or set whether a sound should be stopped when Cosmic Hammer reloads its configuration
///
/// Parameters:
///  * stopOnReload - An optional boolean, true to stop playback when Cosmic Hammer reloads its config, false to continue playback regardless.  Defaults to true.
///
/// Returns:
///  * If a parameter is provided, returns the sound object; otherwise returns the current setting.
///
/// Notes:
///  * This method can only be used on a named `hs.sound` object, see `hs.sound:name()`
private func sound_stopOnRelease(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "HSSoundObject") as! HSSoundObject
    if lua_gettop(L) == 2 {
        if obj.soundObject?.name != nil {
            obj.stopOnRelease = lua_toboolean(L, 2) != 0
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "you must first assign a name to this sound in order to change this attribute")
        }
    } else {
        lua_pushboolean(L, obj.stopOnRelease ? 1 : 0)
    }
    return 1
}

/// hs.sound:name([soundName]) -> soundObject | name string
/// Method
/// Get or set the name of an `hs.sound` object
///
/// Parameters:
///  * soundName - An optional string to use as the name of the object; use an explicit nil to remove the name
///
/// Returns:
///  * If a parameter is provided, returns the sound object; otherwise returns the current setting.
///
/// Notes:
///  * If remove the sound name by specifying `nil`, the sound will automatically be set to stop when Cosmic Hammer is reloaded.
private func sound_name(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "HSSoundObject") as! HSSoundObject
    if lua_gettop(L) == 2 {
        if lua_isnil(L, 2) {
            obj.soundObject?.setName(nil)
            obj.stopOnRelease = true
        } else {
            obj.soundObject?.setName(NSSound.Name(skin.toNSObject(at: 2) as! String))
        }
        lua_pushvalue(L, 1)
    } else {
        if let name = obj.soundObject?.name {
            skin.pushNSObject(name as NSString)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.sound:device([deviceUID]) -> soundObject | UID string
/// Method
/// Get or set the playback device to use for an `hs.sound` object
///
/// Parameters:
///  * deviceUID - An optional string containing the UID of an `hs.audiodevice` object to use for playback of this sound. Use an explicit nil to use the system's default device
///
/// Returns:
///  * If a parameter is provided, returns the sound object; otherwise returns the current setting.
///
/// Notes:
///  * To obtain the UID of a sound device, see `hs.audiodevice:uid()`
private func sound_device(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if lua_gettop(L) == 2 {
        if lua_type(L, 2) == LUA_TNIL {
            obj.playbackDeviceIdentifier = nil
        } else {
            luaL_checkstring(L, 2)
            do {
                obj.playbackDeviceIdentifier = NSSound.PlaybackDeviceIdentifier(skin.toNSObject(at: 2) as! String)
            }
        }
        lua_pushvalue(L, 1)
    } else {
        if let identifier = obj.playbackDeviceIdentifier {
            skin.pushNSObject(identifier as NSString)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.sound:currentTime([seekTime]) -> soundObject | seconds
/// Method
/// Get or set the current seek offset within an `hs.sound` object.
///
/// Parameters:
///  * seekTime - An optional number of seconds to seek to within the sound object
///
/// Returns:
///  * If a parameter is provided, returns the sound object; otherwise returns the current position.
private func sound_currentTime(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if lua_gettop(L) == 2 {
        obj.currentTime = luaL_checknumber(L, 2)
        lua_pushvalue(L, 1)
    } else {
        lua_pushnumber(L, obj.currentTime)
    }
    return 1
}

/// hs.sound:duration() -> seconds
/// Method
/// Gets the length of an `hs.sound` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the length of the sound, in seconds
private func sound_duration(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    lua_pushnumber(L, obj.duration)
    return 1
}

/// hs.sound:volume([level]) -> soundObject | number
/// Method
/// Get or set the playback volume of an `hs.sound` object
///
/// Parameters:
///  * level - A number between 0.0 and 1.0, representing the volume of the sound object relative to the current system volume
///
/// Returns:
///  * If a parameter is provided, returns the sound object; otherwise returns the current value.
private func sound_volume(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    if lua_gettop(L) == 2 {
        obj.volume = Float(luaL_checknumber(L, 2))
        lua_pushvalue(L, 1)
    } else {
        lua_pushnumber(L, lua_Number(obj.volume))
    }
    return 1
}

/// hs.sound:isPlaying() -> bool
/// Method
/// Gets the current playback state of an `hs.sound` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the sound is currently playing, otherwise false
private func sound_isPlaying(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "NSSound") as! NSSound
    lua_pushboolean(L, obj.isPlaying ? 1 : 0)
    return 1
}

/// hs.sound:setCallback(function) -> soundObject
/// Method
/// Set or remove the callback for receiving completion notification for the sound object.
///
/// Parameters:
///  * function - A function which should be called when the sound completes playing.  Specify an explicit nil to remove the callback function.
///
/// Returns:
///  * the sound object
///
/// Notes:
///  * the callback function should accept two parameters and return none.  The parameters passed to the callback function are:
///    * state - a boolean flag indicating if the sound completed playing.  Returns true if playback completes properly, or false if a decoding error occurs or if the sound is stopped early with `hs.sound:stop`.
///    * sound - the soundObject userdata
private func sound_callback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let obj = skin.luaObject(at: 1, toClass: "HSSoundObject") as! HSSoundObject
    // in either case, we need to remove an existing callback, so...
    obj.callbackRef = skin.luaUnref(refTable, ref: obj.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        obj.callbackRef = skin.luaRef(refTable)
        if obj.selfRef == LUA_NOREF {
            lua_pushvalue(L, 1)
            obj.selfRef = skin.luaRef(refTable)
        }
    } else {
        if obj.soundObject?.isPlaying != true {
            obj.selfRef = skin.luaUnref(refTable, ref: obj.selfRef)
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

// pushes HSSoundObject userdata onto stack, or reuses selfRef, if defined
private func pushHSSoundObject(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let value = obj as! HSSoundObject
    if value.selfRef != LUA_NOREF {
        skin.pushLuaRef(refTable, ref: value.selfRef)
    } else {
        let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
        luaL_getmetatable(L, USERDATA_TAG)
        lua_setmetatable(L, -2)
    }
    return 1
}

// retrieves userdata on stack as HSSoundObject
private func toHSSoundObjectFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = lua_touserdata(L, idx)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<HSSoundObject>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        skin.logError("\(USERDATA_TAG) expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// creates new HSSoundObject from NSSound and pushes userdata onto stack
private func pushNSSound(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let value = HSSoundObject(sound: obj as! NSSound)
    return skin.pushNSObject(value)
}

// retrieves userdata on stack as HSSoundObject, but returns NSSound portion only
private func toNSSoundFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    let value = skin.luaObject(at: idx, toClass: "HSSoundObject") as! HSSoundObject
    return value.soundObject
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at: 1, toClass: "HSSoundObject") as! HSSoundObject
    let title = obj.soundObject?.name ?? "(unnamed sound)" as NSSound.Name
    skin.pushNSObject("\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "HSSoundObject") as! HSSoundObject
        let obj2 = skin.luaObject(at: 2, toClass: "HSSoundObject") as! HSSoundObject
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = lua_touserdata(L, 1)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj: HSSoundObject = Unmanaged.fromOpaque(rawPtr).takeRetainedValue()
        obj.selfRef = skin.luaUnref(refTable, ref: obj.selfRef)
        obj.callbackRef = skin.luaUnref(refTable, ref: obj.callbackRef)
        obj.soundObject?.delegate = nil
        if obj.stopOnRelease { obj.soundObject?.stop() }
        obj.soundObject = nil
        ptr.pointee = nil
    }
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Module Registration

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("play"), func: sound_play),
    luaL_Reg(name: strdup("pause"), func: sound_pause),
    luaL_Reg(name: strdup("resume"), func: sound_resume),
    luaL_Reg(name: strdup("stop"), func: sound_stop),
    luaL_Reg(name: strdup("loopSound"), func: sound_loopSound),
    luaL_Reg(name: strdup("name"), func: sound_name),
    luaL_Reg(name: strdup("volume"), func: sound_volume),
    luaL_Reg(name: strdup("currentTime"), func: sound_currentTime),
    luaL_Reg(name: strdup("duration"), func: sound_duration),
    luaL_Reg(name: strdup("device"), func: sound_device),
    luaL_Reg(name: strdup("stopOnReload"), func: sound_stopOnRelease),
    luaL_Reg(name: strdup("setCallback"), func: sound_callback),
    luaL_Reg(name: strdup("isPlaying"), func: sound_isPlaying),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("soundTypes"), func: sound_soundUnfilteredTypes),
    luaL_Reg(name: strdup("soundFileTypes"), func: sound_soundUnfilteredFileTypes),
    luaL_Reg(name: strdup("getByName"), func: sound_byname),
    luaL_Reg(name: strdup("getByFile"), func: sound_byfile),
    luaL_Reg(name: strdup("systemSounds"), func: sound_systemSounds),
    luaL_Reg(name: strdup("getAudioEffectNames"), func: sound_getAudioEffectNames),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libsound")
public func luaopen_hs_libsound(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(
        withObject: USERDATA_TAG,
        functions: &moduleLib,
        metaFunctions: nil,
        objectFunctions: &userdata_metaLib
    )

    // pushes HSSoundObject userdata onto stack, or reuses selfRef, if defined
    skin.registerPushNSHelper(pushHSSoundObject, forClass: "HSSoundObject")
    // retrieves userdata on stack as HSSoundObject
    skin.registerLuaObjectHelper(toHSSoundObjectFromLua, forClass: "HSSoundObject")

    // creates new HSSoundObject from NSSound and pushes userdata onto stack
    skin.registerPushNSHelper(pushNSSound, forClass: "NSSound")
    // retrieves userdata on stack as HSSoundObject, but returns NSSound portion only; also
    // makes this the default for the USERDATA type, since I doubt there will be much call
    // for HSSoundObject outside of this specific module, but may for NSSound in array's, etc.
    skin.registerLuaObjectHelper(toNSSoundFromLua, forClass: "NSSound", withUserdataMapping: USERDATA_TAG)

    return 1
}
