import Foundation

public struct AppInfo: Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var processIdentifier: Int32
    public var isActive: Bool
    public var isHidden: Bool
    public var isFinishedLaunching: Bool
    public var ownsMenuBar: Bool
    public var bundlePath: String?
    public var executablePath: String?
    public var launchDate: Date?
    public var activationPolicy: Int
    public var localizedName: String?

    public init(name: String, bundleIdentifier: String? = nil,
                processIdentifier: Int32 = 0, isActive: Bool = false,
                isHidden: Bool = false, isFinishedLaunching: Bool = true,
                ownsMenuBar: Bool = false, bundlePath: String? = nil,
                executablePath: String? = nil, launchDate: Date? = nil,
                activationPolicy: Int = 0, localizedName: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.isActive = isActive
        self.isHidden = isHidden
        self.isFinishedLaunching = isFinishedLaunching
        self.ownsMenuBar = ownsMenuBar
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.launchDate = launchDate
        self.activationPolicy = activationPolicy
        self.localizedName = localizedName
    }
}

public struct WindowInfo: Sendable {
    public var windowID: UInt32
    public var ownerPID: Int32
    public var ownerName: String
    public var title: String?
    public var frame: (x: Double, y: Double, width: Double, height: Double)
    public var layer: Int
    public var isOnScreen: Bool
    public var alpha: Double

    public init(windowID: UInt32, ownerPID: Int32, ownerName: String,
                title: String? = nil,
                frame: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 800, 600),
                layer: Int = 0, isOnScreen: Bool = true, alpha: Double = 1.0) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.alpha = alpha
    }
}

public protocol WorkspaceProtocol: AnyObject {
    func runningApplications() -> [AppInfo]
    func frontmostApplication() -> AppInfo?
    func openURL(_ url: String) -> Bool
    func openFile(_ path: String) -> Bool
    func launchApplication(bundleIdentifier: String) -> Bool
    func terminateApplication(pid: Int32) -> Bool
    func hideApplication(pid: Int32) -> Bool
    func unhideApplication(pid: Int32) -> Bool
    func activateApplication(pid: Int32) -> Bool
    func windowList(options: UInt32) -> [WindowInfo]

    func applicationForPID(_ pid: Int32) -> AppInfo?
    func applicationForBundleIdentifier(_ bundleID: String) -> AppInfo?

    func setApplicationHidden(_ hidden: Bool, pid: Int32) -> Bool
    func forceTerminateApplication(pid: Int32) -> Bool

    func windowInfo(forID windowID: UInt32) -> WindowInfo?
    func setWindowPosition(_ position: (x: Double, y: Double), windowID: UInt32) -> Bool
    func setWindowSize(_ size: (width: Double, height: Double), windowID: UInt32) -> Bool
    func minimizeWindow(windowID: UInt32) -> Bool
    func closeWindow(windowID: UInt32) -> Bool

    func urlForApplicationWithBundleIdentifier(_ bundleID: String) -> String?
    func fullPathForApplication(_ appName: String) -> String?

    func desktopImagePath(forScreenID screenID: UInt32) -> String?
    func setDesktopImagePath(_ path: String, forScreenID screenID: UInt32) -> Bool
}

public extension WorkspaceProtocol {
    func applicationForPID(_ pid: Int32) -> AppInfo? { nil }
    func applicationForBundleIdentifier(_ bundleID: String) -> AppInfo? { nil }
    func setApplicationHidden(_ hidden: Bool, pid: Int32) -> Bool { false }
    func forceTerminateApplication(pid: Int32) -> Bool { false }
    func windowInfo(forID windowID: UInt32) -> WindowInfo? { nil }
    func setWindowPosition(_ position: (x: Double, y: Double), windowID: UInt32) -> Bool { false }
    func setWindowSize(_ size: (width: Double, height: Double), windowID: UInt32) -> Bool { false }
    func minimizeWindow(windowID: UInt32) -> Bool { false }
    func closeWindow(windowID: UInt32) -> Bool { false }
    func urlForApplicationWithBundleIdentifier(_ bundleID: String) -> String? { nil }
    func fullPathForApplication(_ appName: String) -> String? { nil }
    func desktopImagePath(forScreenID screenID: UInt32) -> String? { nil }
    func setDesktopImagePath(_ path: String, forScreenID screenID: UInt32) -> Bool { false }
}
