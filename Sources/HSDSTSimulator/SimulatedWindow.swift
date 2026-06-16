import Foundation
import HSDSTCore

public final class SimulatedWindow: WindowProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var windows: [AXWindowInfo] = [AXWindowInfo()]
    public var focusedWindowID: UInt32 = 1
    public var shadowsEnabled: Bool = true
    public var timeoutValue: Float = 0
    public var windowSpaces: [UInt32: [Int]] = [1: [1]]

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

    // MARK: - Listing and lookup

    public func allWindows() -> [AXWindowInfo] { windows }

    public func focusedWindow() -> AXWindowInfo? {
        if faults.accessibilityPermissionDenied { return nil }
        return windows.first { $0.id == focusedWindowID }
    }

    public func orderedWindowIDs() -> [UInt32] {
        windows.filter { $0.isVisible && !$0.isMinimized }.map { $0.id }
    }

    public func windowInfo(forID id: UInt32) -> AXWindowInfo? {
        if faults.accessibilityPermissionDenied { return nil }
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
        return true
    }

    public func close(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard windows.contains(where: { $0.id == windowID }) else { return false }
        closedWindowIDs.append(windowID)
        windows.removeAll { $0.id == windowID }
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
        focusedWindowID = windowID
        return true
    }

    public func toggleZoom(windowID: UInt32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard windows.contains(where: { $0.id == windowID }) else { return false }
        zoomToggledWindowIDs.append(windowID)
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
