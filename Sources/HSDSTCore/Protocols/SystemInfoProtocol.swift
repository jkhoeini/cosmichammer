import Foundation

public struct BatteryInfo: Sendable {
    public var percentage: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var timeToFullCharge: Int?
    public var timeToEmpty: Int?
    public var powerSource: String
    public var health: String
    public var cycleCount: Int

    public init(percentage: Double = 85, isCharging: Bool = false,
                isPluggedIn: Bool = true, timeToFullCharge: Int? = nil,
                timeToEmpty: Int? = 240, powerSource: String = "AC Power",
                health: String = "Good", cycleCount: Int = 200) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.timeToFullCharge = timeToFullCharge
        self.timeToEmpty = timeToEmpty
        self.powerSource = powerSource
        self.health = health
        self.cycleCount = cycleCount
    }
}

public struct WifiInfo: Sendable {
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int
    public var noise: Int
    public var channel: Int
    public var interfaceName: String
    public var isPoweredOn: Bool

    public init(ssid: String? = "TestNetwork", bssid: String? = "00:11:22:33:44:55",
                rssi: Int = -55, noise: Int = -90, channel: Int = 6,
                interfaceName: String = "en0", isPoweredOn: Bool = true) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.interfaceName = interfaceName
        self.isPoweredOn = isPoweredOn
    }
}

public struct AudioDeviceInfo: Sendable {
    public var uid: String
    public var name: String
    public var isInput: Bool
    public var isOutput: Bool
    public var volume: Float
    public var isMuted: Bool
    public var sampleRate: Double
    public var isDefault: Bool

    public init(uid: String = "BuiltInSpeaker", name: String = "Built-in Output",
                isInput: Bool = false, isOutput: Bool = true,
                volume: Float = 0.75, isMuted: Bool = false,
                sampleRate: Double = 44100, isDefault: Bool = true) {
        self.uid = uid
        self.name = name
        self.isInput = isInput
        self.isOutput = isOutput
        self.volume = volume
        self.isMuted = isMuted
        self.sampleRate = sampleRate
        self.isDefault = isDefault
    }
}

public protocol SystemInfoProtocol: AnyObject {
    func hostname() -> String
    func addresses() -> [String]
    func batteryInfo() -> BatteryInfo?
    func wifiInfo() -> WifiInfo?
    func audioDevices() -> [AudioDeviceInfo]
    func setAudioDeviceVolume(uid: String, volume: Float) -> Bool
    func setAudioDeviceMuted(uid: String, muted: Bool) -> Bool
    func thermalState() -> Int
    func systemUptime() -> TimeInterval
    func operatingSystemVersion() -> (major: Int, minor: Int, patch: Int)

    func mouseDeviceNames() -> [String]
    func mouseDeviceCount() -> Int
    func hasInternalMouse() -> Bool

    func mousePosition() -> (x: Double, y: Double)
    func setMousePosition(x: Double, y: Double)
    func isScrollDirectionNatural() -> Bool

    func mouseTrackingSpeed() -> Double
    func setMouseTrackingSpeed(_ speed: Double) -> Bool
}
