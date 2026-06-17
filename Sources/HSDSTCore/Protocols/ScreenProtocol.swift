import Foundation

public struct ScreenInfo: Sendable {
    public var id: UInt32
    public var name: String
    public var frame: (x: Double, y: Double, width: Double, height: Double)
    public var visibleFrame: (x: Double, y: Double, width: Double, height: Double)
    public var scaleFactor: Double
    public var isBuiltIn: Bool
    public var rotation: Double
    public var brightness: Double
    public var colorSpaceName: String

    public init(id: UInt32 = 1, name: String = "Builtin Retina Display",
                frame: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 1440, 900),
                visibleFrame: (x: Double, y: Double, width: Double, height: Double) = (0, 25, 1440, 875),
                scaleFactor: Double = 2.0, isBuiltIn: Bool = true,
                rotation: Double = 0, brightness: Double = 0.75,
                colorSpaceName: String = "sRGB IEC61966-2.1") {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scaleFactor = scaleFactor
        self.isBuiltIn = isBuiltIn
        self.rotation = rotation
        self.brightness = brightness
        self.colorSpaceName = colorSpaceName
    }
}

public struct DisplayModeInfo: Sendable {
    public var modeNumber: Int32
    public var width: UInt32
    public var height: UInt32
    public var depth: UInt32
    public var frequency: UInt16
    public var density: Float
    public var isCurrent: Bool

    public init(modeNumber: Int32 = 0, width: UInt32 = 1440, height: UInt32 = 900,
                depth: UInt32 = 4, frequency: UInt16 = 60, density: Float = 2.0,
                isCurrent: Bool = false) {
        self.modeNumber = modeNumber
        self.width = width
        self.height = height
        self.depth = depth
        self.frequency = frequency
        self.density = density
        self.isCurrent = isCurrent
    }
}

public struct GammaTable: Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float] = [], green: [Float] = [], blue: [Float] = []) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public protocol ScreenProtocol: AnyObject {
    // MARK: - Screen enumeration
    func allScreens() -> [ScreenInfo]
    func mainScreen() -> ScreenInfo?
    func primaryScreen() -> ScreenInfo?
    func screenInfo(forScreenID id: UInt32) -> ScreenInfo?

    // MARK: - Brightness
    func getBrightness(forScreenID id: UInt32) -> Float?
    func setBrightness(_ value: Double, forScreenID id: UInt32) -> Bool

    // MARK: - Rotation
    func getRotation(forScreenID id: UInt32) -> Double
    func setRotation(_ degrees: Double, forScreenID id: UInt32) -> Bool

    // MARK: - Display modes
    func availableDisplayModes(forScreenID id: UInt32) -> [DisplayModeInfo]
    func currentDisplayMode(forScreenID id: UInt32) -> DisplayModeInfo?
    func setDisplayMode(_ modeNumber: Int32, forScreenID id: UInt32) -> Bool

    // MARK: - Gamma
    func getGammaTable(forScreenID id: UInt32) -> GammaTable?
    func setGammaTable(_ table: GammaTable, forScreenID id: UInt32) -> Bool
    func restoreGamma()

    // MARK: - Accessibility display settings
    func usesForceToGray() -> Bool
    func setForceToGray(_ enabled: Bool)
    func usesInvertedPolarity() -> Bool
    func setInvertedPolarity(_ enabled: Bool)
    func accessibilityDisplaySettings() -> [String: Bool]

    // MARK: - Screen capture
    func captureScreenRect(displayID: UInt32, rect: (x: Double, y: Double, width: Double, height: Double)) -> Data?

    // MARK: - UUID
    func getUUID(forScreenID id: UInt32) -> String?

    // MARK: - Display info (IOKit-derived)
    func getDisplayInfo(forScreenID id: UInt32) -> [String: Any]?

    // MARK: - Display topology (setPrimary, setOrigin, mirroring)
    func setPrimary(screenID: UInt32) -> Bool
    func setOrigin(screenID: UInt32, x: Int32, y: Int32) -> Bool
    func mirrorOf(targetScreenID: UInt32, sourceScreenID: UInt32, permanent: Bool) -> Bool
    func mirrorStop(screenID: UInt32, permanent: Bool) -> Bool

    // MARK: - Desktop image
    func desktopImageURL(forScreenID id: UInt32) -> String?
    func setDesktopImageURL(_ url: String, forScreenID id: UInt32) -> Bool

    // MARK: - Spaces
    func currentSpaceID(forScreenID id: UInt32) -> Int?

    // MARK: - Display bounds (for coordinate calculations in setPrimary)
    func displayBounds(forScreenID id: UInt32) -> (x: Double, y: Double, width: Double, height: Double)
    func mainDisplayID() -> UInt32
    func onlineDisplayIDs() -> [UInt32]
}
