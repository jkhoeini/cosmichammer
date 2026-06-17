import AudioToolbox
import CoreAudio
import Carbon
import Foundation
import HSDSTCore

final class ProductionAudio: AudioProtocol {
    private var nextCallbackID: UInt64 = 1
    private var deviceChangeCallbacks: [UInt64: AudioCallbackState] = [:]
    private var propertyListenerCallbacks: [UInt64: PropertyListenerState] = [:]
    private var systemHardwareCallbacks: [UInt64: SystemHardwareListenerState] = [:]

    private class AudioCallbackState {
        let callback: (UInt32) -> Void
        var listenerProc: AudioObjectPropertyListenerProc?

        init(callback: @escaping (UInt32) -> Void) {
            self.callback = callback
        }
    }

    private class PropertyListenerState {
        let deviceID: UInt32
        let callback: (_ deviceID: UInt32, _ eventName: String, _ eventScope: String, _ element: UInt32) -> Void
        var listenerProc: AudioObjectPropertyListenerProc?

        init(deviceID: UInt32, callback: @escaping (_ deviceID: UInt32, _ eventName: String, _ eventScope: String, _ element: UInt32) -> Void) {
            self.deviceID = deviceID
            self.callback = callback
        }
    }

    private class SystemHardwareListenerState {
        let callback: (_ eventName: String) -> Void
        var listenerProc: AudioObjectPropertyListenerProc?

        init(callback: @escaping (_ eventName: String) -> Void) {
            self.callback = callback
        }
    }

    // MARK: - Device enumeration

    func allDevices() -> [AudioDevice] {
        return getDeviceIDs().compactMap { buildAudioDevice(deviceID: $0) }
    }

    func allInputDevices() -> [AudioDevice] {
        allDevices().filter { $0.isInput }
    }

    func allOutputDevices() -> [AudioDevice] {
        allDevices().filter { $0.isOutput }
    }

    func defaultOutputDevice() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return buildAudioDevice(deviceID: deviceID)
    }

    func defaultInputDevice() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return buildAudioDevice(deviceID: deviceID)
    }

    func defaultEffectDevice() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return buildAudioDevice(deviceID: deviceID)
    }

    func setDefaultOutputDevice(id: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(id)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
    }

    func setDefaultInputDevice(id: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(id)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
    }

    func setDefaultEffectDevice(id: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(id)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
    }

    // MARK: - Device info

    func deviceName(deviceID: UInt32) -> String? {
        getStringProperty(AudioDeviceID(deviceID), kAudioObjectPropertyName)
    }

    func deviceUID(deviceID: UInt32) -> String? {
        getStringProperty(AudioDeviceID(deviceID), kAudioDevicePropertyDeviceUID)
    }

    func isInputDevice(deviceID: UInt32) -> Bool {
        hasStreams(AudioDeviceID(deviceID), kAudioDevicePropertyScopeInput)
    }

    func isOutputDevice(deviceID: UInt32) -> Bool {
        hasStreams(AudioDeviceID(deviceID), kAudioDevicePropertyScopeOutput)
    }

    func transportType(deviceID: UInt32) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return nil }
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &type) == noErr
        else { return nil }
        return type
    }

    func jackConnected(deviceID: UInt32, scope: AudioScope) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyJackIsConnected,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        var jack: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &jack) == noErr
        else { return nil }
        return jack != 0
    }

    // MARK: - Volume (scope-aware)

    func getVolume(deviceID: UInt32) -> Float? {
        getVolume(deviceID: deviceID, scope: .output)
    }

    func getVolume(deviceID: UInt32, scope: AudioScope) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return volume
    }

    func setVolume(deviceID: UInt32, volume: Float) -> Bool {
        setVolume(deviceID: deviceID, volume: volume, scope: .output)
    }

    func setVolume(deviceID: UInt32, volume: Float, scope: AudioScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return false }
        var vol = Float32(volume)
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &vol) == noErr
    }

    // MARK: - Mute (scope-aware)

    func isMuted(deviceID: UInt32) -> Bool? {
        isMuted(deviceID: deviceID, scope: .output)
    }

    func isMuted(deviceID: UInt32, scope: AudioScope) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &muted) == noErr
        else { return nil }
        return muted != 0
    }

    func setMuted(deviceID: UInt32, muted: Bool) -> Bool {
        setMuted(deviceID: deviceID, muted: muted, scope: .output)
    }

    func setMuted(deviceID: UInt32, muted: Bool, scope: AudioScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return false }
        var muteValue: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &muteValue) == noErr
    }

    // MARK: - Balance

    func getBalance(deviceID: UInt32, scope: AudioScope) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return nil }
        var balance: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &balance) == noErr
        else { return nil }
        return balance
    }

    func setBalance(deviceID: UInt32, balance: Float, scope: AudioScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return false }
        var bal = Float32(balance)
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &bal) == noErr
    }

    // MARK: - Play-through

    func getPlayThrough(deviceID: UInt32, scope: AudioScope) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPlayThru,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return nil }
        var thru: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &thru) == noErr
        else { return nil }
        return thru != 0
    }

    func setPlayThrough(deviceID: UInt32, enabled: Bool, scope: AudioScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPlayThru,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(deviceID), &address) else { return false }
        var thruValue: UInt32 = enabled ? 1 : 0
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &thruValue) == noErr
    }

    // MARK: - Sample rate

    func getSampleRate(deviceID: UInt32) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &rate) == noErr
        else { return nil }
        return rate
    }

    func setSampleRate(deviceID: UInt32, rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var newRate = Float64(rate)
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &newRate) == noErr
    }

    // MARK: - Data sources (scope-aware)

    func dataSources(forDeviceID deviceID: UInt32) -> [AudioDataSourceInfo] {
        dataSources(forDeviceID: deviceID, scope: .output)
    }

    func dataSources(forDeviceID deviceID: UInt32, scope: AudioScope) -> [AudioDataSourceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(deviceID), &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<UInt32>.size
        let sources = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        defer { sources.deallocate() }
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, sources) == noErr
        else { return [] }

        return (0..<count).compactMap { i -> AudioDataSourceInfo? in
            let sourceID = sources[i]
            let name = dataSourceName(deviceID: deviceID, dataSourceID: sourceID, scope: scope)
            return AudioDataSourceInfo(id: sourceID, name: name ?? "Source \(sourceID)",
                                       deviceID: deviceID)
        }
    }

    func currentDataSource(forDeviceID deviceID: UInt32) -> AudioDataSourceInfo? {
        currentDataSource(forDeviceID: deviceID, scope: .output)
    }

    func currentDataSource(forDeviceID deviceID: UInt32, scope: AudioScope) -> AudioDataSourceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        var sourceID: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &sourceID) == noErr
        else { return nil }
        let name = dataSourceName(deviceID: deviceID, dataSourceID: sourceID, scope: scope)
        return AudioDataSourceInfo(id: sourceID, name: name ?? "Source \(sourceID)",
                                   deviceID: deviceID)
    }

    func setDataSource(deviceID: UInt32, dataSourceID: UInt32) -> Bool {
        setDataSource(deviceID: deviceID, dataSourceID: dataSourceID, scope: .output)
    }

    func setDataSource(deviceID: UInt32, dataSourceID: UInt32, scope: AudioScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        var sourceID = dataSourceID
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &sourceID) == noErr
    }

    func supportsDataSources(deviceID: UInt32, scope: AudioScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(AudioObjectID(deviceID), &address)
    }

    func dataSourceName(deviceID: UInt32, dataSourceID: UInt32, scope: AudioScope) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: coreAudioScope(scope),
            mElement: kAudioObjectPropertyElementMain)
        var dataSourceName: Unmanaged<CFString>?
        var mutableDataSource = dataSourceID
        var avt = AudioValueTranslation(
            mInputData: &mutableDataSource,
            mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
            mOutputData: &dataSourceName,
            mOutputDataSize: UInt32(MemoryLayout<CFString>.size)
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &avt) == noErr,
            let cfName = dataSourceName?.takeRetainedValue()
        else { return nil }
        return cfName as String
    }

    // MARK: - In use

    func isInUse(deviceID: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &running) == noErr
        else { return nil }
        return running != 0
    }

    // MARK: - Per-device property watcher

    private let propertyWatchSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyMute,
        kAudioDevicePropertyJackIsConnected,
        kAudioDevicePropertyDeviceHasChanged,
        kAudioDevicePropertyStereoPan,
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyDeviceIsRunningSomewhere,
    ]

    func addPropertyListener(deviceID: UInt32, callback: @escaping (_ deviceID: UInt32, _ eventName: String, _ eventScope: String, _ element: UInt32) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        let state = PropertyListenerState(deviceID: deviceID, callback: callback)

        let listenerProc: AudioObjectPropertyListenerProc = {
            objID, numAddresses, addressList, clientData -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let st = Unmanaged<PropertyListenerState>.fromOpaque(clientData).takeUnretainedValue()
            for i in 0..<Int(numAddresses) {
                let addr = addressList[i]
                let eventName = UTCreateStringForOSType(addr.mSelector).takeRetainedValue() as String
                let eventScope = UTCreateStringForOSType(addr.mScope).takeRetainedValue() as String
                let element = addr.mElement
                DispatchQueue.main.async {
                    st.callback(objID, eventName, eventScope, element)
                }
            }
            return noErr
        }

        state.listenerProc = listenerProc
        propertyListenerCallbacks[id] = state

        let unmanaged = Unmanaged.passRetained(state)
        var address = AudioObjectPropertyAddress(
            mSelector: 0,
            mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementWildcard)

        for selector in propertyWatchSelectors {
            address.mSelector = selector
            AudioObjectAddPropertyListener(
                AudioObjectID(deviceID), &address,
                listenerProc, unmanaged.toOpaque())
        }

        return id
    }

    func removePropertyListener(id: UInt64) -> Bool {
        guard let state = propertyListenerCallbacks.removeValue(forKey: id),
              let proc = state.listenerProc
        else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: 0,
            mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementWildcard)

        let unmanaged = Unmanaged.passUnretained(state)
        for selector in propertyWatchSelectors {
            address.mSelector = selector
            AudioObjectRemovePropertyListener(
                AudioObjectID(state.deviceID), &address,
                proc, unmanaged.toOpaque())
        }
        // Balance the passRetained from addPropertyListener
        unmanaged.release()
        return true
    }

    // MARK: - Device change callbacks

    func addDeviceChangeCallback(callback: @escaping (UInt32) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        let state = AudioCallbackState(callback: callback)

        let listenerProc: AudioObjectPropertyListenerProc = {
            _, _, _, clientData -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let cb = Unmanaged<AudioCallbackState>.fromOpaque(clientData).takeUnretainedValue()
            DispatchQueue.main.async { cb.callback(0) }
            return noErr
        }

        state.listenerProc = listenerProc
        deviceChangeCallbacks[id] = state

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let unmanaged = Unmanaged.passRetained(state)
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            listenerProc, unmanaged.toOpaque())

        return id
    }

    func removeDeviceChangeCallback(id: UInt64) -> Bool {
        guard let state = deviceChangeCallbacks.removeValue(forKey: id),
              let proc = state.listenerProc
        else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let unmanaged = Unmanaged.passUnretained(state)
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            proc, unmanaged.toOpaque())
        // Balance the passRetained from addDeviceChangeCallback
        unmanaged.release()
        return true
    }

    // MARK: - System-level audio hardware watcher

    private let systemWatchSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]

    func addSystemAudioHardwareListener(callback: @escaping (_ eventName: String) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        let state = SystemHardwareListenerState(callback: callback)

        let listenerProc: AudioObjectPropertyListenerProc = {
            _, numAddresses, addressList, clientData -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let st = Unmanaged<SystemHardwareListenerState>.fromOpaque(clientData).takeUnretainedValue()
            for i in 0..<Int(numAddresses) {
                let eventName = UTCreateStringForOSType(addressList[i].mSelector).takeRetainedValue() as String
                DispatchQueue.main.async {
                    st.callback(eventName)
                }
            }
            return noErr
        }

        state.listenerProc = listenerProc
        systemHardwareCallbacks[id] = state

        let unmanaged = Unmanaged.passRetained(state)
        var address = AudioObjectPropertyAddress(
            mSelector: 0,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        for selector in systemWatchSelectors {
            address.mSelector = selector
            AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &address,
                listenerProc, unmanaged.toOpaque())
        }

        return id
    }

    func removeSystemAudioHardwareListener(id: UInt64) -> Bool {
        guard let state = systemHardwareCallbacks.removeValue(forKey: id),
              let proc = state.listenerProc
        else { return false }

        let unmanaged = Unmanaged.passUnretained(state)
        var address = AudioObjectPropertyAddress(
            mSelector: 0,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        for selector in systemWatchSelectors {
            address.mSelector = selector
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &address,
                proc, unmanaged.toOpaque())
        }
        // Balance the passRetained from addSystemAudioHardwareListener
        unmanaged.release()
        return true
    }

    // MARK: - Private helpers

    private func coreAudioScope(_ scope: AudioScope) -> AudioObjectPropertyScope {
        switch scope {
        case .input: return kAudioObjectPropertyScopeInput
        case .output: return kAudioObjectPropertyScopeOutput
        }
    }

    private func getDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        let deviceIDs = UnsafeMutablePointer<AudioDeviceID>.allocate(capacity: count)
        defer { deviceIDs.deallocate() }
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, deviceIDs) == noErr
        else { return [] }

        return (0..<count).map { deviceIDs[$0] }
    }

    private func buildAudioDevice(deviceID: AudioDeviceID) -> AudioDevice? {
        let uid = getStringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
        let name = getStringProperty(deviceID, kAudioObjectPropertyName) ?? "Unknown"
        let manufacturer = getStringProperty(deviceID, kAudioObjectPropertyManufacturer) ?? ""
        let isInput = hasStreams(deviceID, kAudioDevicePropertyScopeInput)
        let isOutput = hasStreams(deviceID, kAudioDevicePropertyScopeOutput)
        let sampleRate = getSampleRate(deviceID: deviceID) ?? 0
        let volume = getVolume(deviceID: deviceID) ?? 0
        let muted = isMuted(deviceID: deviceID) ?? false
        let inUse = isInUse(deviceID: deviceID) ?? false

        // Transport type
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transportType: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &transportAddress, 0, nil, &tSize, &transportType)

        // Jack connected
        var jackAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyJackIsConnected,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var jack: UInt32 = 0
        var jSize = UInt32(MemoryLayout<UInt32>.size)
        let jackConnected: Bool
        if AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &jackAddress, 0, nil, &jSize, &jack) == noErr
        {
            jackConnected = jack != 0
        } else {
            jackConnected = false
        }

        return AudioDevice(
            id: deviceID, uid: uid, name: name, manufacturer: manufacturer,
            isInput: isInput, isOutput: isOutput, sampleRate: sampleRate,
            volume: volume, isMuted: muted, jackConnected: jackConnected,
            transportType: transportType, inUse: inUse
        )
    }

    private func getStringProperty(_ deviceID: AudioDeviceID,
                                    _ selector: AudioObjectPropertySelector) -> String?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfStr: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &cfStr) == noErr,
            let result = cfStr
        else { return nil }
        return result as String
    }

    private func hasStreams(_ deviceID: AudioDeviceID,
                            _ scope: AudioObjectPropertyScope) -> Bool
    {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            AudioObjectID(deviceID), &address, 0, nil, &size) == noErr && size > 0
    }
}
