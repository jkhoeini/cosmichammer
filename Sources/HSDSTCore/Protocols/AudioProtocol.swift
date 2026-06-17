import Foundation

public enum AudioScope: Sendable, Hashable {
    case input
    case output
}

public struct AudioDevice: Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var isInput: Bool
    public var isOutput: Bool
    public var sampleRate: Double
    public var volume: Float
    public var isMuted: Bool
    public var jackConnected: Bool
    public var transportType: UInt32
    public var inUse: Bool

    public init(id: UInt32 = 1, uid: String = "BuiltInSpeakerDevice",
                name: String = "MacBook Pro Speakers", manufacturer: String = "Apple Inc.",
                isInput: Bool = false, isOutput: Bool = true,
                sampleRate: Double = 44100.0, volume: Float = 0.75,
                isMuted: Bool = false, jackConnected: Bool = false,
                transportType: UInt32 = 0, inUse: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.isInput = isInput
        self.isOutput = isOutput
        self.sampleRate = sampleRate
        self.volume = volume
        self.isMuted = isMuted
        self.jackConnected = jackConnected
        self.transportType = transportType
        self.inUse = inUse
    }
}

public struct AudioDataSourceInfo: Sendable {
    public var id: UInt32
    public var name: String
    public var deviceID: UInt32

    public init(id: UInt32 = 0, name: String = "Default", deviceID: UInt32 = 1) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
    }
}

public protocol AudioProtocol: AnyObject {
    // MARK: - Device enumeration
    func allDevices() -> [AudioDevice]
    func allInputDevices() -> [AudioDevice]
    func allOutputDevices() -> [AudioDevice]
    func defaultOutputDevice() -> AudioDevice?
    func defaultInputDevice() -> AudioDevice?
    func defaultEffectDevice() -> AudioDevice?
    func setDefaultOutputDevice(id: UInt32) -> Bool
    func setDefaultInputDevice(id: UInt32) -> Bool
    func setDefaultEffectDevice(id: UInt32) -> Bool

    // MARK: - Device info (by ID)
    func deviceName(deviceID: UInt32) -> String?
    func deviceUID(deviceID: UInt32) -> String?
    func isInputDevice(deviceID: UInt32) -> Bool
    func isOutputDevice(deviceID: UInt32) -> Bool
    func transportType(deviceID: UInt32) -> UInt32?
    func jackConnected(deviceID: UInt32, scope: AudioScope) -> Bool?

    // MARK: - Volume (scope-aware)
    func getVolume(deviceID: UInt32) -> Float?
    func getVolume(deviceID: UInt32, scope: AudioScope) -> Float?
    func setVolume(deviceID: UInt32, volume: Float) -> Bool
    func setVolume(deviceID: UInt32, volume: Float, scope: AudioScope) -> Bool

    // MARK: - Mute (scope-aware)
    func isMuted(deviceID: UInt32) -> Bool?
    func isMuted(deviceID: UInt32, scope: AudioScope) -> Bool?
    func setMuted(deviceID: UInt32, muted: Bool) -> Bool
    func setMuted(deviceID: UInt32, muted: Bool, scope: AudioScope) -> Bool

    // MARK: - Balance
    func getBalance(deviceID: UInt32, scope: AudioScope) -> Float?
    func setBalance(deviceID: UInt32, balance: Float, scope: AudioScope) -> Bool

    // MARK: - Play-through (thru)
    func getPlayThrough(deviceID: UInt32, scope: AudioScope) -> Bool?
    func setPlayThrough(deviceID: UInt32, enabled: Bool, scope: AudioScope) -> Bool

    // MARK: - Sample rate
    func getSampleRate(deviceID: UInt32) -> Double?
    func setSampleRate(deviceID: UInt32, rate: Double) -> Bool

    // MARK: - In use
    func isInUse(deviceID: UInt32) -> Bool?

    // MARK: - Data sources (scope-aware)
    func dataSources(forDeviceID: UInt32) -> [AudioDataSourceInfo]
    func dataSources(forDeviceID: UInt32, scope: AudioScope) -> [AudioDataSourceInfo]
    func currentDataSource(forDeviceID: UInt32) -> AudioDataSourceInfo?
    func currentDataSource(forDeviceID: UInt32, scope: AudioScope) -> AudioDataSourceInfo?
    func setDataSource(deviceID: UInt32, dataSourceID: UInt32) -> Bool
    func setDataSource(deviceID: UInt32, dataSourceID: UInt32, scope: AudioScope) -> Bool
    func supportsDataSources(deviceID: UInt32, scope: AudioScope) -> Bool
    func dataSourceName(deviceID: UInt32, dataSourceID: UInt32, scope: AudioScope) -> String?

    // MARK: - Per-device property watcher
    func addPropertyListener(deviceID: UInt32, callback: @escaping (_ deviceID: UInt32, _ eventName: String, _ eventScope: String, _ element: UInt32) -> Void) -> UInt64
    func removePropertyListener(id: UInt64) -> Bool

    // MARK: - System-level device change watcher
    func addDeviceChangeCallback(callback: @escaping (UInt32) -> Void) -> UInt64
    func removeDeviceChangeCallback(id: UInt64) -> Bool

    // MARK: - System-level audio hardware watcher (device added/removed/default changed)
    func addSystemAudioHardwareListener(callback: @escaping (_ eventName: String) -> Void) -> UInt64
    func removeSystemAudioHardwareListener(id: UInt64) -> Bool
}
