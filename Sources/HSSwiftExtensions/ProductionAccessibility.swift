import AppKit
import ApplicationServices
import Foundation
import HSDSTCore

private let _prodAXSystemWideElement: AXUIElement = AXUIElementCreateSystemWide()

final class ProductionAccessibility: AccessibilityProtocol {
    private var nextID: UInt64 = 1
    private var elements: [UInt64: AXUIElement] = [:]
    private var observers: [UInt64: ObserverState] = [:]

    private class ObserverState {
        let observer: AXObserver
        let callback: (UInt64, UInt64, String) -> Void

        init(observer: AXObserver, callback: @escaping (UInt64, UInt64, String) -> Void) {
            self.observer = observer
            self.callback = callback
        }
    }

    func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    func createElement(forPID pid: Int32) -> UInt64? {
        let element = AXUIElementCreateApplication(pid)
        return storeElement(element)
    }

    func getAttributeValue(element: UInt64, attribute: String) -> String? {
        guard let axElement = elements[element] else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, attribute as CFString, &ref) == .success,
              let ref = ref
        else { return nil }
        return "\(ref)"
    }

    func setAttributeValue(element: UInt64, attribute: String, value: String) -> Bool {
        guard let axElement = elements[element] else { return false }
        return AXUIElementSetAttributeValue(
            axElement, attribute as CFString, value as CFString) == .success
    }

    func performAction(element: UInt64, action: String) -> Bool {
        guard let axElement = elements[element] else { return false }
        return AXUIElementPerformAction(axElement, action as CFString) == .success
    }

    func getChildren(element: UInt64) -> [UInt64] {
        guard let axElement = elements[element] else { return [] }
        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(
            axElement, kAXChildrenAttribute as CFString, 0, 1000,
            &childrenRef) == .success,
            let children = childrenRef
        else { return [] }

        var result: [UInt64] = []
        let count = CFArrayGetCount(children)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(children, i) else { continue }
            let child = unsafeBitCast(raw, to: AXUIElement.self)
            result.append(storeElement(child))
        }
        return result
    }

    func getParent(element: UInt64) -> UInt64? {
        guard let axElement = elements[element] else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement, kAXParentAttribute as CFString, &ref) == .success,
            let ref = ref
        else { return nil }
        let parent = unsafeBitCast(ref, to: AXUIElement.self)
        return storeElement(parent)
    }

    func elementAtPosition(x: Double, y: Double) -> UInt64? {
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            _prodAXSystemWideElement, Float(x), Float(y), &ref) == .success,
            let element = ref
        else { return nil }
        return storeElement(element)
    }

    func observerCreate(pid: Int32,
                        callback: @escaping (UInt64, UInt64, String) -> Void) -> UInt64?
    {
        let id = nextID
        nextID += 1

        let axCallback: AXObserverCallback = { _, element, notification, userData in
            guard let userData = userData else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            let notifName = notification as String
            let elemID = box.accessibility.storeElement(element)
            box.callback(box.id, elemID, notifName)
        }

        var axObserver: AXObserver?
        guard AXObserverCreate(pid, axCallback, &axObserver) == .success,
              let observer = axObserver
        else { return nil }

        // Store callback box
        let box = CallbackBox(id: id, callback: callback, accessibility: self)
        let _ = Unmanaged.passRetained(box)

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode)

        observers[id] = ObserverState(observer: observer, callback: callback)
        return id
    }

    func observerAddNotification(observer: UInt64, element: UInt64,
                                  notification: String) -> Bool
    {
        guard let state = observers[observer],
              let axElement = elements[element]
        else { return false }
        return AXObserverAddNotification(
            state.observer, axElement, notification as CFString, nil) == .success
    }

    func observerRemoveNotification(observer: UInt64, element: UInt64,
                                     notification: String) -> Bool
    {
        guard let state = observers[observer],
              let axElement = elements[element]
        else { return false }
        return AXObserverRemoveNotification(
            state.observer, axElement, notification as CFString) == .success
    }

    func getRole(element: UInt64) -> String? {
        guard let axElement = elements[element] else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement, kAXRoleAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    func getTitle(element: UInt64) -> String? {
        guard let axElement = elements[element] else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement, NSAccessibility.Attribute.title.rawValue as CFString,
            &ref) == .success
        else { return nil }
        return ref as? String
    }

    func getFrame(element: UInt64) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let axElement = elements[element] else { return nil }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            axElement, kAXPositionAttribute as CFString, &posRef) == .success,
            let posRef = posRef,
            AXUIElementCopyAttributeValue(
                axElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let sizeRef = sizeRef
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        return (Double(position.x), Double(position.y),
                Double(size.width), Double(size.height))
    }

    func getSystemWideElement() -> UInt64 {
        return storeElement(_prodAXSystemWideElement)
    }

    // MARK: - Private

    private func storeElement(_ element: AXUIElement) -> UInt64 {
        let id = nextID
        nextID += 1
        elements[id] = element
        return id
    }

    private class CallbackBox {
        let id: UInt64
        let callback: (UInt64, UInt64, String) -> Void
        let accessibility: ProductionAccessibility

        init(id: UInt64, callback: @escaping (UInt64, UInt64, String) -> Void,
             accessibility: ProductionAccessibility) {
            self.id = id
            self.callback = callback
            self.accessibility = accessibility
        }
    }
}
