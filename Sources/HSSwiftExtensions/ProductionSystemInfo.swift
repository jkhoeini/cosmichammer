import Cocoa
import Foundation
import HSDSTCore
import IOKit
import IOKit.hid

final class ProductionSystemInfo: SystemInfoProtocol {
    func hostname() -> String {
        ProcessInfo.processInfo.hostName
    }

    func addresses() -> [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addrs }
        defer { freeifaddrs(first) }
        var ptr = first
        while true {
            let family = Int32(ptr.pointee.ifa_addr.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                addrs.append(String(cString: hostname))
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return addrs
    }

    func batteryInfo() -> BatteryInfo? { nil }
    func wifiInfo() -> WifiInfo? { nil }
    func audioDevices() -> [AudioDeviceInfo] { [] }
    func setAudioDeviceVolume(uid: String, volume: Float) -> Bool { false }
    func setAudioDeviceMuted(uid: String, muted: Bool) -> Bool { false }
    func thermalState() -> Int { ProcessInfo.processInfo.thermalState.rawValue }
    func systemUptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func operatingSystemVersion() -> (major: Int, minor: Int, patch: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }

    private let mouse = HSmouse()

    func mouseDeviceNames() -> [String] { mouse.getNames() }
    func mouseDeviceCount() -> Int { mouse.count }
    func hasInternalMouse() -> Bool { mouse.hasInternalMouse }

    func mousePosition() -> (x: Double, y: Double) {
        let p = mouse.absolutePosition
        return (Double(p.x), Double(p.y))
    }

    func setMousePosition(x: Double, y: Double) {
        mouse.absolutePosition = NSPoint(x: x, y: y)
    }

    func isScrollDirectionNatural() -> Bool { mouse.isScrollDirectionNatural }

    func mouseTrackingSpeed() -> Double { mouse.trackingSpeed }

    func setMouseTrackingSpeed(_ speed: Double) -> Bool {
        mouse.setTrackingSpeed(speed) == KERN_SUCCESS
    }
}
