import Foundation
import HSDSTCore

public final class SimulatedAccessibility: AccessibilityProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var elements: [UInt64: AccessibilityElement] = [:]
    public var accessibilityEnabled: Bool = true
    public var performedActions: [(elementID: UInt64, action: String)] = []
    public var activeObservers: [UInt64: [(element: UInt64, notification: String)]] = [:]

    private var nextElementID: UInt64 = 1
    private var nextObserverID: UInt64 = 1
    private var observerCallbacks: [UInt64: (UInt64, UInt64, String) -> Void] = [:]

    /// The system-wide element is always ID 0.
    private let systemWideElementID: UInt64 = 0

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults

        // Seed the system-wide element.
        elements[systemWideElementID] = AccessibilityElement(
            elementID: systemWideElementID, role: "AXSystemWide",
            frame: (0, 0, 0, 0), pid: 0
        )
    }

    public func isAccessibilityEnabled() -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        return accessibilityEnabled
    }

    public func createElement(forPID pid: Int32) -> UInt64? {
        if faults.accessibilityPermissionDenied { return nil }
        let id = nextElementID
        nextElementID += 1
        elements[id] = AccessibilityElement(
            elementID: id, role: "AXApplication", pid: pid
        )
        return id
    }

    public func getAttributeValue(element: UInt64, attribute: String) -> String? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let el = elements[element] else { return nil }
        return el.attributes[attribute]
    }

    public func setAttributeValue(element: UInt64, attribute: String, value: String) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard var el = elements[element] else { return false }
        el.attributes[attribute] = value
        elements[element] = el
        return true
    }

    public func performAction(element: UInt64, action: String) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard elements[element] != nil else { return false }
        performedActions.append((elementID: element, action: action))

        // Fire any matching observer notifications for "AXAction" events.
        for (observerID, subscriptions) in activeObservers {
            for sub in subscriptions where sub.element == element && sub.notification == action {
                observerCallbacks[observerID]?(observerID, element, action)
            }
        }
        return true
    }

    public func getChildren(element: UInt64) -> [UInt64] {
        if faults.accessibilityPermissionDenied { return [] }
        guard let el = elements[element] else { return [] }
        return el.children
    }

    public func getParent(element: UInt64) -> UInt64? {
        if faults.accessibilityPermissionDenied { return nil }
        guard let el = elements[element] else { return nil }
        return el.parent
    }

    public func elementAtPosition(x: Double, y: Double) -> UInt64? {
        if faults.accessibilityPermissionDenied { return nil }
        // Find the first element whose frame contains the point.
        for (id, el) in elements {
            if id == systemWideElementID { continue }
            let f = el.frame
            if x >= f.x && x < f.x + f.width && y >= f.y && y < f.y + f.height {
                return id
            }
        }
        return nil
    }

    public func observerCreate(pid: Int32, callback: @escaping (UInt64, UInt64, String) -> Void) -> UInt64? {
        if faults.accessibilityPermissionDenied { return nil }
        let id = nextObserverID
        nextObserverID += 1
        activeObservers[id] = []
        observerCallbacks[id] = callback
        return id
    }

    public func observerAddNotification(observer: UInt64, element: UInt64, notification: String) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard activeObservers[observer] != nil, elements[element] != nil else { return false }
        activeObservers[observer]?.append((element: element, notification: notification))
        return true
    }

    public func observerRemoveNotification(observer: UInt64, element: UInt64, notification: String) -> Bool {
        if faults.accessibilityPermissionDenied { return false }
        guard activeObservers[observer] != nil else { return false }
        activeObservers[observer]?.removeAll { $0.element == element && $0.notification == notification }
        return true
    }

    public func getRole(element: UInt64) -> String? {
        if faults.accessibilityPermissionDenied { return nil }
        return elements[element]?.role
    }

    public func getTitle(element: UInt64) -> String? {
        if faults.accessibilityPermissionDenied { return nil }
        return elements[element]?.title
    }

    public func getFrame(element: UInt64) -> (x: Double, y: Double, width: Double, height: Double)? {
        if faults.accessibilityPermissionDenied { return nil }
        return elements[element]?.frame
    }

    public func getSystemWideElement() -> UInt64 {
        systemWideElementID
    }
}
