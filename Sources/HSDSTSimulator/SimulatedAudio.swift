import Foundation
import HSDSTCore

public final class SimulatedAudio: AudioProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var devices: [AudioDevice] = [
        AudioDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "Built-in Output",
                        manufacturer: "Apple Inc.", isInput: false, isOutput: true,
                        sampleRate: 44100.0, volume: 0.75, isMuted: false),
        AudioDevice(id: 2, uid: "BuiltInMicrophoneDevice", name: "Built-in Microphone",
                        manufacturer: "Apple Inc.", isInput: true, isOutput: false,
                        sampleRate: 44100.0, volume: 0.80, isMuted: false),
    ]
    public var defaultOutputID: UInt32 = 1
    public var defaultInputID: UInt32 = 2
    public var defaultEffectID: UInt32 = 1
    public var dataSources: [UInt32: [AudioScope: [AudioDataSourceInfo]]] = [:]
    public var currentDataSourceIDs: [UInt32: [AudioScope: UInt32]] = [:]
    /// Per-device balance values keyed by (deviceID, scope).
    public var balances: [UInt32: [AudioScope: Float]] = [:]
    /// Per-device play-through state keyed by (deviceID, scope).
    public var playThroughStates: [UInt32: [AudioScope: Bool]] = [:]
    /// Per-device volume keyed by (deviceID, scope). Falls back to AudioDevice.volume when absent.
    public var scopedVolumes: [UInt32: [AudioScope: Float]] = [:]
    /// Per-device mute keyed by (deviceID, scope). Falls back to AudioDevice.isMuted when absent.
    public var scopedMutes: [UInt32: [AudioScope: Bool]] = [:]

    private var nextCallbackID: UInt64 = 1
    private var deviceChangeCallbacks: [UInt64: (UInt32) -> Void] = [:]
    private var propertyListenerCallbacks: [UInt64: (deviceID: UInt32, callback: (_ deviceID: UInt32, _ eventName: String, _ eventScope: String, _ element: UInt32) -> Void)] = [:]
    private var systemHardwareCallbacks: [UInt64: (_ eventName: String) -> Void] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Device listing

    public func allDevices() -> [AudioDevice] { devices }

    public func allInputDevices() -> [AudioDevice] {
        devices.filter { $0.isInput }
    }

    public func allOutputDevices() -> [AudioDevice] {
        devices.filter { $0.isOutput }
    }

    public func defaultOutputDevice() -> AudioDevice? {
        devices.first { $0.id == defaultOutputID && $0.isOutput }
    }

    public func defaultInputDevice() -> AudioDevice? {
        devices.first { $0.id == defaultInputID && $0.isInput }
    }

    public func defaultEffectDevice() -> AudioDevice? {
        devices.first { $0.id == defaultEffectID && $0.isOutput }
    }

    public func setDefaultOutputDevice(id: UInt32) -> Bool {
        guard devices.contains(where: { $0.id == id && $0.isOutput }) else { return false }
        defaultOutputID = id
        notifyDeviceChangeCallbacks(deviceID: id)
        notifySystemHardwareListeners(eventName: "dOut")
        return true
    }

    public func setDefaultInputDevice(id: UInt32) -> Bool {
        guard devices.contains(where: { $0.id == id && $0.isInput }) else { return false }
        defaultInputID = id
        notifyDeviceChangeCallbacks(deviceID: id)
        notifySystemHardwareListeners(eventName: "dIn ")
        return true
    }

    public func setDefaultEffectDevice(id: UInt32) -> Bool {
        guard devices.contains(where: { $0.id == id && $0.isOutput }) else { return false }
        defaultEffectID = id
        notifyDeviceChangeCallbacks(deviceID: id)
        notifySystemHardwareListeners(eventName: "sOut")
        return true
    }

    // MARK: - Device info

    public func deviceName(deviceID: UInt32) -> String? {
        devices.first { $0.id == deviceID }?.name
    }

    public func deviceUID(deviceID: UInt32) -> String? {
        devices.first { $0.id == deviceID }?.uid
    }

    public func isInputDevice(deviceID: UInt32) -> Bool {
        devices.first { $0.id == deviceID }?.isInput ?? false
    }

    public func isOutputDevice(deviceID: UInt32) -> Bool {
        devices.first { $0.id == deviceID }?.isOutput ?? false
    }

    public func transportType(deviceID: UInt32) -> UInt32? {
        devices.first { $0.id == deviceID }?.transportType
    }

    public func jackConnected(deviceID: UInt32, scope: AudioScope) -> Bool? {
        devices.first { $0.id == deviceID }?.jackConnected
    }

    // MARK: - Volume (scope-aware)

    public func getVolume(deviceID: UInt32) -> Float? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.volume
    }

    public func getVolume(deviceID: UInt32, scope: AudioScope) -> Float? {
        if let scopedVol = scopedVolumes[deviceID]?[scope] {
            return scopedVol
        }
        return getVolume(deviceID: deviceID)
    }

    public func setVolume(deviceID: UInt32, volume: Float) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        let clamped = max(0, min(1, volume))
        devices[idx].volume = clamped
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        let scope: AudioScope = devices[idx].isOutput ? .output : .input
        notifyPropertyListeners(deviceID: deviceID, eventName: "vmvc", eventScope: scopeString(scope))
        return true
    }

    public func setVolume(deviceID: UInt32, volume: Float, scope: AudioScope) -> Bool {
        guard devices.contains(where: { $0.id == deviceID }) else { return false }
        let clamped = max(0, min(1, volume))
        if scopedVolumes[deviceID] == nil { scopedVolumes[deviceID] = [:] }
        scopedVolumes[deviceID]![scope] = clamped
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        notifyPropertyListeners(deviceID: deviceID, eventName: "vmvc", eventScope: scopeString(scope))
        return true
    }

    // MARK: - Mute (scope-aware)

    public func isMuted(deviceID: UInt32) -> Bool? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.isMuted
    }

    public func isMuted(deviceID: UInt32, scope: AudioScope) -> Bool? {
        if let scopedMute = scopedMutes[deviceID]?[scope] {
            return scopedMute
        }
        return isMuted(deviceID: deviceID)
    }

    public func setMuted(deviceID: UInt32, muted: Bool) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        devices[idx].isMuted = muted
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        let scope: AudioScope = devices[idx].isOutput ? .output : .input
        notifyPropertyListeners(deviceID: deviceID, eventName: "mute", eventScope: scopeString(scope))
        return true
    }

    public func setMuted(deviceID: UInt32, muted: Bool, scope: AudioScope) -> Bool {
        guard devices.contains(where: { $0.id == deviceID }) else { return false }
        if scopedMutes[deviceID] == nil { scopedMutes[deviceID] = [:] }
        scopedMutes[deviceID]![scope] = muted
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        notifyPropertyListeners(deviceID: deviceID, eventName: "mute", eventScope: scopeString(scope))
        return true
    }

    // MARK: - Balance

    public func getBalance(deviceID: UInt32, scope: AudioScope) -> Float? {
        balances[deviceID]?[scope]
    }

    public func setBalance(deviceID: UInt32, balance: Float, scope: AudioScope) -> Bool {
        guard devices.contains(where: { $0.id == deviceID }) else { return false }
        let clamped = max(0, min(1, balance))
        if balances[deviceID] == nil { balances[deviceID] = [:] }
        balances[deviceID]![scope] = clamped
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        notifyPropertyListeners(deviceID: deviceID, eventName: "span", eventScope: scopeString(scope))
        return true
    }

    // MARK: - Play-through

    public func getPlayThrough(deviceID: UInt32, scope: AudioScope) -> Bool? {
        playThroughStates[deviceID]?[scope]
    }

    public func setPlayThrough(deviceID: UInt32, enabled: Bool, scope: AudioScope) -> Bool {
        guard devices.contains(where: { $0.id == deviceID }) else { return false }
        if playThroughStates[deviceID] == nil { playThroughStates[deviceID] = [:] }
        playThroughStates[deviceID]![scope] = enabled
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        notifyPropertyListeners(deviceID: deviceID, eventName: "thru", eventScope: scopeString(scope))
        return true
    }

    // MARK: - Sample rate

    public func getSampleRate(deviceID: UInt32) -> Double? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.sampleRate
    }

    public func setSampleRate(deviceID: UInt32, rate: Double) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        devices[idx].sampleRate = rate
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        notifyPropertyListeners(deviceID: deviceID, eventName: "nsrt", eventScope: "glob")
        return true
    }

    // MARK: - Data sources (scope-aware)

    public func dataSources(forDeviceID deviceID: UInt32) -> [AudioDataSourceInfo] {
        dataSources(forDeviceID: deviceID, scope: .output)
    }

    public func dataSources(forDeviceID deviceID: UInt32, scope: AudioScope) -> [AudioDataSourceInfo] {
        dataSources[deviceID]?[scope] ?? []
    }

    public func currentDataSource(forDeviceID deviceID: UInt32) -> AudioDataSourceInfo? {
        currentDataSource(forDeviceID: deviceID, scope: .output)
    }

    public func currentDataSource(forDeviceID deviceID: UInt32, scope: AudioScope) -> AudioDataSourceInfo? {
        guard let sources = dataSources[deviceID]?[scope],
              let currentID = currentDataSourceIDs[deviceID]?[scope] else { return nil }
        return sources.first { $0.id == currentID }
    }

    public func setDataSource(deviceID: UInt32, dataSourceID: UInt32) -> Bool {
        setDataSource(deviceID: deviceID, dataSourceID: dataSourceID, scope: .output)
    }

    public func setDataSource(deviceID: UInt32, dataSourceID: UInt32, scope: AudioScope) -> Bool {
        guard let sources = dataSources[deviceID]?[scope],
              sources.contains(where: { $0.id == dataSourceID }) else { return false }
        if currentDataSourceIDs[deviceID] == nil { currentDataSourceIDs[deviceID] = [:] }
        currentDataSourceIDs[deviceID]![scope] = dataSourceID
        notifyDeviceChangeCallbacks(deviceID: deviceID)
        notifyPropertyListeners(deviceID: deviceID, eventName: "dsrc", eventScope: scopeString(scope))
        return true
    }

    public func supportsDataSources(deviceID: UInt32, scope: AudioScope) -> Bool {
        guard let scopedSources = dataSources[deviceID]?[scope] else { return false }
        return !scopedSources.isEmpty
    }

    public func dataSourceName(deviceID: UInt32, dataSourceID: UInt32, scope: AudioScope) -> String? {
        guard let sources = dataSources[deviceID]?[scope] else { return nil }
        return sources.first { $0.id == dataSourceID }?.name
    }

    // MARK: - In use

    public func isInUse(deviceID: UInt32) -> Bool? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.inUse
    }

    // MARK: - Per-device property watcher

    public func addPropertyListener(deviceID: UInt32, callback: @escaping (_ deviceID: UInt32, _ eventName: String, _ eventScope: String, _ element: UInt32) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        propertyListenerCallbacks[id] = (deviceID: deviceID, callback: callback)
        return id
    }

    public func removePropertyListener(id: UInt64) -> Bool {
        propertyListenerCallbacks.removeValue(forKey: id) != nil
    }

    // MARK: - Device change callbacks

    public func addDeviceChangeCallback(callback: @escaping (UInt32) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        deviceChangeCallbacks[id] = callback
        return id
    }

    public func removeDeviceChangeCallback(id: UInt64) -> Bool {
        deviceChangeCallbacks.removeValue(forKey: id) != nil
    }

    // MARK: - System-level audio hardware watcher

    public func addSystemAudioHardwareListener(callback: @escaping (_ eventName: String) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        systemHardwareCallbacks[id] = callback
        return id
    }

    public func removeSystemAudioHardwareListener(id: UInt64) -> Bool {
        systemHardwareCallbacks.removeValue(forKey: id) != nil
    }

    // MARK: - Private

    private func notifyDeviceChangeCallbacks(deviceID: UInt32) {
        for (_, callback) in deviceChangeCallbacks {
            callback(deviceID)
        }
    }

    /// Convert an AudioScope to the CoreAudio FourCC scope string.
    private func scopeString(_ scope: AudioScope) -> String {
        switch scope {
        case .output: return "outp"
        case .input: return "inpt"
        }
    }

    /// Auto-fire property listener callbacks for a device, mirroring what CoreAudio
    /// does when a property is mutated via AudioObjectSetPropertyData.
    private func notifyPropertyListeners(deviceID: UInt32, eventName: String, eventScope: String, element: UInt32 = 0) {
        for (_, entry) in propertyListenerCallbacks {
            if entry.deviceID == deviceID {
                entry.callback(deviceID, eventName, eventScope, element)
            }
        }
    }

    /// Auto-fire system hardware listener callbacks, mirroring what CoreAudio does
    /// when the default device changes.
    private func notifySystemHardwareListeners(eventName: String) {
        for (_, callback) in systemHardwareCallbacks {
            callback(eventName)
        }
    }

    /// Trigger property listener callbacks for testing. Can be called from tests.
    public func simulatePropertyChange(deviceID: UInt32, eventName: String, eventScope: String, element: UInt32) {
        notifyPropertyListeners(deviceID: deviceID, eventName: eventName, eventScope: eventScope, element: element)
    }

    /// Trigger system hardware listener callbacks for testing.
    public func simulateSystemHardwareEvent(eventName: String) {
        notifySystemHardwareListeners(eventName: eventName)
    }
}
