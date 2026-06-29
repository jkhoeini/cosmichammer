import HSDSTCore
import Cocoa
import CLua
import Lua
import Foundation
import os.log

/// === hs.audiodevice.watcher ===
///
/// Watch for system level audio hardware events

// MARK: - Library defines

// Define a datatype for hs.audiodevice.watcher objects
struct AudioDeviceWatcher {
    var running: Bool
    var listenerID: UInt64
    var lsCanary: UInt64
}

/// Module-level LuaValue for the single watcher callback.
private var watcherCallback: LuaValue? = nil

private var watcherRefTable: Int32 = 0
private var theWatcher: UnsafeMutablePointer<AudioDeviceWatcher>? = nil
private var activeAudioDeviceWatcherCount = 0

private func recordActiveAudioDeviceWatcherGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.audiodevice.watcher.active",
        kind: .gauge,
        value: Double(activeAudioDeviceWatcherCount),
        attributes: [:],
        unit: "1"
    )
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
private func audiodevicewatcher_setCallback(_ L: LuaState) throws -> CInt {

    if theWatcher == nil {
        theWatcher = UnsafeMutablePointer<AudioDeviceWatcher>.allocate(capacity: 1)
        theWatcher!.initialize(to: AudioDeviceWatcher(
            running: false,
            listenerID: 0,
            lsCanary: lua_currentStateGeneration()
        ))
    }

    watcherCallback = nil

    switch lua_type(L, 1) {
    case LUA_TFUNCTION:
        watcherCallback = L.ref(index: 1)
    case LUA_TNIL:
        _ = try audiodevicewatcher_stop(L)
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
private func audiodevicewatcher_start(_ L: LuaState) throws -> CInt {
    guard let watcher = theWatcher, watcherCallback != nil else {
        os_log(.error, "%{public}s", "You must call hs.audiodevice.watcher.setCallback() before hs.audiodevice.watcher.start()")
        return 0
    }

    if watcher.pointee.running {
        return 0
    }

    let audio = environmentGet(L).audio
    let lsCanary = watcher.pointee.lsCanary

    let listenerID = audio.addSystemAudioHardwareListener { eventName in
        environmentGetGlobalOrNil()?.eventLoop.async {
            let L = lua_getCurrentState()!

            guard let watcher = theWatcher else {
                os_log(.info, "%{public}s", "hs.audiodevice.watcher callback fired, but theWatcher is nil. This is a bug")
                return
            }

            if !lua_isStateGenerationValid(watcher.pointee.lsCanary) {
                return
            }

            guard let cb = watcherCallback else {
                os_log(.info, "%{public}s", "hs.audiodevice.watcher callback fired, but there is no callback. This is a bug")
                return
            }

            cb.push(onto: L)
            lua_pushany(L, eventName as NSString)
            if luaTelemetryPCall(
                L,
                nargs: 1,
                nresults: 0,
                callbackName: "hs.audiodevice.watcher",
                attributes: ["audio.event": eventName]
            ) != LUA_OK { lua_pop(L, 1) }
        }
    }

    watcher.pointee.listenerID = listenerID
    watcher.pointee.running = true
    activeAudioDeviceWatcherCount += 1
    recordActiveAudioDeviceWatcherGauge(L)

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
private func audiodevicewatcher_stop(_ L: LuaState) throws -> CInt {
    guard let watcher = theWatcher, watcher.pointee.running else {
        return 0
    }

    let audio = environmentGet(L).audio
    _ = audio.removeSystemAudioHardwareListener(id: watcher.pointee.listenerID)

    watcher.pointee.running = false
    watcher.pointee.listenerID = 0
    activeAudioDeviceWatcherCount = max(0, activeAudioDeviceWatcherCount - 1)
    recordActiveAudioDeviceWatcherGauge(L)

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
private func audiodevicewatcher_isRunning(_ L: LuaState) throws -> CInt {

    guard let watcher = theWatcher else {
        L.push(false)
        return 1
    }

    L.push(watcher.pointee.running)
    return 1
}

private func audiodevicewatcher_gc(_ L: LuaState) throws -> CInt {

    if let watcher = theWatcher {
        _ = try audiodevicewatcher_stop(L)
        watcherCallback = nil

        watcher.deinitialize(count: 1)
        watcher.deallocate()
        theWatcher = nil
    }

    return 0
}

// MARK: - Library initialisation

@_cdecl("luaopen_hs_libaudiodevicewatcher")
public func luaopen_hs_libaudiodevicewatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        watcherRefTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(audiodevicewatcher_setCallback)
        lua_setfield(L, -2, "setCallback")
        L.push(audiodevicewatcher_start)
        lua_setfield(L, -2, "start")
        L.push(audiodevicewatcher_stop)
        lua_setfield(L, -2, "stop")
        L.push(audiodevicewatcher_isRunning)
        lua_setfield(L, -2, "isRunning")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(audiodevicewatcher_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
