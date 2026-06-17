import Foundation
import HSDSTCore

public final class SimulatedScreen: ScreenProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var screens: [ScreenInfo] = [ScreenInfo()]
    public var mainScreenID: UInt32 = 1
    public var spaceIDs: [UInt32: Int] = [1: 1]

    public var displayModes: [UInt32: [DisplayModeInfo]] = [
        1: [
            DisplayModeInfo(modeNumber: 0, width: 1440, height: 900, depth: 4, frequency: 60, density: 2.0, isCurrent: true),
            DisplayModeInfo(modeNumber: 1, width: 2560, height: 1600, depth: 4, frequency: 60, density: 2.0),
            DisplayModeInfo(modeNumber: 2, width: 1024, height: 768, depth: 4, frequency: 60, density: 1.0),
        ]
    ]
    public var currentModes: [UInt32: Int32] = [1: 0]
    public var gammaTables: [UInt32: GammaTable] = [1: SimulatedScreen.linearGammaRamp()]
    public var forceToGray: Bool = false
    public var invertedPolarity: Bool = false
    public var capturedRects: [(displayID: UInt32, rect: (x: Double, y: Double, width: Double, height: Double))] = []
    public var desktopImages: [UInt32: String] = [:]
    public var uuids: [UInt32: String] = [1: "37D8832A-2D66-02CA-B9F7-8F30A301B230"]
    public var displayInfos: [UInt32: [String: Any]] = [:]
    public var primaryScreenID: UInt32 = 1

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    /// Returns a 256-entry linear gamma ramp (0.0 ... 1.0) for R/G/B,
    /// matching a typical uncalibrated display's default gamma table.
    public static func linearGammaRamp(sampleCount: Int = 256) -> GammaTable {
        let ramp = (0..<sampleCount).map { Float($0) / Float(sampleCount - 1) }
        return GammaTable(red: ramp, green: ramp, blue: ramp)
    }

    // MARK: - Screen enumeration

    public func allScreens() -> [ScreenInfo] { screens }

    public func mainScreen() -> ScreenInfo? { screens.first { $0.id == mainScreenID } }

    public func primaryScreen() -> ScreenInfo? { screens.first }

    public func screenInfo(forScreenID id: UInt32) -> ScreenInfo? {
        screens.first { $0.id == id }
    }

    // MARK: - Brightness

    public func getBrightness(forScreenID id: UInt32) -> Float? {
        guard let screen = screens.first(where: { $0.id == id }) else { return nil }
        return Float(screen.brightness)
    }

    public func setBrightness(_ value: Double, forScreenID id: UInt32) -> Bool {
        if rng.boolean(probability: faults.brightnessSetFailProbability) { return false }
        guard let idx = screens.firstIndex(where: { $0.id == id }) else { return false }
        screens[idx] = ScreenInfo(
            id: id, name: screens[idx].name, frame: screens[idx].frame,
            visibleFrame: screens[idx].visibleFrame, scaleFactor: screens[idx].scaleFactor,
            isBuiltIn: screens[idx].isBuiltIn, rotation: screens[idx].rotation,
            brightness: value, colorSpaceName: screens[idx].colorSpaceName
        )
        return true
    }

    // MARK: - Rotation

    public func getRotation(forScreenID id: UInt32) -> Double {
        screens.first(where: { $0.id == id })?.rotation ?? 0
    }

    public func setRotation(_ degrees: Double, forScreenID id: UInt32) -> Bool {
        guard let idx = screens.firstIndex(where: { $0.id == id }) else { return false }
        screens[idx] = ScreenInfo(
            id: id, name: screens[idx].name, frame: screens[idx].frame,
            visibleFrame: screens[idx].visibleFrame, scaleFactor: screens[idx].scaleFactor,
            isBuiltIn: screens[idx].isBuiltIn, rotation: degrees,
            brightness: screens[idx].brightness, colorSpaceName: screens[idx].colorSpaceName
        )
        return true
    }

    // MARK: - Display modes

    public func availableDisplayModes(forScreenID id: UInt32) -> [DisplayModeInfo] {
        displayModes[id] ?? []
    }

    public func currentDisplayMode(forScreenID id: UInt32) -> DisplayModeInfo? {
        guard let modeNumber = currentModes[id],
              let modes = displayModes[id] else { return nil }
        return modes.first { $0.modeNumber == modeNumber }
    }

    public func setDisplayMode(_ modeNumber: Int32, forScreenID id: UInt32) -> Bool {
        currentModes[id] = modeNumber
        return true
    }

    // MARK: - Gamma

    public func getGammaTable(forScreenID id: UInt32) -> GammaTable? {
        gammaTables[id]
    }

    public func setGammaTable(_ table: GammaTable, forScreenID id: UInt32) -> Bool {
        gammaTables[id] = table
        return true
    }

    public func restoreGamma() {
        for id in screens.map(\.id) {
            gammaTables[id] = SimulatedScreen.linearGammaRamp()
        }
    }

    // MARK: - Accessibility

    public func usesForceToGray() -> Bool { forceToGray }

    public func setForceToGray(_ enabled: Bool) { forceToGray = enabled }

    public func usesInvertedPolarity() -> Bool { invertedPolarity }

    public func setInvertedPolarity(_ enabled: Bool) { invertedPolarity = enabled }

    public func accessibilityDisplaySettings() -> [String: Bool] {
        [
            "InvertColors": false,
            "ReduceMotion": false,
            "ReduceTransparency": false,
            "IncreaseContrast": false,
            "DifferentiateWithoutColor": false,
        ]
    }

    // MARK: - Screen capture

    public func captureScreenRect(displayID: UInt32, rect: (x: Double, y: Double, width: Double, height: Double)) -> Data? {
        capturedRects.append((displayID: displayID, rect: rect))
        let pngStub: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ]
        return Data(pngStub)
    }

    // MARK: - UUID

    public func getUUID(forScreenID id: UInt32) -> String? {
        uuids[id]
    }

    // MARK: - Display info

    public func getDisplayInfo(forScreenID id: UInt32) -> [String: Any]? {
        displayInfos[id]
    }

    // MARK: - Display topology

    public func setPrimary(screenID: UInt32) -> Bool {
        primaryScreenID = screenID
        return true
    }

    public func setOrigin(screenID: UInt32, x: Int32, y: Int32) -> Bool {
        guard let idx = screens.firstIndex(where: { $0.id == screenID }) else { return false }
        let s = screens[idx]
        screens[idx] = ScreenInfo(
            id: s.id, name: s.name,
            frame: (Double(x), Double(y), s.frame.width, s.frame.height),
            visibleFrame: (Double(x), Double(y) + 25, s.visibleFrame.width, s.visibleFrame.height),
            scaleFactor: s.scaleFactor, isBuiltIn: s.isBuiltIn, rotation: s.rotation,
            brightness: s.brightness, colorSpaceName: s.colorSpaceName
        )
        return true
    }

    public func mirrorOf(targetScreenID: UInt32, sourceScreenID: UInt32, permanent: Bool) -> Bool {
        return screens.contains(where: { $0.id == targetScreenID }) &&
               screens.contains(where: { $0.id == sourceScreenID })
    }

    public func mirrorStop(screenID: UInt32, permanent: Bool) -> Bool {
        return screens.contains(where: { $0.id == screenID })
    }

    // MARK: - Desktop image

    public func desktopImageURL(forScreenID id: UInt32) -> String? {
        desktopImages[id]
    }

    public func setDesktopImageURL(_ url: String, forScreenID id: UInt32) -> Bool {
        desktopImages[id] = url
        return true
    }

    // MARK: - Spaces

    public func currentSpaceID(forScreenID id: UInt32) -> Int? { spaceIDs[id] }

    // MARK: - Display bounds / topology helpers

    public func displayBounds(forScreenID id: UInt32) -> (x: Double, y: Double, width: Double, height: Double) {
        guard let screen = screens.first(where: { $0.id == id }) else {
            return (0, 0, 0, 0)
        }
        return screen.frame
    }

    public func mainDisplayID() -> UInt32 {
        primaryScreenID
    }

    public func onlineDisplayIDs() -> [UInt32] {
        screens.map { $0.id }
    }
}
