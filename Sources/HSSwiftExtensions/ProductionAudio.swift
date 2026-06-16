import AudioToolbox
import CoreAudio
import Foundation
import HSDSTCore

final class ProductionAudio: AudioProtocol {
    private var nextCallbackID: UInt64 = 1
    private var callbacks: [UInt64: AudioCallbackState] = [:]

    private class AudioCallbackState {
        let callback: (UInt32) -> Void
        var listenerProc: AudioObjectPropertyListenerProc?

        init(callback: @escaping (UInt32) -> Void) {
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

    // MARK: - Volume

    func getVolume(deviceID: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return volume
    }

    func setVolume(deviceID: UInt32, volume: Float) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vol = Float32(volume)
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &vol) == noErr
    }

    func isMuted(deviceID: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &muted) == noErr
        else { return nil }
        return muted != 0
    }

    func setMuted(deviceID: UInt32, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muteValue: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &muteValue) == noErr
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

    // MARK: - Data sources

    func dataSources(forDeviceID deviceID: UInt32) -> [AudioDataSourceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: kAudioDevicePropertyScopeOutput,
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
            let name = dataSourceName(deviceID: deviceID, sourceID: sourceID)
            return AudioDataSourceInfo(id: sourceID, name: name ?? "Source \(sourceID)",
                                       deviceID: deviceID)
        }
    }

    func currentDataSource(forDeviceID deviceID: UInt32) -> AudioDataSourceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var sourceID: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &sourceID) == noErr
        else { return nil }
        let name = dataSourceName(deviceID: deviceID, sourceID: sourceID)
        return AudioDataSourceInfo(id: sourceID, name: name ?? "Source \(sourceID)",
                                   deviceID: deviceID)
    }

    func setDataSource(deviceID: UInt32, dataSourceID: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var sourceID = dataSourceID
        return AudioObjectSetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &sourceID) == noErr
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
        callbacks[id] = state

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
        guard let state = callbacks.removeValue(forKey: id),
              let proc = state.listenerProc
        else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            proc, Unmanaged.passUnretained(state).toOpaque())
        return true
    }

    // MARK: - Private

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

    private func dataSourceName(deviceID: UInt32, sourceID: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var translation = AudioValueTranslation(
            mInputData: UnsafeMutableRawPointer(mutating: [sourceID]).bindMemory(
                to: UInt32.self, capacity: 1),
            mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
            mOutputData: UnsafeMutableRawPointer.allocate(
                byteCount: MemoryLayout<CFString?>.size, alignment: MemoryLayout<CFString?>.alignment),
            mOutputDataSize: UInt32(MemoryLayout<CFString?>.size)
        )
        defer { translation.mOutputData.deallocate() }
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(deviceID), &address, 0, nil, &size, &translation) == noErr
        else { return nil }
        let cfStr = translation.mOutputData.load(as: CFString?.self)
        return cfStr as String?
    }
}
