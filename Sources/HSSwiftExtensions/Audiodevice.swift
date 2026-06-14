import Cocoa
import CLua
import Lua
import Carbon
import CoreAudio
import AudioToolbox
import Foundation
import os.log

// MARK: - Library defines

private let USERDATA_TAG = "hs.audiodevice"
private let USERDATA_DATASOURCE_TAG = "hs.audiodevice.datasource"

// Define a datatype for hs.audiodevice objects
struct AudioDeviceUserData {
    var deviceId: AudioDeviceID
    var watcherRunning: Bool
    var lsCanary: UInt64
}

/// Side-table mapping each userdata pointer to its per-device watcher callback.
/// We cannot store a LuaValue (ARC-managed) inside the raw C struct allocated by
/// lua_newuserdata, so we keep callbacks in a separate dictionary keyed by the
/// userdata address.
private var deviceCallbacks: [UnsafeMutableRawPointer: LuaValue] = [:]

// Define a datatype for hs.audiodevice.datasource objects
struct DataSourceUserData {
    var hostDevice: AudioDeviceID
    var dataSource: UInt32
}

private func userdataToAudioDevice(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<AudioDeviceUserData> {
    return luaL_checkudata(L, idx, USERDATA_TAG).assumingMemoryBound(to: AudioDeviceUserData.self)
}

private func userdataToDataSource(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<DataSourceUserData> {
    return luaL_checkudata(L, idx, USERDATA_DATASOURCE_TAG).assumingMemoryBound(to: DataSourceUserData.self)
}

private let watchSelectors: [AudioObjectPropertySelector] = [
    kAudioDevicePropertyMute,
    kAudioDevicePropertyJackIsConnected,
    kAudioDevicePropertyDeviceHasChanged,
    kAudioDevicePropertyStereoPan,
    kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    kAudioDevicePropertyDeviceIsRunningSomewhere,
]


// MARK: - Function forward declarations (not needed in Swift, but noting for parity)

// MARK: - CoreAudio helper functions

private func audiodevice_callback(
    deviceID: AudioDeviceID,
    numAddresses: UInt32,
    addressList: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    // Get the UID of the device, to pass into the callback
    var deviceUIDNS: String? = nil

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceUID: Unmanaged<CFString>?
    var propertySize = UInt32(MemoryLayout<CFString>.size)

    let result = withUnsafeMutablePointer(to: &deviceUID) { ptr in
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, ptr)
    }
    if result == noErr, let uid = deviceUID?.takeRetainedValue() {
        deviceUIDNS = uid as String
    }

    var events: [[String: Any]] = []

    for i in 0..<numAddresses {
        let addr = addressList[Int(i)]
        let mSelector = UTCreateStringForOSType(addr.mSelector).takeRetainedValue() as String
        let mScope = UTCreateStringForOSType(addr.mScope).takeRetainedValue() as String
        let mElement = NSNumber(value: addr.mElement)
        events.append(["mSelector": mSelector, "mScope": mScope, "mElement": mElement])
    }

    DispatchQueue.main.async {
        guard let clientData = clientData else { return }
        let userData = clientData.assumingMemoryBound(to: AudioDeviceUserData.self)
        let L = lua_getCurrentState()!
        if !lua_isStateGenerationValid(userData.pointee.lsCanary) {
            return
        }
        guard let cb = deviceCallbacks[clientData] else {
            os_log(.error, "%{public}s", "hs.audiodevice.watcher callback fired, but no function has been set with hs.audiodevice:watcherCallback()")
            return
        }
        for event in events {
            cb.push(onto: L)

            if let uid = deviceUIDNS {
                L.push(uid)
            } else {
                lua_pushnil(L)
            }

            lua_pushany(L, event["mSelector"] as? String)
            lua_pushany(L, event["mScope"] as? String)
            lua_pushany(L, event["mElement"])
            if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
    return noErr
}

// MARK: - Helper functions to identify the type of device

private func _check_audio_device_has_streams(_ deviceId: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
    var dataSize: UInt32 = 0

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectGetPropertyDataSize(deviceId, &propertyAddress, 0, nil, &dataSize) == noErr {
        return (dataSize / UInt32(MemoryLayout<AudioStreamID>.size)) > 0
    } else {
        return true
    }
}

private func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
    return _check_audio_device_has_streams(deviceID, kAudioObjectPropertyScopeOutput)
}

private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    return _check_audio_device_has_streams(deviceID, kAudioObjectPropertyScopeInput)
}

// MARK: - Helper functions for creating userdata objects

func new_device(_ L: UnsafeMutablePointer<lua_State>!, _ deviceId: AudioDeviceID) {
    let ptr = lua_newuserdata(L, MemoryLayout<AudioDeviceUserData>.size)!
    let audioDevice = ptr.assumingMemoryBound(to: AudioDeviceUserData.self)
    audioDevice.pointee.deviceId = deviceId
    audioDevice.pointee.watcherRunning = false
    audioDevice.pointee.lsCanary = lua_currentStateGeneration()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
}

func new_dataSource(_ L: UnsafeMutablePointer<lua_State>!, _ deviceID: AudioDeviceID, _ dataSource: UInt32) {
    let ptr = lua_newuserdata(L, MemoryLayout<DataSourceUserData>.size)!
    let userData = ptr.assumingMemoryBound(to: DataSourceUserData.self)
    userData.pointee.dataSource = dataSource
    userData.pointee.hostDevice = deviceID

    luaL_getmetatable(L, USERDATA_DATASOURCE_TAG)
    lua_setmetatable(L, -2)
}

// MARK: - hs.audiodevice library functions

/// hs.audiodevice.allDevices() -> hs.audiodevice[]
/// Function
/// Returns a list of all connected devices
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table of zero or more audio devices connected to the system
private func audiodevice_alldevices(_ L: LuaState) throws -> CInt {

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard
    )
    var deviceListPropertySize: UInt32 = 0

    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &deviceListPropertySize) == noErr else {
        lua_pushnil(L)
        return 1
    }

    let numDevices = Int(deviceListPropertySize) / MemoryLayout<AudioDeviceID>.size
    let deviceList = UnsafeMutablePointer<AudioDeviceID>.allocate(capacity: numDevices)
    defer { deviceList.deallocate() }
    deviceList.initialize(repeating: 0, count: numDevices)

    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &deviceListPropertySize, deviceList) == noErr else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)

    var tableIndex: Int32 = 1
    for i in 0..<numDevices {
        let deviceId = deviceList[i]
        L.push(lua_Integer(tableIndex))
        new_device(L, deviceId)
        lua_settable(L, -3)
        tableIndex += 1
    }

    return 1
}

/// hs.audiodevice.defaultOutputDevice() -> audio or nil
/// Function
/// Get the currently selected audio output device
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.audiodevice object, or nil if no suitable device could be found
private func audiodevice_defaultoutputdevice(_ L: LuaState) throws -> CInt {

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceId: AudioDeviceID = 0
    var deviceIdSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &deviceIdSize, &deviceId) == noErr && isOutputDevice(deviceId) {
        new_device(L, deviceId)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice.defaultInputDevice() -> audio or nil
/// Function
/// Get the currently selected audio input device
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.audiodevice object, or nil if no suitable device could be found
private func audiodevice_defaultinputdevice(_ L: LuaState) throws -> CInt {

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceId: AudioDeviceID = 0
    var deviceIdSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &deviceIdSize, &deviceId) == noErr && isInputDevice(deviceId) {
        new_device(L, deviceId)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice.defaultEffectDevice() -> audio or nil
/// Function
/// Get the currently selected sound effect device
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.audiodevice object, or nil if no suitable device could be found
private func audiodevice_defaulteffectdevice(_ L: LuaState) throws -> CInt {

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceId: AudioDeviceID = 0
    var deviceIdSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &deviceIdSize, &deviceId) == noErr && isOutputDevice(deviceId) {
        new_device(L, deviceId)
    } else {
        lua_pushnil(L)
    }

    return 1
}

// MARK: - hs.audiodevice object methods

/// hs.audiodevice:setDefaultOutputDevice() -> bool
/// Method
/// Selects this device as the system's audio output device
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device was successfully selected, otherwise false.
private func audiodevice_setdefaultoutputdevice(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    var deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let deviceIdSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    if isOutputDevice(deviceId) && AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, deviceIdSize, &deviceId) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:setDefaultEffectDevice() -> bool
/// Method
/// Selects this device as the audio output device for system sound effects
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device was successfully selected, otherwise false.
private func audiodevice_setdefaulteffectdevice(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    var deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let deviceIdSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    if isOutputDevice(deviceId) && AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, deviceIdSize, &deviceId) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:setDefaultInputDevice() -> bool
/// Method
/// Selects this device as the system's audio input device
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device was successfully selected, otherwise false.
private func audiodevice_setdefaultinputdevice(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    var deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let deviceIdSize = UInt32(MemoryLayout<AudioDeviceID>.size)

    if isInputDevice(deviceId) && AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, deviceIdSize, &deviceId) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:name() -> string or nil
/// Method
/// Get the name of the audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the audio device, or nil if it has no name
private func audiodevice_name(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceName: Unmanaged<CFString>?
    var propertySize = UInt32(MemoryLayout<CFString>.size)

    if withUnsafeMutablePointer(to: &deviceName, { ptr in
        AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &propertySize, ptr)
    }) == noErr, let name = deviceName?.takeRetainedValue() {
        L.push(name as String)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:uid() -> string or nil
/// Method
/// Get the unique identifier of the audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the UID of the audio device, or nil if it has no UID.
private func audiodevice_uid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceUID: Unmanaged<CFString>?
    var propertySize = UInt32(MemoryLayout<CFString>.size)

    let result = withUnsafeMutablePointer(to: &deviceUID) { ptr in
        AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &propertySize, ptr)
    }
    if result != noErr {
        lua_pushnil(L)
        return 1
    }

    if let uid = deviceUID {
        let uidString = uid.takeRetainedValue() as String
        L.push(uidString)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:inUse() -> bool or nil
/// Method
/// Check if the audio device is in use
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device is in use, False if not. nil if an error occurred.
private func audiodevice_inUse(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var dataSize: UInt32 = 0
    var isUsed: Int32 = 0

    var prop = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var err = AudioObjectGetPropertyDataSize(deviceId, &prop, 0, nil, &dataSize)
    if err != kAudioHardwareNoError {
        os_log(.error, "getAudioDeviceIsUsed(): get data size error: %d", err)
        lua_pushnil(L)
        return 1
    }

    err = AudioObjectGetPropertyData(deviceId, &prop, 0, nil, &dataSize, &isUsed)
    if err != kAudioHardwareNoError {
        os_log(.error, "getAudioDeviceIsUsed(): get data error: %d", err)
        lua_pushnil(L)
        return 1
    }

    L.push(isUsed != 0)
    return 1
}

/// hs.audiodevice:inputMuted() -> bool or nil
/// Method
/// Get the Input mutedness state of the audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device's Input is muted. False if it's not muted, nil if it does not support muting
private func audiodevice_inputMuted(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var muted: UInt32 = 0
    var mutedSize = UInt32(MemoryLayout<UInt32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &mutedSize, &muted) == noErr {
        L.push(muted != 0)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:outputMuted() -> bool or nil
/// Method
/// Get the Output mutedness state of the audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device's Output is muted. False if it's not muted, nil if it does not support muting
private func audiodevice_outputMuted(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var muted: UInt32 = 0
    var mutedSize = UInt32(MemoryLayout<UInt32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &mutedSize, &muted) == noErr {
        L.push(muted != 0)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:muted() -> bool or nil
/// Method
/// Get the mutedness state of the audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device is muted, False if it is not muted, nil if it does not support muting
///
/// Notes:
///  * If a device is capable of both input and output, this method will prefer the output. See `:inputMuted()` and `:outputMuted()` for specific variants.
private func audiodevice_muted(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var muted: UInt32 = 0
    var mutedSize = UInt32(MemoryLayout<UInt32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &mutedSize, &muted) == noErr {
        L.push(muted != 0)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:setInputMuted(state) -> bool
/// Method
/// Set the mutedness state of the Input of the audio device
///
/// Parameters:
///  * state - A boolean value. True to mute the device, False to unmute it
///
/// Returns:
///  * True if the device's Input mutedness state was set, or False if it does not support muting
private func audiodevice_setInputMuted(_ L: LuaState) throws -> CInt {

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var muted = UInt32(lua_toboolean(L, 2))
    let mutedSize = UInt32(MemoryLayout<UInt32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, mutedSize, &muted) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:setOutputMuted(state) -> bool
/// Method
/// Set the mutedness state of the Output of the audio device
///
/// Parameters:
///  * state - A boolean value. True to mute the device, False to unmute it
///
/// Returns:
///  * True if the device's Output mutedness state was set, or False if it does not support muting
private func audiodevice_setOutputMuted(_ L: LuaState) throws -> CInt {

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var muted = UInt32(lua_toboolean(L, 2))
    let mutedSize = UInt32(MemoryLayout<UInt32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, mutedSize, &muted) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:setMuted(state) -> bool
/// Method
/// Set the mutedness state of the audio device
///
/// Parameters:
///  * state - A boolean value. True to mute the device, False to unmute it
///
/// Returns:
///  * True if the device's mutedness state was set, or False if it does not support muting
///
/// Notes:
///  * If a device is capable of both input and output, this method will prefer the output. See `:setInputMuted()` and `:setOutputMuted()` for specific variants.
private func audiodevice_setmuted(_ L: LuaState) throws -> CInt {

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var muted = UInt32(lua_toboolean(L, 2))
    let mutedSize = UInt32(MemoryLayout<UInt32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, mutedSize, &muted) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:inputVolume() -> number or nil
/// Method
/// Get the current input volume of this audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number between 0 and 100, representing the input volume percentage, or nil if the audio device does not support input volume levels
///
/// Notes:
///  * The return value will be a floating point number
private func audiodevice_inputVolume(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var volume: Float32 = 0
    var volumeSize = UInt32(MemoryLayout<Float32>.size)

    if !isInputDevice(deviceId) {
        lua_pushnil(L)
        return 1
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &volumeSize, &volume) == noErr {
        L.push(lua_Number(volume * 100.0))
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:outputVolume() -> number or nil
/// Method
/// Get the current output volume of this audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number between 0 and 100, representing the output volume percentage, or nil if the audio device does not support output volume levels
///
/// Notes:
///  * The return value will be a floating point number
private func audiodevice_outputVolume(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var volume: Float32 = 0
    var volumeSize = UInt32(MemoryLayout<Float32>.size)

    if !isOutputDevice(deviceId) {
        lua_pushnil(L)
        return 1
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &volumeSize, &volume) == noErr {
        L.push(lua_Number(volume * 100.0))
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:volume() -> number or nil
/// Method
/// Get the current volume of this audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number between 0 and 100, representing the volume percentage, or nil if the audio device does not support volume levels
///
/// Notes:
///  * The return value will be a floating point number
///  * This method will inspect the device to determine if it is an input or output device, and return the appropriate volume. For devices that are both input and output devices, see `:inputVolume()` and `:outputVolume()`
private func audiodevice_volume(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var volume: Float32 = 0
    var volumeSize = UInt32(MemoryLayout<Float32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &volumeSize, &volume) == noErr {
        L.push(lua_Number(volume * 100.0))
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:setInputVolume(level) -> bool
/// Method
/// Set the input volume of this audio device
///
/// Parameters:
///  * level - A number between 0 and 100, representing the input volume as a percentage
///
/// Returns:
///  * True if the volume was set, false if the audio device does not support setting an input volume level
///
/// Notes:
///  * The volume level is a floating point number. Depending on your audio hardware, it may not be possible to increase volume in single digit increments
private func audiodevice_setInputVolume(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var value = Float32(lua_tonumber(L, 2))
    value = max(0, min(100, value))

    var volume = value / 100.0
    let volumeSize = UInt32(MemoryLayout<Float32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, volumeSize, &volume) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:setOutputVolume(level) -> bool
/// Method
/// Set the output volume of this audio device
///
/// Parameters:
///  * level - A number between 0 and 100, representing the output volume as a percentage
///
/// Returns:
///  * True if the volume was set, false if the audio device does not support setting an output volume level
///
/// Notes:
///  * The volume level is a floating point number. Depending on your audio hardware, it may not be possible to increase volume in single digit increments
private func audiodevice_setOutputVolume(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var value = Float32(lua_tonumber(L, 2))
    value = max(0, min(100, value))

    var volume = value / 100.0
    let volumeSize = UInt32(MemoryLayout<Float32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, volumeSize, &volume) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:setVolume(level) -> bool
/// Method
/// Set the volume of this audio device
///
/// Parameters:
///  * level - A number between 0 and 100, representing the volume as a percentage
///
/// Returns:
///  * True if the volume was set, false if the audio device does not support setting a volume level.
///
/// Notes:
///  * The volume level is a floating point number. Depending on your audio hardware, it may not be possible to increase volume in single digit increments.
///  * This method will inspect the device to determine if it is an input or output device, and set the appropriate volume. For devices that are both input and output devices, see `:setInputVolume()` and `:setOutputVolume()`
private func audiodevice_setvolume(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var value = Float32(lua_tonumber(L, 2))
    value = max(0, min(100, value))

    var volume = value / 100.0
    let volumeSize = UInt32(MemoryLayout<Float32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, volumeSize, &volume) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:balance() -> number or nil
/// Method
/// Get the current left/right balance of this audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number between 0.0 and 1.0, representing the balance (0.0 for full left, 1.0 for full right, 0.5 for center), or nil if the audio device does not support balance
///
/// Notes:
///  * The return value will be a floating point number
///  * This method will inspect the device to determine if it is an input or output device, and return the appropriate volume. For devices that are both input and output devices, see `:inputVolume()` and `:outputVolume()`
private func audiodevice_balance(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var balance: Float32 = 0
    var balanceSize = UInt32(MemoryLayout<Float32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &balanceSize, &balance) == noErr {
        L.push(lua_Number(balance))
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:setBalance(level) -> bool
/// Method
/// Set the balance of this audio device
///
/// Parameters:
///  * level - A number between 0.0 and 1.0, representing the balance (0.0 for full left, 1.0 for full right, 0.5 for center)
///
/// Returns:
///  * True if the balance was set, false if the audio device does not support setting a balance.
///
/// Notes:
///  * This method will inspect the device to determine if it is an input or output device, and set the appropriate volume. For devices that are both input and output devices, see `:setInputVolume()` and `:setOutputVolume()`
private func audiodevice_setbalance(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var value = Float32(lua_tonumber(L, 2))
    value = max(0, min(1, value))

    var balance = value
    let balanceSize = UInt32(MemoryLayout<Float32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, balanceSize, &balance) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:thru() -> bool or nil
/// Method
/// Get the play through (low latency/direct monitoring) state of the audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the audio device has thru enabled, False if thru is disabled, nil if it does not support thru
///
/// Notes:
///  * This method only works on devices that have hardware support (often microphones with a built-in headphone jack)
///  * This setting corresponds to the "Thru" setting in Audio MIDI Setup
private func audiodevice_thru(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var thru: UInt32 = 0
    var thruSize = UInt32(MemoryLayout<UInt32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyPlayThru,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &thruSize, &thru) == noErr {
        L.push(thru != 0)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:setThru(thru) -> bool
/// Method
/// Set the play through (low latency/direct monitoring) state of the audio device
///
/// Parameters:
///  * thru -  A boolean value. True to enable thru, False to disable
///
/// Returns:
///  * True if thru was set, False if the audio device does not support thru
///
/// Notes:
///  * This method only works on devices that have hardware support (often microphones with a built-in headphone jack)
///  * This setting corresponds to the "Thru" setting in Audio MIDI Setup
private func audiodevice_setThru(_ L: LuaState) throws -> CInt {

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var thru = UInt32(lua_toboolean(L, 2))
    let thruSize = UInt32(MemoryLayout<UInt32>.size)

    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyPlayThru,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectSetPropertyData(deviceId, &propertyAddress, 0, nil, thruSize, &thru) == noErr {
        L.push(true)
    } else {
        L.push(false)
    }

    return 1
}

/// hs.audiodevice:isOutputDevice() -> boolean
/// Method
/// Determines if an audio device is an output device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the device is an output device, false if not
private func audiodevice_isOutputDevice(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    L.push(isOutputDevice(audioDevice.pointee.deviceId))

    return 1
}

/// hs.audiodevice:isInputDevice() -> boolean
/// Method
/// Determines if an audio device is an input device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the device is an input device, false if not
private func audiodevice_isInputDevice(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    L.push(isInputDevice(audioDevice.pointee.deviceId))

    return 1
}

/// hs.audiodevice:transportType() -> string
/// Method
/// Gets the hardware transport type of an audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the transport type, or nil if an error occurred
private func audiodevice_transportType(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var transportType: UInt32 = 0
    var transportTypeSize = UInt32(MemoryLayout<UInt32>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceId, &propertyAddress) && AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &transportTypeSize, &transportType) == noErr {
        let transportTypeName: String
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:       transportTypeName = "Built-in"
        case kAudioDeviceTransportTypeAggregate:      transportTypeName = "Aggregate"
        case kAudioDeviceTransportTypeAutoAggregate:   transportTypeName = "Auto Aggregate"
        case kAudioDeviceTransportTypeVirtual:        transportTypeName = "Virtual"
        case kAudioDeviceTransportTypePCI:            transportTypeName = "PCI"
        case kAudioDeviceTransportTypeUSB:            transportTypeName = "USB"
        case kAudioDeviceTransportTypeFireWire:       transportTypeName = "FireWire"
        case kAudioDeviceTransportTypeBluetooth:      transportTypeName = "Bluetooth"
        case kAudioDeviceTransportTypeHDMI:           transportTypeName = "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:    transportTypeName = "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:        transportTypeName = "AirPlay"
        case kAudioDeviceTransportTypeAVB:            transportTypeName = "AVB"
        case kAudioDeviceTransportTypeThunderbolt:    transportTypeName = "Thunderbolt"
        default:                                      transportTypeName = "UNKNOWN"
        }
        L.push(transportTypeName)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:jackConnected() -> boolean or nil
/// Method
/// Determines whether an audio jack (e.g. headphones) is connected to an audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if a jack is connected, false if not, or nil if the device does not support jack sense
private func audiodevice_jackConnected(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var jackConnected: UInt32 = 0
    var jackConnectedSize = UInt32(MemoryLayout<UInt32>.size)
    let scope: AudioObjectPropertyScope = isOutputDevice(deviceId) ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyJackIsConnected,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &jackConnectedSize, &jackConnected) != noErr {
        lua_pushnil(L)
    } else {
        L.push(jackConnected != 0)
    }

    return 1
}

/// hs.audiodevice:supportsInputDataSources() -> boolean
/// Method
/// Determines whether an audio device supports input data sources
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the device supports input data sources, false if not
private func audiodevice_supportsInputDataSources(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSources,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    L.push(AudioObjectHasProperty(deviceId, &propertyAddress))

    return 1
}

/// hs.audiodevice:supportsOutputDataSources() -> boolean
/// Method
/// Determines whether an audio device supports output data sources
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the device supports output data sources, false if not
private func audiodevice_supportsOutputDataSources(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSources,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    L.push(AudioObjectHasProperty(deviceId, &propertyAddress))

    return 1
}

/// hs.audiodevice:currentInputDataSource() -> hs.audiodevice.dataSource object or nil
/// Method
/// Gets the current input data source of an audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.audiodevice.dataSource object, or nil if an error occurred
///
/// Notes:
///  * Before calling this method, you should check the result of hs.audiodevice:supportsInputDataSources()
private func audiodevice_currentInputDataSource(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSourceId: UInt32 = 0
    var dataSourceIdSize = UInt32(MemoryLayout<UInt32>.size)

    if AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &dataSourceIdSize, &dataSourceId) == noErr {
        new_dataSource(L, deviceId, dataSourceId)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:currentOutputDataSource() -> hs.audiodevice.dataSource object or nil
/// Method
/// Gets the current output data source of an audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.audiodevice.dataSource object, or nil if an error occurred
///
/// Notes:
///  * Before calling this method, you should check the result of hs.audiodevice:supportsOutputDataSources()
private func audiodevice_currentOutputDataSource(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSourceId: UInt32 = 0
    var dataSourceIdSize = UInt32(MemoryLayout<UInt32>.size)

    if AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &dataSourceIdSize, &dataSourceId) == noErr {
        new_dataSource(L, deviceId, dataSourceId)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.audiodevice:allOutputDataSources() -> hs.audiodevice.dataSource[] or nil
/// Method
/// Gets all of the output data sources of an audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A list of hs.audiodevice.dataSource objects, or nil if an error occurred
private func audiodevice_allOutputDataSources(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var datasourceListPropertySize: UInt32 = 0

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSources,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectGetPropertyDataSize(deviceId, &propertyAddress, 0, nil, &datasourceListPropertySize) == noErr else {
        lua_pushnil(L)
        return 1
    }

    let numSources = Int(datasourceListPropertySize) / MemoryLayout<UInt32>.size
    let datasourceList = UnsafeMutablePointer<UInt32>.allocate(capacity: numSources)
    defer { datasourceList.deallocate() }

    guard AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &datasourceListPropertySize, datasourceList) == noErr else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)

    for i in 0..<numSources {
        L.push(lua_Integer(i + 1))
        new_dataSource(L, deviceId, datasourceList[i])
        lua_settable(L, -3)
    }

    return 1
}

/// hs.audiodevice:allInputDataSources() -> hs.audiodevice.dataSource[] or nil
/// Method
/// Gets all of the input data sources of an audio device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A list of hs.audiodevice.dataSource objects, or nil if an error occurred
private func audiodevice_allInputDataSources(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var datasourceListPropertySize: UInt32 = 0

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSources,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectGetPropertyDataSize(deviceId, &propertyAddress, 0, nil, &datasourceListPropertySize) == noErr else {
        lua_pushnil(L)
        return 1
    }

    let numSources = Int(datasourceListPropertySize) / MemoryLayout<UInt32>.size
    let datasourceList = UnsafeMutablePointer<UInt32>.allocate(capacity: numSources)
    defer { datasourceList.deallocate() }

    guard AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &datasourceListPropertySize, datasourceList) == noErr else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)

    for i in 0..<numSources {
        L.push(lua_Integer(i + 1))
        new_dataSource(L, deviceId, datasourceList[i])
        lua_settable(L, -3)
    }

    return 1
}

/// hs.audiodevice:watcherCallback(fn) -> hs.audiodevice
/// Method
/// Sets or removes a callback function for an audio device watcher
///
/// Parameters:
///  * fn - A callback function that will be called when properties of this audio device change, or nil to remove an existing callback. The function should accept four arguments:
///   * A string containing the UID of the audio device (see `hs.audiodevice.findDeviceByUID()`)
///   * A string containing the name of the event. Possible values are:
///    * vmvc - Volume changed
///    * mute - Mute state changed
///    * jack - Jack sense state changed (usually this means headphones were plugged/unplugged)
///    * span - Stereo pan changed
///    * diff - Device configuration changed (if you are caching audio device properties, this event indicates you should flush your cache)
///    * gone - The device's "in use" status changed (ie another app started using the device, or stopped using it)
///   * A string containing the scope of the event. Possible values are:
///    * glob - This is a global event pertaining to the whole device
///    * inpt - This is an event pertaining only to the input functions of the device
///    * outp - This is an event pertaining only to the output functions of the device
///   * A number containing the element of the event. Typical values are:
///    * 0 - Typically this means the Master channel
///    * 1 - Typically this means the Left channel
///    * 2 - Typically this means the Right channel
///
/// Returns:
///  * The `hs.audiodevice` object
///
/// Notes:
///  * You will receive many events to your callback, so filtering on the name/scope/element arguments is vital. For example, on a stereo device, it is not uncommon to receive a `volm` event for each audio channel when the volume changes, or multiple `mute` events for channels. Dragging a volume slider in the system Sound preferences will produce a large number of `volm` events. Plugging/unplugging headphones may trigger `volm` events in addition to `jack` ones, etc.
///  * If you need to use the `hs.audiodevice` object in your callback, use `hs.audiodevice.findDeviceByUID()` to obtain it fro the first callback argument
private func audiodevice_watcherSetCallback(_ L: LuaState) throws -> CInt {
    let udPtr = luaL_checkudata(L, 1, USERDATA_TAG)!

    let audioDevice = userdataToAudioDevice(L, 1)

    // Drop any previous callback
    deviceCallbacks[udPtr] = nil

    switch lua_type(L, 2) {
    case LUA_TFUNCTION:
        deviceCallbacks[udPtr] = L.ref(index: 2)
    case LUA_TNIL:
        watcherStop(audioDevice)
    default:
        break
    }

    lua_pushvalue(L, 1)

    return 1
}

/// hs.audiodevice:watcherStart() -> hs.audiodevice or nil
/// Method
/// Starts the watcher on an `hs.audiodevice` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.audiodevice` object, or nil if an error occurred
private func audiodevice_watcherStart(_ L: LuaState) throws -> CInt {
    let udPtr = luaL_checkudata(L, 1, USERDATA_TAG)!

    let audioDevice = userdataToAudioDevice(L, 1)

    if deviceCallbacks[udPtr] == nil {
        os_log(.error, "%{public}s", "You must call hs.audiodevice:watcherCallback() before hs.audiodevice:watcherStart()")
        lua_pushnil(L)
        return 1
    }

    if audioDevice.pointee.watcherRunning {
        lua_pushvalue(L, 1)
        return 1
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: 0,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard
    )

    for selector in watchSelectors {
        propertyAddress.mSelector = selector
        AudioObjectAddPropertyListener(audioDevice.pointee.deviceId, &propertyAddress, audiodevice_callback, audioDevice)
    }

    audioDevice.pointee.watcherRunning = true

    lua_pushvalue(L, 1)

    return 1
}

func watcherStop(_ audioDevice: UnsafeMutablePointer<AudioDeviceUserData>) {
    if !audioDevice.pointee.watcherRunning {
        return
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: 0,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard
    )

    for selector in watchSelectors {
        propertyAddress.mSelector = selector
        AudioObjectRemovePropertyListener(audioDevice.pointee.deviceId, &propertyAddress, audiodevice_callback, audioDevice)
    }

    audioDevice.pointee.watcherRunning = false
}

/// hs.audiodevice:watcherStop() -> hs.audiodevice
/// Method
/// Stops the watcher on an `hs.audiodevice` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.audiodevice` object
private func audiodevice_watcherStop(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)

    watcherStop(audioDevice)

    lua_pushvalue(L, 1)

    return 1
}

/// hs.audiodevice:watcherIsRunning() -> boolean
/// Method
/// Gets the status of the `hs.audiodevice` object watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the watcher is running, false if not
private func audiodevice_watcherIsRunning(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)

    L.push(audioDevice.pointee.watcherRunning)

    return 1
}

private func audiodevice_tostring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let audioDevice = userdataToAudioDevice(L, 1)
    let deviceId = audioDevice.pointee.deviceId
    var deviceName: Unmanaged<CFString>?
    var propertySize = UInt32(MemoryLayout<CFString>.size)

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let deviceNameNS: String
    if withUnsafeMutablePointer(to: &deviceName, { ptr in
        AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &propertySize, ptr)
    }) == noErr, let name = deviceName?.takeRetainedValue() {
        deviceNameNS = name as String
    } else {
        deviceNameNS = "(un-named audiodevice)"
    }

    let ptr = lua_topointer(L, 1)
    lua_pushany(L, "\(USERDATA_TAG): \(deviceNameNS) (\(String(describing: ptr)))" as NSString)

    return 1
}

private func audiodevice_eq(_ L: LuaState) throws -> CInt {

    let deviceA = userdataToAudioDevice(L, 1)
    let deviceB = userdataToAudioDevice(L, 2)
    L.push(deviceA.pointee.deviceId == deviceB.pointee.deviceId)

    return 1
}

private func audiodevice_gc(_ L: LuaState) throws -> CInt {
    let udPtr = luaL_checkudata(L, 1, USERDATA_TAG)!

    _ = try audiodevice_watcherStop(L)

    // Drop the callback LuaValue (releases the registry ref via ARC)
    deviceCallbacks.removeValue(forKey: udPtr)

    return 0
}

// MARK: - hs.audiodevice.datasource object methods

func get_datasource_name(_ hostDevice: AudioDeviceID, _ dataSource: UInt32) -> String {
    var name = "(un-named datasource)"
    var dataSourceName: Unmanaged<CFString>?
    let scope: AudioObjectPropertyScope

    if isOutputDevice(hostDevice) {
        scope = kAudioObjectPropertyScopeOutput
    } else if isInputDevice(hostDevice) {
        scope = kAudioObjectPropertyScopeInput
    } else {
        return name
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    var mutableDataSource = dataSource
    var avt = AudioValueTranslation(
        mInputData: &mutableDataSource,
        mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
        mOutputData: &dataSourceName,
        mOutputDataSize: UInt32(MemoryLayout<CFString>.size)
    )

    var avtSize = UInt32(MemoryLayout<AudioValueTranslation>.size)

    if AudioObjectGetPropertyData(hostDevice, &propertyAddress, 0, nil, &avtSize, &avt) == noErr,
       let cfName = dataSourceName?.takeRetainedValue() {
        name = cfName as String
    }

    return name
}

/// hs.audiodevice.datasource:name() -> string
/// Method
/// Gets the name of an audio device datasource
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the datasource
private func datasource_name(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_DATASOURCE_TAG)

    let dataSource = userdataToDataSource(L, 1)
    let name = get_datasource_name(dataSource.pointee.hostDevice, dataSource.pointee.dataSource)

    L.push(name)

    return 1
}

/// hs.audiodevice.datasource:setDefault() -> hs.audiodevice.datasource
/// Method
/// Sets the audio device datasource as the default
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.audiodevice.datasource` object
private func datasource_setDefault(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_DATASOURCE_TAG)

    let dataSource = userdataToDataSource(L, 1)
    let scope: AudioObjectPropertyScope

    if isOutputDevice(dataSource.pointee.hostDevice) {
        scope = kAudioObjectPropertyScopeOutput
    } else if isInputDevice(dataSource.pointee.hostDevice) {
        scope = kAudioObjectPropertyScopeInput
    } else {
        os_log(.error, "ERROR: datasource host device is neither input nor output")
        lua_pushvalue(L, 1)
        return 1
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    var ds = dataSource.pointee.dataSource
    AudioObjectSetPropertyData(dataSource.pointee.hostDevice, &propertyAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &ds)

    lua_pushvalue(L, 1)

    return 1
}

private func datasource_tostring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_DATASOURCE_TAG)

    let dataSource = userdataToDataSource(L, 1)
    let name = get_datasource_name(dataSource.pointee.hostDevice, dataSource.pointee.dataSource)

    let ptr = lua_topointer(L, 1)
    L.push("\(USERDATA_DATASOURCE_TAG): \(name) (\(String(describing: ptr)))")

    return 1
}

private func datasource_eq(_ L: LuaState) throws -> CInt {

    let sourceA = userdataToDataSource(L, 1)
    let sourceB = userdataToDataSource(L, 2)
    L.push(sourceA.pointee.dataSource == sourceB.pointee.dataSource)

    return 1
}

// MARK: - Library initialisation

@_cdecl("luaopen_hs_libaudiodevice")
public func luaopen_hs_libaudiodevice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register audiodevice userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(audiodevice_setdefaultoutputdevice)
        lua_setfield(L, -2, "setDefaultOutputDevice")
        L.push(audiodevice_setdefaultinputdevice)
        lua_setfield(L, -2, "setDefaultInputDevice")
        L.push(audiodevice_setdefaulteffectdevice)
        lua_setfield(L, -2, "setDefaultEffectDevice")
        L.push(audiodevice_name)
        lua_setfield(L, -2, "name")
        L.push(audiodevice_uid)
        lua_setfield(L, -2, "uid")
        L.push(audiodevice_volume)
        lua_setfield(L, -2, "volume")
        L.push(audiodevice_inputVolume)
        lua_setfield(L, -2, "inputVolume")
        L.push(audiodevice_outputVolume)
        lua_setfield(L, -2, "outputVolume")
        L.push(audiodevice_setvolume)
        lua_setfield(L, -2, "setVolume")
        L.push(audiodevice_balance)
        lua_setfield(L, -2, "balance")
        L.push(audiodevice_setbalance)
        lua_setfield(L, -2, "setBalance")
        L.push(audiodevice_thru)
        lua_setfield(L, -2, "thru")
        L.push(audiodevice_setThru)
        lua_setfield(L, -2, "setThru")
        L.push(audiodevice_setInputVolume)
        lua_setfield(L, -2, "setInputVolume")
        L.push(audiodevice_setOutputVolume)
        lua_setfield(L, -2, "setOutputVolume")
        L.push(audiodevice_muted)
        lua_setfield(L, -2, "muted")
        L.push(audiodevice_inputMuted)
        lua_setfield(L, -2, "inputMuted")
        L.push(audiodevice_outputMuted)
        lua_setfield(L, -2, "outputMuted")
        L.push(audiodevice_setmuted)
        lua_setfield(L, -2, "setMuted")
        L.push(audiodevice_setInputMuted)
        lua_setfield(L, -2, "setInputMuted")
        L.push(audiodevice_setOutputMuted)
        lua_setfield(L, -2, "setOutputMuted")
        L.push(audiodevice_inUse)
        lua_setfield(L, -2, "inUse")
        L.push(audiodevice_isOutputDevice)
        lua_setfield(L, -2, "isOutputDevice")
        L.push(audiodevice_isInputDevice)
        lua_setfield(L, -2, "isInputDevice")
        L.push(audiodevice_transportType)
        lua_setfield(L, -2, "transportType")
        L.push(audiodevice_jackConnected)
        lua_setfield(L, -2, "jackConnected")
        L.push(audiodevice_supportsInputDataSources)
        lua_setfield(L, -2, "supportsInputDataSources")
        L.push(audiodevice_supportsOutputDataSources)
        lua_setfield(L, -2, "supportsOutputDataSources")
        L.push(audiodevice_currentInputDataSource)
        lua_setfield(L, -2, "currentInputDataSource")
        L.push(audiodevice_currentOutputDataSource)
        lua_setfield(L, -2, "currentOutputDataSource")
        L.push(audiodevice_allOutputDataSources)
        lua_setfield(L, -2, "allOutputDataSources")
        L.push(audiodevice_allInputDataSources)
        lua_setfield(L, -2, "allInputDataSources")
        L.push(audiodevice_watcherSetCallback)
        lua_setfield(L, -2, "watcherCallback")
        L.push(audiodevice_watcherStart)
        lua_setfield(L, -2, "watcherStart")
        L.push(audiodevice_watcherStop)
        lua_setfield(L, -2, "watcherStop")
        L.push(audiodevice_watcherIsRunning)
        lua_setfield(L, -2, "watcherIsRunning")
        L.push(audiodevice_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(audiodevice_eq)
        lua_setfield(L, -2, "__eq")
        L.push(audiodevice_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Register datasource userdata metatable
        luaL_newmetatable(L, USERDATA_DATASOURCE_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(USERDATA_DATASOURCE_TAG)
        lua_setfield(L, -2, "__type")
        L.push(datasource_name)
        lua_setfield(L, -2, "name")
        L.push(datasource_setDefault)
        lua_setfield(L, -2, "setDefault")
        L.push(datasource_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(datasource_eq)
        lua_setfield(L, -2, "__eq")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(audiodevice_alldevices)
        lua_setfield(L, -2, "allDevices")
        L.push(audiodevice_defaultoutputdevice)
        lua_setfield(L, -2, "defaultOutputDevice")
        L.push(audiodevice_defaultinputdevice)
        lua_setfield(L, -2, "defaultInputDevice")
        L.push(audiodevice_defaulteffectdevice)
        lua_setfield(L, -2, "defaultEffectDevice")
    }
}
