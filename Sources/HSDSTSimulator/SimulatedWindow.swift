import Foundation
import HSDSTCore

public final class SimulatedWindow: WindowProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var windows: [AXWindowInfo] = []
    private var focusStack: [UInt32] = []
    private var nextWindowID: UInt32 = 1
    public var shadowsEnabled: Bool = true
    public var timeoutValue: Float = 0
    public var windowSpaces: [UInt32: [Int]] = [:]

    // MARK: - Call tracking for verification

    public var closedWindowIDs: [UInt32] = []
    public var raisedWindowIDs: [UInt32] = []
    public var focusedWindowIDs: [UInt32] = []
    public var minimizedWindowIDs: [UInt32] = []
    public var unminimizedWindowIDs: [UInt32] = []
    public var zoomToggledWindowIDs: [UInt32] = []
    public var snapshotWindowIDs: [UInt32] = []
    public var focusedTabs: [(windowID: UInt32, tabIndex: Int32)] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Window creation

    public func createWindow(title: String, pid: Int32, role: String, subrole: String?,
                             frame: (x: Double, y: Double, width: Double, height: Double)) -> UInt32 {
        let id = nextWindowID
        nextWindowID += 1
        let info = AXWindowInfo(
            id: id, title: title, role: role, subrole: subrole,
            frame: frame, pid: pid,
            isMinimized: false, isFullScreen: false,
            level: 0, alpha: 1.0,
            isStandard: subrole == "AXStandardWindow",
            isVisible: true, isMaximizable: true,
            tabCount: 0, cornerRadius: 10.0
        )
        windows.append(info)
        windowSpaces[id] = [1]
        // Push to front of focus stack
        focusStack.insert(id, at: 0)
        return id
    }

    // MARK: - Desktop

    public func desktopWindow() -> AXWindowInfo? {
        AXWindowInfo(
            id: UInt32.max, title: nil, role: "AXScrollArea", subrole: nil,
            frame: (0, 0, 1920, 1080), pid: 1,
            isMinimized: false, isFullScreen: false,
            level: -2147483623, alpha: 1.0,
            isStandard: false, isVisible: true,
            isMaximizable: false, tabCount: 0, cornerRadius: 0
        )
    }

    // MARK: - Listing and lookup

    public func allWindows() -> [AXWindowInfo] { windows }

    public func focusedWindow() -> AXWindowInfo? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let topID = focusStack.first else { return nil }
        return windows.first { $0.id == topID }
    }

    public func orderedWindowIDs() -> [UInt32] {
        windows.filter { $0.isVisible && !$0.isMinimized }.map { $0.id }
    }

    public func windowInfo(forID id: UInt32) -> AXWindowInfo? {
        if faults.accessibilityPermissionDenied { return nil }
        // Check for the special desktop window ID
        if id == UInt32.max { return desktopWindow() }
        return windows.first { $0.id == id }
    }

    public func windows(forAppPID pid: Int32) -> [AXWindowInfo] {
        if faults.accessibilityPermissionDenied { return [] }
        return windows.filter { $0.pid == pid }
    }

    // MARK: - Position and size

    public func setTopLeft(_ point: (x: Double, y: Double), forWindowID id: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return false }
        let w = windows[idx]
        windows[idx] = AXWindowInfo(
            id: id, title: w.title, role: w.role, subrole: w.subrole,
            frame: (point.x, point.y, w.frame.width, w.frame.height),
            pid: w.pid, isMinimized: w.isMinimized, isFullScreen: w.isFullScreen,
            level: w.level, alpha: w.alpha, isStandard: w.isStandard,
            isVisible: w.isVisible, isMaximizable: w.isMaximizable,
            tabCount: w.tabCount, cornerRadius: w.cornerRadius
        )
        return true
    }

    public func setSize(_ size: (width: Double, height: Double), forWindowID id: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return false }
        let w = windows[idx]
        windows[idx] = AXWindowInfo(
            id: id, title: w.title, role: w.role, subrole: w.subrole,
            frame: (w.frame.x, w.frame.y, size.width, size.height),
            pid: w.pid, isMinimized: w.isMinimized, isFullScreen: w.isFullScreen,
            level: w.level, alpha: w.alpha, isStandard: w.isStandard,
            isVisible: w.isVisible, isMaximizable: w.isMaximizable,
            tabCount: w.tabCount, cornerRadius: w.cornerRadius
        )
        return true
    }

    public func setFrame(_ frame: (x: Double, y: Double, width: Double, height: Double), forWindowID id: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return false }
        let w = windows[idx]
        windows[idx] = AXWindowInfo(
            id: id, title: w.title, role: w.role, subrole: w.subrole,
            frame: frame,
            pid: w.pid, isMinimized: w.isMinimized, isFullScreen: w.isFullScreen,
            level: w.level, alpha: w.alpha, isStandard: w.isStandard,
            isVisible: w.isVisible, isMaximizable: w.isMaximizable,
            tabCount: w.tabCount, cornerRadius: w.cornerRadius
        )
        return true
    }

    // MARK: - State changes

    public func minimize(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == windowID }) else { return false }
        minimizedWindowIDs.append(windowID)
        let w = windows[idx]
        windows[idx] = AXWindowInfo(
            id: windowID, title: w.title, role: w.role, subrole: w.subrole,
            frame: w.frame, pid: w.pid, isMinimized: true, isFullScreen: w.isFullScreen,
            level: w.level, alpha: w.alpha, isStandard: w.isStandard,
            isVisible: false, isMaximizable: w.isMaximizable,
            tabCount: w.tabCount, cornerRadius: w.cornerRadius
        )
        // Minimized windows lose focus
        focusStack.removeAll { $0 == windowID }
        return true
    }

    public func unminimize(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == windowID }) else { return false }
        unminimizedWindowIDs.append(windowID)
        let w = windows[idx]
        windows[idx] = AXWindowInfo(
            id: windowID, title: w.title, role: w.role, subrole: w.subrole,
            frame: w.frame, pid: w.pid, isMinimized: false, isFullScreen: w.isFullScreen,
            level: w.level, alpha: w.alpha, isStandard: w.isStandard,
            isVisible: true, isMaximizable: w.isMaximizable,
            tabCount: w.tabCount, cornerRadius: w.cornerRadius
        )
        // Unminimized window gets focus back
        focusStack.removeAll { $0 == windowID }
        focusStack.insert(windowID, at: 0)
        return true
    }

    public func close(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard windows.contains(where: { $0.id == windowID }) else { return false }
        closedWindowIDs.append(windowID)
        windows.removeAll { $0.id == windowID }
        focusStack.removeAll { $0 == windowID }
        windowSpaces.removeValue(forKey: windowID)
        return true
    }

    public func raise(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard windows.contains(where: { $0.id == windowID }) else { return false }
        raisedWindowIDs.append(windowID)
        return true
    }

    public func focus(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard windows.contains(where: { $0.id == windowID }) else { return false }
        focusedWindowIDs.append(windowID)
        focusStack.removeAll { $0 == windowID }
        focusStack.insert(windowID, at: 0)
        return true
    }

    public func toggleZoom(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == windowID }) else { return false }
        zoomToggledWindowIDs.append(windowID)
        let w = windows[idx]
        if w.isMaximizable {
            windows[idx] = AXWindowInfo(
                id: windowID, title: w.title, role: w.role, subrole: w.subrole,
                frame: w.frame, pid: w.pid, isMinimized: w.isMinimized,
                isFullScreen: !w.isFullScreen,
                level: w.level, alpha: w.alpha, isStandard: w.isStandard,
                isVisible: w.isVisible, isMaximizable: w.isMaximizable,
                tabCount: w.tabCount, cornerRadius: w.cornerRadius
            )
        }
        return true
    }

    public func setFullScreen(_ fullScreen: Bool, forWindowID id: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return false }
        let w = windows[idx]
        windows[idx] = AXWindowInfo(
            id: id, title: w.title, role: w.role, subrole: w.subrole,
            frame: w.frame, pid: w.pid, isMinimized: w.isMinimized,
            isFullScreen: fullScreen,
            level: w.level, alpha: w.alpha, isStandard: w.isStandard,
            isVisible: w.isVisible, isMaximizable: w.isMaximizable,
            tabCount: w.tabCount, cornerRadius: w.cornerRadius
        )
        return true
    }

    // MARK: - Shadows

    public func setShadows(_ enabled: Bool) {
        shadowsEnabled = enabled
    }

    // MARK: - Timeout

    public func setTimeout(_ seconds: Float) -> Bool {
        guard seconds > 0 else { return false }
        timeoutValue = seconds
        return true
    }

    // MARK: - Tabs

    public func focusTab(_ tabIndex: Int32, forWindowID id: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard let w = windows.first(where: { $0.id == id }) else { return false }
        guard tabIndex >= 1 && tabIndex <= w.tabCount else { return false }
        focusedTabs.append((windowID: id, tabIndex: tabIndex))
        return true
    }

    // MARK: - Snapshot

    public func snapshot(windowID: UInt32, keepTransparency: Bool) -> Data? {
        if faults.screenRecordingPermissionDenied { return nil }
        guard windows.contains(where: { $0.id == windowID }) else { return nil }
        snapshotWindowIDs.append(windowID)
        return makePNGStub()
    }

    public func snapshotForID(_ windowID: UInt32, keepTransparency: Bool) -> Data? {
        if faults.screenRecordingPermissionDenied { return nil }
        snapshotWindowIDs.append(windowID)
        return makePNGStub()
    }

    // MARK: - Corner radius

    public func cornerRadius(forWindowID id: UInt32) -> Double {
        windows.first(where: { $0.id == id })?.cornerRadius ?? 0
    }

    // MARK: - Spaces

    public func spaces(forWindowID id: UInt32) -> [Int] {
        windowSpaces[id] ?? []
    }

    // MARK: - Additional window operations

    public var becameMainWindowIDs: [UInt32] = []

    public func becomeMain(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard windows.contains(where: { $0.id == windowID }) else { return false }
        becameMainWindowIDs.append(windowID)
        return true
    }

    public func zoomButtonRect(forWindowID id: UInt32) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let w = windows.first(where: { $0.id == id }) else { return nil }
        // Simulated zoom button at top-left of window frame, 14x14
        return (w.frame.x + 7, w.frame.y + 7, 14, 14)
    }

    public func isMaximizable(forWindowID id: UInt32) -> Bool? {
        guard let w = windows.first(where: { $0.id == id }) else { return nil }
        return w.isMaximizable
    }

    /// Simulated CGWindowList info dictionaries.
    public var cgWindowListInfo: [[String: Any]] = []

    public func listWindowInfo(allWindows: Bool) -> [[String: Any]] {
        if cgWindowListInfo.isEmpty {
            // Auto-generate from windows array
            return windows.filter { $0.isVisible && !$0.isMinimized }.map { w in
                [
                    "kCGWindowNumber": NSNumber(value: w.id),
                    "kCGWindowOwnerPID": NSNumber(value: w.pid),
                    "kCGWindowName": w.title ?? "" as Any,
                    "kCGWindowLayer": NSNumber(value: w.level),
                    "kCGWindowAlpha": NSNumber(value: w.alpha),
                    "kCGWindowBounds": [
                        "X": w.frame.x, "Y": w.frame.y,
                        "Width": w.frame.width, "Height": w.frame.height
                    ] as [String: Any]
                ] as [String: Any]
            }
        }
        return cgWindowListInfo
    }

    // MARK: - Private helpers

    private func makePNGStub() -> Data {
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
