import Foundation

/// Value type representing a menu item in an application's menu bar.
public struct AppMenuItemInfo: Sendable {
    public var title: String?
    public var role: String?
    public var enabled: Bool
    public var marked: Bool
    public var cmdChar: String?
    public var cmdModifiers: [String]?
    public var cmdGlyph: String?
    public var children: [AppMenuItemInfo]?

    public init(title: String? = nil, role: String? = "AXMenuItem",
                enabled: Bool = true, marked: Bool = false,
                cmdChar: String? = nil, cmdModifiers: [String]? = nil,
                cmdGlyph: String? = nil, children: [AppMenuItemInfo]? = nil) {
        self.title = title
        self.role = role
        self.enabled = enabled
        self.marked = marked
        self.cmdChar = cmdChar
        self.cmdModifiers = cmdModifiers
        self.cmdGlyph = cmdGlyph
        self.children = children
    }
}

/// Value type representing an application's identity and state.
public struct ApplicationInfo: Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var path: String?
    public var isHidden: Bool
    public var isFrontmost: Bool
    public var isRunning: Bool
    public var kind: Int32  // 1 = regular, 0 = accessory, -1 = prohibited
    public var isResponsive: Bool

    public init(pid: Int32 = 0, bundleID: String? = nil, name: String? = nil,
                path: String? = nil, isHidden: Bool = false, isFrontmost: Bool = false,
                isRunning: Bool = true, kind: Int32 = 1, isResponsive: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.isHidden = isHidden
        self.isFrontmost = isFrontmost
        self.isRunning = isRunning
        self.kind = kind
        self.isResponsive = isResponsive
    }
}

/// Protocol abstracting application lifecycle, menu queries, and bundle info.
///
/// The production implementation delegates to NSRunningApplication, NSWorkspace,
/// and AXUIElement.  The simulator maintains in-memory application state.
public protocol ApplicationProtocol: AnyObject {
    // MARK: - Application lookup

    func frontmostApplication() -> ApplicationInfo?
    func runningApplications() -> [ApplicationInfo]
    func applicationForPID(_ pid: Int32) -> ApplicationInfo?
    func applicationsForBundleID(_ bundleID: String) -> [ApplicationInfo]

    // MARK: - Bundle info (static lookups, no running app needed)

    func nameForBundleID(_ bundleID: String) -> String?
    func pathForBundleID(_ bundleID: String) -> String?
    func infoForBundleID(_ bundleID: String) -> [String: Any]?
    func infoForBundlePath(_ bundlePath: String) -> [String: Any]?
    func preferredLocalizationsForBundleID(_ bundleID: String) -> [String]?
    func preferredLocalizationsForBundlePath(_ bundlePath: String) -> [String]?
    func localizationsForBundleID(_ bundleID: String) -> [String]?
    func localizationsForBundlePath(_ bundlePath: String) -> [String]?

    // MARK: - Launch Services

    func defaultAppForUTI(_ uti: String) -> String?

    // MARK: - App launch

    func launchOrFocus(_ name: String) -> Bool
    func launchOrFocusByBundleID(_ bundleID: String) -> Bool

    // MARK: - Instance operations (identified by PID)

    func activate(pid: Int32, allWindows: Bool) -> Bool
    func setFrontmost(pid: Int32, allWindows: Bool) -> Bool
    func hide(pid: Int32) -> Bool
    func unhide(pid: Int32) -> Bool
    func isHidden(pid: Int32) -> Bool
    func isFrontmost(pid: Int32) -> Bool
    func kill(pid: Int32)
    func kill9(pid: Int32)
    func isRunning(pid: Int32) -> Bool
    func isResponsive(pid: Int32) -> Bool
    func kind(pid: Int32) -> Int32
    func title(pid: Int32) -> String?
    func bundleID(pid: Int32) -> String?
    func path(pid: Int32) -> String?

    // MARK: - Window queries (app-scoped)

    func allWindows(pid: Int32) -> [AXWindowInfo]
    func mainWindow(pid: Int32) -> AXWindowInfo?
    func focusedWindow(pid: Int32) -> AXWindowInfo?

    // MARK: - Menu queries

    func getMenuItems(pid: Int32) -> [[String: Any]]?
    func findMenuItemByPath(pid: Int32, path: [String]) -> (enabled: Bool, marked: Bool)?
    func findMenuItemByName(pid: Int32, name: String, isRegex: Bool) -> (enabled: Bool, marked: Bool)?
    func selectMenuItemByPath(pid: Int32, path: [String]) -> Bool
    func selectMenuItemByName(pid: Int32, name: String, isRegex: Bool) -> Bool

}

