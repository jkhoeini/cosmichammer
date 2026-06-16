import Cocoa
import HSDSTCore

final class ProductionWorkspace: WorkspaceProtocol {
    func runningApplications() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.map { appInfoFrom($0) }
    }

    func frontmostApplication() -> AppInfo? {
        NSWorkspace.shared.frontmostApplication.map { appInfoFrom($0) }
    }

    func openURL(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        return NSWorkspace.shared.open(u)
    }

    func openFile(_ path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func launchApplication(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleIdentifier,
                                             options: [], additionalEventParamDescriptor: nil,
                                             launchIdentifier: nil)
    }

    func terminateApplication(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    func hideApplication(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.hide() ?? false
    }

    func unhideApplication(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.unhide() ?? false
    }

    func activateApplication(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }

    func windowList(options: UInt32) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(CGWindowListOption(rawValue: options), kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { dict in
            guard let id = dict[kCGWindowNumber as String] as? UInt32,
                  let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  let name = dict[kCGWindowOwnerName as String] as? String else { return nil }
            let bounds = dict[kCGWindowBounds as String] as? [String: Double] ?? [:]
            return WindowInfo(
                windowID: id, ownerPID: pid, ownerName: name,
                title: dict[kCGWindowName as String] as? String,
                frame: (bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0),
                layer: (dict[kCGWindowLayer as String] as? Int) ?? 0,
                isOnScreen: (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                alpha: (dict[kCGWindowAlpha as String] as? Double) ?? 1.0
            )
        }
    }

    private func appInfoFrom(_ app: NSRunningApplication) -> AppInfo {
        AppInfo(
            name: app.localizedName ?? "",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            isActive: app.isActive,
            isHidden: app.isHidden,
            isFinishedLaunching: app.isFinishedLaunching,
            ownsMenuBar: app.ownsMenuBar
        )
    }
}
