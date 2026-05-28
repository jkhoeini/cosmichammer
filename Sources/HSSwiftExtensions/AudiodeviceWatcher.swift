import Cocoa
import Carbon
import CoreAudio
import AudioToolbox
import Foundation
import LuaSkin

/// === hs.audiodevice.watcher ===
///
/// Watch for system level audio hardware events

// MARK: - Library defines

// Define a datatype for hs.audiodevice.watcher objects
struct AudioDeviceWatcher {
    var callback: Int32
    var running: Bool
    var lsCanary: LSGCCanary
}

private let watcherWatchSelectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice,
]

private var watcherRefTable: LSRefTable = 0
private var theWatcher: UnsafeMutablePointer<AudioDeviceWatcher>? = nil

// MARK: - CoreAudio helper functions

private func audiodevicewatcher_callback(
    deviceID: AudioDeviceID,
    numAddresses: UInt32,
    addressList: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    var events: [String] = []
    for i in 0..<numAddresses {
        let selectorString = UTCreateStringForOSType(addressList[Int(i)].mSelector).takeRetainedValue() as String
        events.append(selectorString)
    }

    DispatchQueue.main.async {
        let skin = LuaSkin.skin(with: nil)

        guard let watcher = theWatcher else {
            skin.logWarn("hs.audiodevice.watcher callback fired, but theWatcher is nil. This is a bug")
            return
        }

        if !skin.check(watcher.pointee.lsCanary) {
            return
        }
        _lua_stackguard_entry(skin.l)

        if watcher.pointee.callback == LUA_NOREF {
            skin.logWarn("hs.audiodevice.watcher callback fired, but there is no callback. This is a bug")
        } else {
            for event in events {
                skin.pushLuaRef(watcherRefTable, ref: watcher.pointee.callback)
                skin.pushNSObject(event as NSString)
                skin.protectedCallAndError("hs.audiodevice.watcher callback", nargs: 1, nresults: 0)
            }
        }
        _lua_stackguard_exit(skin.l)
    }
    return noErr
}

// MARK: - hs.audiodevice.watcher library functions

/// hs.audiodevice.watcher.setCallback(fn)
/// Function
/// Sets the callback function for the audio device watcher
///
/// Parameters:
///  * fn - A callback function, or nil to remove a previously set callback. The callback function should accept a single argument (see Notes below)
///
/// Returns:
///  * None
///
/// Notes:
///  * This watcher will call the callback when various audio device related events occur (e.g. an audio device appears/disappears, a system default audio device setting changes, etc)
///  * To watch for changes within an audio device, see `hs.audiodevice:newWatcher()`
///  * The callback function argument is a string which may be one of the following strings, but might also be a different string entirely:
///   * dIn  - Default audio input device setting changed (Note that there is a space character after `dIn`, because these values always have to be four characters long)
///   * dOut - Default audio output device setting changed
///   * sOut - Default system audio output setting changed (i.e. the device that system sound effects use. This may also be triggered by dOut, depending on the user's settings)
///   * dev# - An audio device appeared or disappeared
///  * The callback will be called for each individual audio device event received from the OS, so you may receive multiple events for a single physical action (e.g. unplugging the default audio device will cause `dOut` and `dev#` events, and possibly `sOut` too)
///  * Passing nil will cause the watcher to stop if it is already running
private func audiodevicewatcher_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION | LS_TNIL, LS_TBREAK)

    if theWatcher == nil {
        theWatcher = UnsafeMutablePointer<AudioDeviceWatcher>.allocate(capacity: 1)
        theWatcher!.initialize(to: AudioDeviceWatcher(
            callback: LUA_NOREF,
            running: false,
            lsCanary: skin.createGCCanary()
        ))
    }

    theWatcher!.pointee.callback = skin.luaUnref(watcherRefTable, ref: theWatcher!.pointee.callback)

    switch lua_type(L, 1) {
    case LUA_TFUNCTION:
        lua_pushvalue(L, 1)
        theWatcher!.pointee.callback = skin.luaRef(watcherRefTable)
    case LUA_TNIL:
        _ = audiodevicewatcher_stop(L)
    default:
        break
    }

    return 0
}

/// hs.audiodevice.watcher.start()
/// Function
/// Starts the audio device watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func audiodevicewatcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    guard let watcher = theWatcher, watcher.pointee.callback != LUA_NOREF else {
        skin.logError("You must call hs.audiodevice.watcher.setCallback() before hs.audiodevice.watcher.start()")
        return 0
    }

    if watcher.pointee.running {
        return 0
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: 0,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    for selector in watcherWatchSelectors {
        propertyAddress.mSelector = selector
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, audiodevicewatcher_callback, nil)
    }

    watcher.pointee.running = true

    return 0
}

/// hs.audiodevice.watcher.stop() -> hs.audiodevice.watcher
/// Function
/// Stops the audio device watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.audiodevice.watcher` object
private func audiodevicewatcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let watcher = theWatcher, watcher.pointee.running else {
        return 0
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: 0,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard
    )

    for selector in watcherWatchSelectors {
        propertyAddress.mSelector = selector
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, audiodevicewatcher_callback, nil)
    }

    watcher.pointee.running = false

    return 0
}

/// hs.audiodevice.watcher.isRunning() -> boolean
/// Function
/// Gets the status of the audio device watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the watcher is running, false if not
private func audiodevicewatcher_isRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    guard let watcher = theWatcher else {
        lua_pushboolean(L, 0)
        return 1
    }

    lua_pushboolean(L, watcher.pointee.running ? 1 : 0)
    return 1
}

private func audiodevicewatcher_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    if let watcher = theWatcher {
        _ = audiodevicewatcher_stop(L)
        watcher.pointee.callback = skin.luaUnref(watcherRefTable, ref: watcher.pointee.callback)
        skin.destroy(&watcher.pointee.lsCanary)
        watcher.deinitialize(count: 1)
        watcher.deallocate()
        theWatcher = nil
    }

    return 0
}

// MARK: - Library initialisation

// Metatable for audiodevice watcher objects
private var audiodevicewatcherLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("setCallback"),             func: audiodevicewatcher_setCallback),
    luaL_Reg(name: strdup("start"),                   func: audiodevicewatcher_start),
    luaL_Reg(name: strdup("stop"),                    func: audiodevicewatcher_stop),
    luaL_Reg(name: strdup("isRunning"),               func: audiodevicewatcher_isRunning),
    luaL_Reg(name: nil, func: nil),
]

private var watcherMetaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"),                    func: audiodevicewatcher_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libaudiodevicewatcher")
public func luaopen_hs_libaudiodevicewatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    watcherRefTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Create module table
    lua_createtable(L, 0, Int32(audiodevicewatcherLib.count - 1))
    luaL_setfuncs(L, &audiodevicewatcherLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(watcherMetaLib.count - 1))
    luaL_setfuncs(L, &watcherMetaLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
