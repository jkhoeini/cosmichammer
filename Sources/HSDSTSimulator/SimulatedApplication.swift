import Foundation
import HSDSTCore

/// Deterministic simulator for ApplicationProtocol.
/// Maintains in-memory application state with configurable initial apps, menus, and windows.
public final class SimulatedApplication: ApplicationProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    // MARK: - State

    /// Running applications, keyed by PID.
    public var apps: [Int32: ApplicationInfo] = [:]

    /// Menu structures per PID.  Each entry is a list of top-level menu bar items.
    public var menus: [Int32: [AppMenuItemInfo]] = [:]

    /// Windows per PID.
    public var appWindows: [Int32: [AXWindowInfo]] = [:]

    /// Bundle registry: bundleID -> (name, path, info dict).
    public var bundleRegistry: [String: (name: String, path: String, info: [String: Any], localizations: [String], preferredLocalizations: [String])] = [:]

    /// Path-based bundle registry: bundlePath -> info dict.
    public var pathBundleRegistry: [String: (info: [String: Any], localizations: [String], preferredLocalizations: [String])] = [:]

    /// UTI -> default handler bundle ID.
    public var utiHandlers: [String: String] = [:]

    /// PID of the frontmost app (nil = none).
    public var frontmostPID: Int32?

    /// Auto-incrementing PID for launched apps.
    private var nextPID: Int32 = 1000

    /// Focused window per app (PID -> window index).
    private var focusedWindowIndex: [Int32: Int] = [:]

    // MARK: - Call tracking

    public var launchedApps: [(name: String?, bundleID: String?)] = []
    public var killedPIDs: [Int32] = []
    public var forceKilledPIDs: [Int32] = []
    public var hiddenPIDs: [Int32] = []
    public var unhiddenPIDs: [Int32] = []
    public var activatedPIDs: [(pid: Int32, allWindows: Bool)] = []
    public var selectedMenuItems: [(pid: Int32, path: [String]?, name: String?)] = []

    /// Optional back-reference to the window simulator so that launching a new
    /// GUI app can create a default window in both the Application and Window stores.
    public weak var windowSim: SimulatedWindow?

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Convenience setup

    /// Add a running application to the simulator state.
    @discardableResult
    public func addApp(_ info: ApplicationInfo) -> Int32 {
        let pid = info.pid
        apps[pid] = info
        if info.isFrontmost { frontmostPID = pid }
        return pid
    }

    /// Add a window for an application.
    public func addWindow(forPID pid: Int32, _ window: AXWindowInfo) {
        var wins = appWindows[pid] ?? []
        wins.append(window)
        appWindows[pid] = wins
        // First window is focused by default
        if focusedWindowIndex[pid] == nil {
            focusedWindowIndex[pid] = wins.count - 1
        }
    }

    /// Set the menu structure for an application.
    public func setMenus(forPID pid: Int32, _ menuItems: [AppMenuItemInfo]) {
        menus[pid] = menuItems
    }

    /// Create a default window for a newly launched GUI app, registered in both stores.
    private func createDefaultWindow(forPID pid: Int32, title: String) {
        if let winSim = windowSim {
            // Create through the Window simulator so it gets a unique auto-incremented ID
            // and is accessible via windowInfo(forID:).
            let id = winSim.createWindow(
                title: title, pid: pid,
                role: "AXWindow", subrole: "AXStandardWindow",
                frame: (100, 100, 800, 600)
            )
            // Mirror into appWindows so Application protocol queries (mainWindow, allWindows) find it.
            addWindow(forPID: pid, AXWindowInfo(id: id, title: title, pid: pid))
        } else {
            // Fallback: only register in appWindows (sufficient for mainWindow polling).
            addWindow(forPID: pid, AXWindowInfo(title: title, pid: pid))
        }
    }

    /// Register a bundle by its identifier.
    public func registerBundle(bundleID: String, name: String, path: String,
                               info: [String: Any] = [:],
                               localizations: [String] = ["en"],
                               preferredLocalizations: [String] = ["en"]) {
        bundleRegistry[bundleID] = (name, path, info, localizations, preferredLocalizations)
        pathBundleRegistry[path] = (info, localizations, preferredLocalizations)
    }

    // MARK: - Application lookup

    public func frontmostApplication() -> ApplicationInfo? {
        guard let pid = frontmostPID else { return nil }
        return apps[pid]
    }

    public func runningApplications() -> [ApplicationInfo] {
        Array(apps.values).sorted { $0.pid < $1.pid }
    }

    public func applicationForPID(_ pid: Int32) -> ApplicationInfo? {
        apps[pid]
    }

    public func applicationsForBundleID(_ bundleID: String) -> [ApplicationInfo] {
        apps.values.filter { $0.bundleID == bundleID }.sorted { $0.pid < $1.pid }
    }

    // MARK: - Bundle info

    public func nameForBundleID(_ bundleID: String) -> String? {
        bundleRegistry[bundleID]?.name
    }

    public func pathForBundleID(_ bundleID: String) -> String? {
        bundleRegistry[bundleID]?.path
    }

    public func infoForBundleID(_ bundleID: String) -> [String: Any]? {
        bundleRegistry[bundleID]?.info
    }

    public func infoForBundlePath(_ bundlePath: String) -> [String: Any]? {
        pathBundleRegistry[bundlePath]?.info
    }

    public func preferredLocalizationsForBundleID(_ bundleID: String) -> [String]? {
        bundleRegistry[bundleID]?.preferredLocalizations
    }

    public func preferredLocalizationsForBundlePath(_ bundlePath: String) -> [String]? {
        pathBundleRegistry[bundlePath]?.preferredLocalizations
    }

    public func localizationsForBundleID(_ bundleID: String) -> [String]? {
        bundleRegistry[bundleID]?.localizations
    }

    public func localizationsForBundlePath(_ bundlePath: String) -> [String]? {
        pathBundleRegistry[bundlePath]?.localizations
    }

    // MARK: - Launch Services

    public func defaultAppForUTI(_ uti: String) -> String? {
        utiHandlers[uti]
    }

    // MARK: - App launch

    public func launchOrFocus(_ name: String) -> Bool {
        if faults.appLaunchFailProbability >= 1.0 { return false }
        launchedApps.append((name: name, bundleID: nil))

        // If already running, activate it
        if let existing = apps.values.first(where: { $0.name == name }) {
            frontmostPID = existing.pid
            apps[existing.pid]?.isFrontmost = true
            return true
        }

        // Launch new
        let pid = nextPID
        nextPID += 1
        let bundleID = bundleRegistry.first(where: { $0.value.name == name })?.key
        let path = bundleID.flatMap { bundleRegistry[$0]?.path }
        let app = ApplicationInfo(pid: pid, bundleID: bundleID, name: name, path: path,
                                  isHidden: false, isFrontmost: true, isRunning: true, kind: 1)
        addApp(app)
        // GUI apps (kind == 1) get a default window so callers waiting for mainWindow() don't time out.
        // Create via windowSim so the window is in both the Window protocol and appWindows stores.
        createDefaultWindow(forPID: pid, title: name ?? "Untitled")
        frontmostPID = pid
        return true
    }

    public func launchOrFocusByBundleID(_ bundleID: String) -> Bool {
        if faults.appLaunchFailProbability >= 1.0 { return false }
        launchedApps.append((name: nil, bundleID: bundleID))

        // If already running, activate it
        if let existing = apps.values.first(where: { $0.bundleID == bundleID }) {
            frontmostPID = existing.pid
            apps[existing.pid]?.isFrontmost = true
            return true
        }

        // Launch new
        let pid = nextPID
        nextPID += 1
        let name = bundleRegistry[bundleID]?.name
        let path = bundleRegistry[bundleID]?.path
        let app = ApplicationInfo(pid: pid, bundleID: bundleID, name: name, path: path,
                                  isHidden: false, isFrontmost: true, isRunning: true, kind: 1)
        addApp(app)
        // GUI apps (kind == 1) get a default window so callers waiting for mainWindow() don't time out.
        createDefaultWindow(forPID: pid, title: name ?? "Untitled")
        frontmostPID = pid
        return true
    }

    // MARK: - Instance operations

    public func activate(pid: Int32, allWindows: Bool) -> Bool {
        guard apps[pid] != nil else { return false }
        activatedPIDs.append((pid: pid, allWindows: allWindows))
        frontmostPID = pid
        // Update frontmost state
        for key in apps.keys { apps[key]?.isFrontmost = (key == pid) }
        return true
    }

    public func setFrontmost(pid: Int32, allWindows: Bool) -> Bool {
        activate(pid: pid, allWindows: allWindows)
    }

    public func hide(pid: Int32) -> Bool {
        guard apps[pid] != nil else { return false }
        hiddenPIDs.append(pid)
        apps[pid]?.isHidden = true
        return true
    }

    public func unhide(pid: Int32) -> Bool {
        guard apps[pid] != nil else { return false }
        unhiddenPIDs.append(pid)
        apps[pid]?.isHidden = false
        return true
    }

    public func isHidden(pid: Int32) -> Bool {
        apps[pid]?.isHidden ?? false
    }

    public func isFrontmost(pid: Int32) -> Bool {
        frontmostPID == pid
    }

    public func kill(pid: Int32) {
        guard apps[pid] != nil else { return }
        killedPIDs.append(pid)
        apps[pid]?.isRunning = false
        if frontmostPID == pid { fallbackFrontmost(excluding: pid) }
    }

    public func kill9(pid: Int32) {
        guard apps[pid] != nil else { return }
        forceKilledPIDs.append(pid)
        apps[pid]?.isRunning = false
        if frontmostPID == pid { fallbackFrontmost(excluding: pid) }
    }

    /// After the frontmost app exits, promote the next regular running app.
    private func fallbackFrontmost(excluding pid: Int32) {
        frontmostPID = apps.values
            .first(where: { $0.pid != pid && $0.isRunning && $0.kind >= 0 })?.pid
    }

    public func isRunning(pid: Int32) -> Bool {
        apps[pid]?.isRunning ?? false
    }

    public func isResponsive(pid: Int32) -> Bool {
        apps[pid]?.isResponsive ?? false
    }

    public func kind(pid: Int32) -> Int32 {
        apps[pid]?.kind ?? -1
    }

    public func title(pid: Int32) -> String? {
        apps[pid]?.name
    }

    public func bundleID(pid: Int32) -> String? {
        apps[pid]?.bundleID
    }

    public func path(pid: Int32) -> String? {
        apps[pid]?.path
    }

    // MARK: - Window queries

    public func allWindows(pid: Int32) -> [AXWindowInfo] {
        if faults.accessibilityPermissionDenied { return [] }
        return appWindows[pid] ?? []
    }

    public func mainWindow(pid: Int32) -> AXWindowInfo? {
        if faults.accessibilityPermissionDenied { return nil }
        return appWindows[pid]?.first
    }

    public func focusedWindow(pid: Int32) -> AXWindowInfo? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let wins = appWindows[pid], !wins.isEmpty else { return nil }
        let idx = focusedWindowIndex[pid] ?? 0
        return wins.indices.contains(idx) ? wins[idx] : wins.first
    }

    // MARK: - Menu queries

    public func getMenuItems(pid: Int32) -> [[String: Any]]? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let menuItems = menus[pid], !menuItems.isEmpty else { return nil }
        return menuItems.compactMap { menuItemToDict($0) }
    }

    public func findMenuItemByPath(pid: Int32, path: [String]) -> (enabled: Bool, marked: Bool)? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let menuItems = menus[pid] else { return nil }
        guard let item = resolveMenuPath(menuItems, path) else { return nil }
        return (item.enabled, item.marked)
    }

    public func findMenuItemByName(pid: Int32, name: String, isRegex: Bool) -> (enabled: Bool, marked: Bool)? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let menuItems = menus[pid] else { return nil }
        guard let item = searchMenuByName(menuItems, name, isRegex: isRegex) else { return nil }
        return (item.enabled, item.marked)
    }

    public func selectMenuItemByPath(pid: Int32, path: [String]) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let menuItems = menus[pid] else { return false }
        guard let _ = resolveMenuPath(menuItems, path) else { return false }
        selectedMenuItems.append((pid: pid, path: path, name: nil))
        return true
    }

    public func selectMenuItemByName(pid: Int32, name: String, isRegex: Bool) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let menuItems = menus[pid] else { return false }
        guard let _ = searchMenuByName(menuItems, name, isRegex: isRegex) else { return false }
        selectedMenuItems.append((pid: pid, path: nil, name: name))
        return true
    }

    // MARK: - Private menu helpers

    private func resolveMenuPath(_ items: [AppMenuItemInfo], _ path: [String]) -> AppMenuItemInfo? {
        guard !path.isEmpty else { return nil }
        var current = items
        for (i, segment) in path.enumerated() {
            guard let match = current.first(where: { $0.title == segment }) else { return nil }
            if i == path.count - 1 { return match }
            current = match.children ?? []
        }
        return nil
    }

    private func searchMenuByName(_ items: [AppMenuItemInfo], _ name: String, isRegex: Bool) -> AppMenuItemInfo? {
        for item in items {
            // Leaf items (no children) are candidates
            if item.children == nil || item.children?.isEmpty == true {
                if isRegex {
                    let pred = NSPredicate(format: "SELF MATCHES %@", name)
                    if pred.evaluate(with: item.title) { return item }
                } else {
                    if item.title == name { return item }
                }
            }
            // Recurse into children
            if let children = item.children {
                if let found = searchMenuByName(children, name, isRegex: isRegex) {
                    return found
                }
            }
        }
        return nil
    }

    private func menuItemToDict(_ item: AppMenuItemInfo) -> [String: Any]? {
        var dict: [String: Any] = [:]
        dict["AXTitle"] = item.title ?? ""
        dict["AXRole"] = item.role ?? "AXMenuItem"
        dict["AXEnabled"] = NSNumber(value: item.enabled)
        dict["AXMenuItemMarkChar"] = item.marked ? "\u{2713}" : ""
        dict["AXMenuItemCmdChar"] = item.cmdChar ?? ""
        dict["AXMenuItemCmdModifiers"] = item.cmdModifiers ?? NSNull()
        dict["AXMenuItemCmdGlyph"] = item.cmdGlyph ?? ""
        if let children = item.children, !children.isEmpty {
            dict["AXChildren"] = children.compactMap { menuItemToDict($0) }
        }
        return dict
    }
}
