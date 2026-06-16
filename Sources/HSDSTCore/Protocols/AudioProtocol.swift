import Foundation

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
    func allDevices() -> [AudioDevice]
    func allInputDevices() -> [AudioDevice]
    func allOutputDevices() -> [AudioDevice]
    func defaultOutputDevice() -> AudioDevice?
    func defaultInputDevice() -> AudioDevice?
    func setDefaultOutputDevice(id: UInt32) -> Bool
    func setDefaultInputDevice(id: UInt32) -> Bool

    func getVolume(deviceID: UInt32) -> Float?
    func setVolume(deviceID: UInt32, volume: Float) -> Bool
    func isMuted(deviceID: UInt32) -> Bool?
    func setMuted(deviceID: UInt32, muted: Bool) -> Bool

    func getSampleRate(deviceID: UInt32) -> Double?
    func setSampleRate(deviceID: UInt32, rate: Double) -> Bool

    func dataSources(forDeviceID: UInt32) -> [AudioDataSourceInfo]
    func currentDataSource(forDeviceID: UInt32) -> AudioDataSourceInfo?
    func setDataSource(deviceID: UInt32, dataSourceID: UInt32) -> Bool

    func isInUse(deviceID: UInt32) -> Bool?

    func addDeviceChangeCallback(callback: @escaping (UInt32) -> Void) -> UInt64
    func removeDeviceChangeCallback(id: UInt64) -> Bool
}
