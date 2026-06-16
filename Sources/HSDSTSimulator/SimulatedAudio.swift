import Foundation
import HSDSTCore

public final class SimulatedAudio: AudioProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var devices: [AudioDevice] = [
        AudioDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                        manufacturer: "Apple Inc.", isInput: false, isOutput: true,
                        sampleRate: 44100.0, volume: 0.75, isMuted: false),
        AudioDevice(id: 2, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                        manufacturer: "Apple Inc.", isInput: true, isOutput: false,
                        sampleRate: 44100.0, volume: 0.80, isMuted: false),
    ]
    public var defaultOutputID: UInt32 = 1
    public var defaultInputID: UInt32 = 2
    public var dataSources: [UInt32: [AudioDataSourceInfo]] = [:]
    public var currentDataSourceIDs: [UInt32: UInt32] = [:]

    private var nextCallbackID: UInt64 = 1
    private var callbacks: [UInt64: (UInt32) -> Void] = [:]

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

    public func setDefaultOutputDevice(id: UInt32) -> Bool {
        guard devices.contains(where: { $0.id == id && $0.isOutput }) else { return false }
        defaultOutputID = id
        notifyCallbacks(deviceID: id)
        return true
    }

    public func setDefaultInputDevice(id: UInt32) -> Bool {
        guard devices.contains(where: { $0.id == id && $0.isInput }) else { return false }
        defaultInputID = id
        notifyCallbacks(deviceID: id)
        return true
    }

    // MARK: - Volume

    public func getVolume(deviceID: UInt32) -> Float? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.volume
    }

    public func setVolume(deviceID: UInt32, volume: Float) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        let clamped = max(0, min(1, volume))
        devices[idx].volume = clamped
        notifyCallbacks(deviceID: deviceID)
        return true
    }

    // MARK: - Mute

    public func isMuted(deviceID: UInt32) -> Bool? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.isMuted
    }

    public func setMuted(deviceID: UInt32, muted: Bool) -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        devices[idx].isMuted = muted
        notifyCallbacks(deviceID: deviceID)
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
        notifyCallbacks(deviceID: deviceID)
        return true
    }

    // MARK: - Data sources

    public func dataSources(forDeviceID deviceID: UInt32) -> [AudioDataSourceInfo] {
        dataSources[deviceID] ?? []
    }

    public func currentDataSource(forDeviceID deviceID: UInt32) -> AudioDataSourceInfo? {
        guard let sources = dataSources[deviceID],
              let currentID = currentDataSourceIDs[deviceID] else { return nil }
        return sources.first { $0.id == currentID }
    }

    public func setDataSource(deviceID: UInt32, dataSourceID: UInt32) -> Bool {
        guard let sources = dataSources[deviceID],
              sources.contains(where: { $0.id == dataSourceID }) else { return false }
        currentDataSourceIDs[deviceID] = dataSourceID
        notifyCallbacks(deviceID: deviceID)
        return true
    }

    // MARK: - In use

    public func isInUse(deviceID: UInt32) -> Bool? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.inUse
    }

    // MARK: - Callbacks

    public func addDeviceChangeCallback(callback: @escaping (UInt32) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        callbacks[id] = callback
        return id
    }

    public func removeDeviceChangeCallback(id: UInt64) -> Bool {
        callbacks.removeValue(forKey: id) != nil
    }

    // MARK: - Private

    private func notifyCallbacks(deviceID: UInt32) {
        for (_, callback) in callbacks {
            callback(deviceID)
        }
    }
}
