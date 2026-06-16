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
    public var gammaTables: [UInt32: GammaTable] = [:]
    public var forceToGray: Bool = false
    public var invertedPolarity: Bool = false
    public var capturedRects: [(displayID: UInt32, rect: (x: Double, y: Double, width: Double, height: Double))] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func allScreens() -> [ScreenInfo] { screens }

    public func mainScreen() -> ScreenInfo? { screens.first { $0.id == mainScreenID } }

    public func primaryScreen() -> ScreenInfo? { screens.first }

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

    public func currentSpaceID(forScreenID id: UInt32) -> Int? { spaceIDs[id] }

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

    public func getGammaTable(forScreenID id: UInt32) -> GammaTable? {
        gammaTables[id]
    }

    public func setGammaTable(_ table: GammaTable, forScreenID id: UInt32) -> Bool {
        gammaTables[id] = table
        return true
    }

    public func restoreGamma() {
        gammaTables.removeAll()
    }

    public func usesForceToGray() -> Bool { forceToGray }

    public func setForceToGray(_ enabled: Bool) { forceToGray = enabled }

    public func usesInvertedPolarity() -> Bool { invertedPolarity }

    public func setInvertedPolarity(_ enabled: Bool) { invertedPolarity = enabled }

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
}
