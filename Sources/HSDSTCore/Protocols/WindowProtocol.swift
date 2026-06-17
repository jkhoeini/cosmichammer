import Foundation

public struct AXWindowInfo: Sendable {
    public var id: UInt32
    public var title: String?
    public var role: String
    public var subrole: String?
    public var frame: (x: Double, y: Double, width: Double, height: Double)
    public var pid: Int32
    public var isMinimized: Bool
    public var isFullScreen: Bool
    public var level: Int
    public var alpha: Double
    public var isStandard: Bool
    public var isVisible: Bool
    public var isMaximizable: Bool
    public var tabCount: Int32
    public var cornerRadius: Double

    public init(id: UInt32 = 1, title: String? = "Untitled",
                role: String = "AXWindow", subrole: String? = "AXStandardWindow",
                frame: (x: Double, y: Double, width: Double, height: Double) = (100, 100, 800, 600),
                pid: Int32 = 100,
                isMinimized: Bool = false, isFullScreen: Bool = false,
                level: Int = 0, alpha: Double = 1.0,
                isStandard: Bool = true, isVisible: Bool = true,
                isMaximizable: Bool = true, tabCount: Int32 = 0,
                cornerRadius: Double = 10.0) {
        self.id = id
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.pid = pid
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.level = level
        self.alpha = alpha
        self.isStandard = isStandard
        self.isVisible = isVisible
        self.isMaximizable = isMaximizable
        self.tabCount = tabCount
        self.cornerRadius = cornerRadius
    }
}

public protocol WindowProtocol: AnyObject {
    // MARK: - Window creation (simulator only; production returns 0)

    func createWindow(title: String, pid: Int32, role: String, subrole: String?,
                      frame: (x: Double, y: Double, width: Double, height: Double)) -> UInt32

    // MARK: - Desktop

    func desktopWindow() -> AXWindowInfo?

    // MARK: - Listing and lookup

    func allWindows() -> [AXWindowInfo]
    func focusedWindow() -> AXWindowInfo?
    func orderedWindowIDs() -> [UInt32]
    func windowInfo(forID id: UInt32) -> AXWindowInfo?
    func windows(forAppPID pid: Int32) -> [AXWindowInfo]

    // MARK: - Position and size

    func setTopLeft(_ point: (x: Double, y: Double), forWindowID id: UInt32) -> Bool
    func setSize(_ size: (width: Double, height: Double), forWindowID id: UInt32) -> Bool
    func setFrame(_ frame: (x: Double, y: Double, width: Double, height: Double), forWindowID id: UInt32) -> Bool

    // MARK: - State changes

    func minimize(windowID: UInt32) -> Bool
    func unminimize(windowID: UInt32) -> Bool
    func close(windowID: UInt32) -> Bool
    func raise(windowID: UInt32) -> Bool
    func focus(windowID: UInt32) -> Bool
    func toggleZoom(windowID: UInt32) -> Bool
    func setFullScreen(_ fullScreen: Bool, forWindowID id: UInt32) -> Bool

    // MARK: - Shadows

    func setShadows(_ enabled: Bool)

    // MARK: - Timeout

    func setTimeout(_ seconds: Float) -> Bool

    // MARK: - Tabs

    func focusTab(_ tabIndex: Int32, forWindowID id: UInt32) -> Bool

    // MARK: - Snapshot

    func snapshot(windowID: UInt32, keepTransparency: Bool) -> Data?
    func snapshotForID(_ windowID: UInt32, keepTransparency: Bool) -> Data?

    // MARK: - Corner radius

    func cornerRadius(forWindowID id: UInt32) -> Double

    // MARK: - Spaces

    func spaces(forWindowID id: UInt32) -> [Int]

    // MARK: - Additional window operations

    func becomeMain(windowID: UInt32) -> Bool
    func zoomButtonRect(forWindowID id: UInt32) -> (x: Double, y: Double, width: Double, height: Double)?
    func isMaximizable(forWindowID id: UInt32) -> Bool?

    // MARK: - CGWindowList-based listing (non-AX)

    /// Returns raw CGWindowList info dictionaries for on-screen windows.
    /// When `allWindows` is true, returns all on-screen windows.
    /// When false, returns only windows below the Dock (excluding desktop elements).
    func listWindowInfo(allWindows: Bool) -> [[String: Any]]
}
