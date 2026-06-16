import Cocoa
import HSDSTCore

final class ProductionScreen: ScreenProtocol {
    func allScreens() -> [ScreenInfo] {
        NSScreen.screens.map { screenInfoFrom($0) }
    }

    func mainScreen() -> ScreenInfo? {
        NSScreen.main.map { screenInfoFrom($0) }
    }

    func primaryScreen() -> ScreenInfo? {
        NSScreen.screens.first.map { screenInfoFrom($0) }
    }

    func setBrightness(_ value: Double, forScreenID id: UInt32) -> Bool {
        // Stub — actual implementation uses CoreDisplay private API
        false
    }

    func setRotation(_ degrees: Double, forScreenID id: UInt32) -> Bool {
        // Stub — actual implementation uses CoreGraphics private API
        false
    }

    func currentSpaceID(forScreenID id: UInt32) -> Int? {
        nil
    }

    func availableDisplayModes(forScreenID id: UInt32) -> [DisplayModeInfo] { [] }
    func currentDisplayMode(forScreenID id: UInt32) -> DisplayModeInfo? { nil }
    func setDisplayMode(_ modeNumber: Int32, forScreenID id: UInt32) -> Bool { false }

    func getGammaTable(forScreenID id: UInt32) -> GammaTable? { nil }
    func setGammaTable(_ table: GammaTable, forScreenID id: UInt32) -> Bool { false }
    func restoreGamma() {}

    func usesForceToGray() -> Bool { false }
    func setForceToGray(_ enabled: Bool) {}
    func usesInvertedPolarity() -> Bool { false }
    func setInvertedPolarity(_ enabled: Bool) {}

    func captureScreenRect(displayID: UInt32, rect: (x: Double, y: Double, width: Double, height: Double)) -> Data? { nil }

    private func screenInfoFrom(_ screen: NSScreen) -> ScreenInfo {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        let f = screen.frame
        let vf = screen.visibleFrame
        return ScreenInfo(
            id: id,
            name: screen.localizedName,
            frame: (f.origin.x, f.origin.y, f.size.width, f.size.height),
            visibleFrame: (vf.origin.x, vf.origin.y, vf.size.width, vf.size.height),
            scaleFactor: screen.backingScaleFactor,
            isBuiltIn: id == CGMainDisplayID(),
            rotation: 0,
            brightness: 0.5,
            colorSpaceName: screen.colorSpace?.localizedName ?? "sRGB"
        )
    }
}
