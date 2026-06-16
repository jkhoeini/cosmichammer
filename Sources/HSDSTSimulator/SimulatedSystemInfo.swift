import Foundation
import HSDSTCore

public final class SimulatedSystemInfo: SystemInfoProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var battery: BatteryInfo? = BatteryInfo()
    public var wifi: WifiInfo? = WifiInfo()
    public var audioDeviceList: [AudioDeviceInfo] = [AudioDeviceInfo()]
    public var host: String = "test-mac.local"
    public var addressList: [String] = ["192.168.1.100", "::1"]
    public var osVersion: (major: Int, minor: Int, patch: Int) = (26, 0, 0)
    public var uptime: TimeInterval = 86400
    public var mouseDevices: [String] = ["Apple Internal::Apple Internal Keyboard / Trackpad"]
    public var mousePos: (x: Double, y: Double) = (500, 400)
    public var scrollDirectionNatural: Bool = true
    public var trackingSpeed: Double = 0.6875

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func hostname() -> String { host }
    public func addresses() -> [String] { addressList }

    public func batteryInfo() -> BatteryInfo? {
        if faults.batteryUnavailable { return nil }
        return battery
    }

    public func wifiInfo() -> WifiInfo? {
        if faults.wifiUnavailable { return nil }
        return wifi
    }

    public func audioDevices() -> [AudioDeviceInfo] { audioDeviceList }

    public func setAudioDeviceVolume(uid: String, volume: Float) -> Bool {
        guard let idx = audioDeviceList.firstIndex(where: { $0.uid == uid }) else { return false }
        audioDeviceList[idx] = AudioDeviceInfo(
            uid: uid, name: audioDeviceList[idx].name,
            isInput: audioDeviceList[idx].isInput, isOutput: audioDeviceList[idx].isOutput,
            volume: volume, isMuted: audioDeviceList[idx].isMuted,
            sampleRate: audioDeviceList[idx].sampleRate, isDefault: audioDeviceList[idx].isDefault
        )
        return true
    }

    public func setAudioDeviceMuted(uid: String, muted: Bool) -> Bool {
        guard let idx = audioDeviceList.firstIndex(where: { $0.uid == uid }) else { return false }
        audioDeviceList[idx] = AudioDeviceInfo(
            uid: uid, name: audioDeviceList[idx].name,
            isInput: audioDeviceList[idx].isInput, isOutput: audioDeviceList[idx].isOutput,
            volume: audioDeviceList[idx].volume, isMuted: muted,
            sampleRate: audioDeviceList[idx].sampleRate, isDefault: audioDeviceList[idx].isDefault
        )
        return true
    }

    public func thermalState() -> Int { 0 }
    public func systemUptime() -> TimeInterval { uptime }
    public func operatingSystemVersion() -> (major: Int, minor: Int, patch: Int) { osVersion }

    public func mouseDeviceNames() -> [String] { mouseDevices }
    public func mouseDeviceCount() -> Int { mouseDevices.count }
    public func hasInternalMouse() -> Bool { mouseDevices.contains { $0.contains("Apple Internal") } }

    public func mousePosition() -> (x: Double, y: Double) { mousePos }
    public func setMousePosition(x: Double, y: Double) { mousePos = (x, y) }
    public func isScrollDirectionNatural() -> Bool { scrollDirectionNatural }

    public func mouseTrackingSpeed() -> Double { trackingSpeed }
    @discardableResult
    public func setMouseTrackingSpeed(_ speed: Double) -> Bool {
        trackingSpeed = speed
        return true
    }
}
