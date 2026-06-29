import Foundation
import HSDSTCore

public final class SimulatedWorkspace: WorkspaceProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public let launchServices = SimulatedLaunchServices()
    public var apps: [AppInfo] = []
    public var windows: [WindowInfo] = []
    public var frontmostApp: AppInfo?
    public var openedURLs: [String] = []
    public var openedFiles: [String] = []
    public var appURLs: [String: String] = [:]
    public var appPaths: [String: String] = [:]
    public var desktopImages: [UInt32: String] = [:]
    public var minimizedWindows: Set<UInt32> = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func runningApplications() -> [AppInfo] { apps }

    public func frontmostApplication() -> AppInfo? { frontmostApp ?? apps.first(where: { $0.isActive }) }

    public func openURL(_ url: String) -> Bool {
        openedURLs.append(url)
        return launchServices.openURL(url)
    }

    public func openFile(_ path: String) -> Bool {
        openedFiles.append(path)
        return launchServices.openFile(path)
    }

    public func launchApplication(bundleIdentifier: String) -> Bool {
        if rng.boolean(probability: faults.appLaunchFailProbability) { return false }
        let app = AppInfo(name: bundleIdentifier, bundleIdentifier: bundleIdentifier,
                          processIdentifier: Int32(apps.count + 100))
        apps.append(app)
        return true
    }

    public func terminateApplication(pid: Int32) -> Bool {
        apps.removeAll { $0.processIdentifier == pid }
        return true
    }

    public func hideApplication(pid: Int32) -> Bool {
        guard let idx = apps.firstIndex(where: { $0.processIdentifier == pid }) else { return false }
        apps[idx] = AppInfo(name: apps[idx].name, bundleIdentifier: apps[idx].bundleIdentifier,
                            processIdentifier: pid, isActive: apps[idx].isActive, isHidden: true)
        return true
    }

    public func unhideApplication(pid: Int32) -> Bool {
        guard let idx = apps.firstIndex(where: { $0.processIdentifier == pid }) else { return false }
        apps[idx] = AppInfo(name: apps[idx].name, bundleIdentifier: apps[idx].bundleIdentifier,
                            processIdentifier: pid, isActive: apps[idx].isActive, isHidden: false)
        return true
    }

    public func activateApplication(pid: Int32) -> Bool {
        guard let idx = apps.firstIndex(where: { $0.processIdentifier == pid }) else { return false }
        for i in apps.indices { apps[i] = AppInfo(name: apps[i].name, bundleIdentifier: apps[i].bundleIdentifier,
                                                   processIdentifier: apps[i].processIdentifier, isActive: false) }
        apps[idx] = AppInfo(name: apps[idx].name, bundleIdentifier: apps[idx].bundleIdentifier,
                            processIdentifier: pid, isActive: true)
        return true
    }

    public func windowList(options: UInt32) -> [WindowInfo] { windows }

    public func applicationForPID(_ pid: Int32) -> AppInfo? {
        apps.first(where: { $0.processIdentifier == pid })
    }

    public func applicationForBundleIdentifier(_ bundleID: String) -> AppInfo? {
        apps.first(where: { $0.bundleIdentifier == bundleID })
    }

    public func setApplicationHidden(_ hidden: Bool, pid: Int32) -> Bool {
        guard let idx = apps.firstIndex(where: { $0.processIdentifier == pid }) else { return false }
        apps[idx].isHidden = hidden
        return true
    }

    public func forceTerminateApplication(pid: Int32) -> Bool {
        apps.removeAll { $0.processIdentifier == pid }
        return true
    }

    public func windowInfo(forID windowID: UInt32) -> WindowInfo? {
        windows.first(where: { $0.windowID == windowID })
    }

    public func setWindowPosition(_ position: (x: Double, y: Double), windowID: UInt32) -> Bool {
        guard let idx = windows.firstIndex(where: { $0.windowID == windowID }) else { return false }
        let w = windows[idx]
        windows[idx] = WindowInfo(windowID: w.windowID, ownerPID: w.ownerPID, ownerName: w.ownerName,
                                  title: w.title,
                                  frame: (position.x, position.y, w.frame.width, w.frame.height),
                                  layer: w.layer, isOnScreen: w.isOnScreen, alpha: w.alpha)
        return true
    }

    public func setWindowSize(_ size: (width: Double, height: Double), windowID: UInt32) -> Bool {
        guard let idx = windows.firstIndex(where: { $0.windowID == windowID }) else { return false }
        let w = windows[idx]
        windows[idx] = WindowInfo(windowID: w.windowID, ownerPID: w.ownerPID, ownerName: w.ownerName,
                                  title: w.title,
                                  frame: (w.frame.x, w.frame.y, size.width, size.height),
                                  layer: w.layer, isOnScreen: w.isOnScreen, alpha: w.alpha)
        return true
    }

    public func minimizeWindow(windowID: UInt32) -> Bool {
        guard let idx = windows.firstIndex(where: { $0.windowID == windowID }) else { return false }
        minimizedWindows.insert(windowID)
        let w = windows[idx]
        windows[idx] = WindowInfo(windowID: w.windowID, ownerPID: w.ownerPID, ownerName: w.ownerName,
                                  title: w.title, frame: w.frame,
                                  layer: w.layer, isOnScreen: false, alpha: w.alpha)
        return true
    }

    public func closeWindow(windowID: UInt32) -> Bool {
        guard windows.contains(where: { $0.windowID == windowID }) else { return false }
        windows.removeAll { $0.windowID == windowID }
        return true
    }

    public func urlForApplicationWithBundleIdentifier(_ bundleID: String) -> String? {
        appURLs[bundleID]
    }

    public func fullPathForApplication(_ appName: String) -> String? {
        appPaths[appName]
    }

    public func desktopImagePath(forScreenID screenID: UInt32) -> String? {
        desktopImages[screenID]
    }

    public func setDesktopImagePath(_ path: String, forScreenID screenID: UInt32) -> Bool {
        desktopImages[screenID] = path
        return true
    }
}
