import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HSDSTCore

// SkyLight private API for querying window corner radii (re-declared here;
// the _prod* variants in ProductionWindow.swift are file-private).
@_silgen_name("SLSWindowQueryWindows")
private func _elemSLSWindowQueryWindows(_ cid: Int32, _ windows: CFArray,
                                        _ options: UInt32) -> CFTypeRef?
@_silgen_name("SLSWindowQueryResultCopyWindows")
private func _elemSLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> CFTypeRef?
@_silgen_name("SLSWindowIteratorGetCount")
private func _elemSLSWindowIteratorGetCount(_ iterator: CFTypeRef) -> Int32
@_silgen_name("SLSWindowIteratorAdvance")
private func _elemSLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool
@_silgen_name("SLSWindowIteratorGetCornerRadii")
private func _elemSLSWindowIteratorGetCornerRadii(_ iterator: CFTypeRef) -> CFArray?

// CGWindowListCreateImage via dlsym
private let _elemCGWindowListCreateImage: (
    (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?
)? = {
    typealias Fn = @convention(c) (CGRect, CGWindowListOption, CGWindowID,
                                   CGWindowImageOption) -> CGImage?
    guard let sym = dlsym(nil, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: Fn.self)
}()

/// A production `WindowElementHandle` that wraps an AXUIElement reference.
///
/// Each property access goes directly to the stored AXUIElement — O(1) per operation.
/// This replaces the O(N*M) pattern where every operation re-discovered the element
/// by scanning all running applications.
final class ProductionWindowElement: WindowElementHandle {
    /// The cached AXUIElement for this window. All AX queries go through this.
    let element: AXUIElement
    let windowID: UInt32
    let pid: Int32

    init(element: AXUIElement) {
        self.element = element
        var wID: CGWindowID = 0
        _AXUIElementGetWindow(element, &wID)
        self.windowID = wID
        var p: pid_t = 0
        AXUIElementGetPid(element, &p)
        self.pid = p
    }

    // MARK: - Read-only properties

    func title() -> String? {
        axStringAttr(NSAccessibility.Attribute.title.rawValue)
    }

    func role() -> String {
        axStringAttr(NSAccessibility.Attribute.role.rawValue) ?? "AXWindow"
    }

    func subrole() -> String? {
        axStringAttr(NSAccessibility.Attribute.subrole.rawValue)
    }

    func frame() -> (x: Double, y: Double, width: Double, height: Double) {
        var position = CGPoint.zero
        var size = CGSize.zero
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, NSAccessibility.Attribute.position.rawValue as CFString,
            &posRef) == .success, let posRef = posRef
        {
            AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(
            element, NSAccessibility.Attribute.size.rawValue as CFString,
            &sizeRef) == .success, let sizeRef = sizeRef
        {
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        }
        return (Double(position.x), Double(position.y), Double(size.width), Double(size.height))
    }

    func isMinimized() -> Bool {
        axBoolAttr(NSAccessibility.Attribute.minimized.rawValue)
    }

    func isFullScreen() -> Bool {
        axBoolAttr("AXFullScreen")
    }

    func isStandard() -> Bool {
        subrole() == kAXStandardWindowSubrole as String
    }

    func isVisible() -> Bool {
        !isMinimized()
    }

    func isMaximizable() -> Bool? {
        var buttonRef: CFTypeRef?
        var isEnabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
            let buttonElement = buttonRef,
            AXUIElementCopyAttributeValue(
                buttonElement as! AXUIElement, kAXEnabledAttribute as CFString,
                &isEnabled) == .success
        else { return nil }
        guard let boolVal = isEnabled else { return nil }
        return CFBooleanGetValue(unsafeBitCast(boolVal, to: CFBoolean.self))
    }

    func tabCount() -> Int32 {
        guard let tabGroup = findTabGroup(element) else { return 0 }
        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(
            tabGroup, kAXTabsAttribute as CFString, 0, 100, &childrenRef) == .success,
            let children = childrenRef
        else { return 0 }
        return Int32(CFArrayGetCount(children))
    }

    func cornerRadius() -> Double {
        guard windowID != 0 else { return 0 }
        let cid = SLSMainConnectionID()
        let windowArray = [NSNumber(value: windowID)] as CFArray
        guard let query = _elemSLSWindowQueryWindows(cid, windowArray, 0x0) else { return 0 }
        guard let iterator = _elemSLSWindowQueryResultCopyWindows(query) else { return 0 }
        guard _elemSLSWindowIteratorGetCount(iterator) > 0 else { return 0 }
        guard _elemSLSWindowIteratorAdvance(iterator) else { return 0 }
        guard let radiiRef = _elemSLSWindowIteratorGetCornerRadii(iterator) else { return 0 }
        let radii = radiiRef as NSArray
        guard radii.count > 0, let value = radii[0] as? NSNumber else { return 0 }
        let radius = CGFloat(value.doubleValue)
        return radius > 0 ? Double(radius) : 0
    }

    // MARK: - Mutation methods

    func setTopLeft(_ point: (x: Double, y: Double)) -> Bool {
        var cgPoint = CGPoint(x: point.x, y: point.y)
        guard let posValue = AXValueCreate(.cgPoint, &cgPoint) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            NSAccessibility.Attribute.position.rawValue as CFString,
            posValue) == .success
    }

    func setSize(_ size: (width: Double, height: Double)) -> Bool {
        var cgSize = CGSize(width: size.width, height: size.height)
        guard let sizeValue = AXValueCreate(.cgSize, &cgSize) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            NSAccessibility.Attribute.size.rawValue as CFString,
            sizeValue) == .success
    }

    func setFrame(_ frame: (x: Double, y: Double, width: Double, height: Double)) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var enhancedRef: CFTypeRef?
        var hadEnhancedUI = false

        if AXUIElementCopyAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString,
            &enhancedRef) == .success,
            let val = enhancedRef as? NSNumber
        {
            hadEnhancedUI = val.boolValue
            if hadEnhancedUI {
                AXUIElementSetAttributeValue(
                    appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        var cgSize = CGSize(width: frame.width, height: frame.height)
        var cgPoint = CGPoint(x: frame.x, y: frame.y)
        if let sizeValue = AXValueCreate(.cgSize, &cgSize) {
            AXUIElementSetAttributeValue(
                element, NSAccessibility.Attribute.size.rawValue as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &cgPoint) {
            AXUIElementSetAttributeValue(
                element, NSAccessibility.Attribute.position.rawValue as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &cgSize) {
            AXUIElementSetAttributeValue(
                element, NSAccessibility.Attribute.size.rawValue as CFString, sizeValue)
        }

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return true
    }

    func minimize() -> Bool {
        AXUIElementSetAttributeValue(
            element, NSAccessibility.Attribute.minimized.rawValue as CFString,
            NSNumber(value: true)) == .success
    }

    func unminimize() -> Bool {
        AXUIElementSetAttributeValue(
            element, NSAccessibility.Attribute.minimized.rawValue as CFString,
            NSNumber(value: false)) == .success
    }

    func close() -> Bool {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
            let buttonRef = buttonRef
        else { return false }
        return AXUIElementPerformAction(
            unsafeBitCast(buttonRef, to: AXUIElement.self),
            kAXPressAction as CFString) == .success
    }

    func raise() -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    func focus() -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            element, NSAccessibility.Attribute.main.rawValue as CFString,
            NSNumber(value: true))
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        return true
    }

    func toggleZoom() -> Bool {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
            let buttonRef = buttonRef
        else { return false }
        return AXUIElementPerformAction(
            unsafeBitCast(buttonRef, to: AXUIElement.self),
            kAXPressAction as CFString) == .success
    }

    func setFullScreen(_ fullScreen: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            element, "AXFullScreen" as CFString,
            fullScreen ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    func becomeMain() -> Bool {
        AXUIElementSetAttributeValue(
            element, NSAccessibility.Attribute.main.rawValue as CFString,
            NSNumber(value: true)) == .success
    }

    func focusTab(_ tabIndex: Int32) -> Bool {
        guard let tabGroup = findTabGroup(element) else { return false }
        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(
            tabGroup, kAXTabsAttribute as CFString, 0, 100, &childrenRef) == .success,
            let children = childrenRef
        else { return false }
        let count = CFArrayGetCount(children)
        var i = CFIndex(tabIndex)
        if i > count || i <= 0 { i = count - 1 } else { i -= 1 }
        guard let tabRaw = CFArrayGetValueAtIndex(children, i) else { return false }
        let tab = unsafeBitCast(tabRaw, to: AXUIElement.self)
        return AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
    }

    func snapshot(keepTransparency: Bool) -> Data? {
        let imageOption: CGWindowImageOption = keepTransparency ? [] : .shouldBeOpaque
        guard let cgImage = _elemCGWindowListCreateImage?(
            CGRect.null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, imageOption])
        else { return nil }
        let nsImage = NSImage(cgImage: cgImage,
                               size: NSSize(width: cgImage.width, height: cgImage.height))
        return nsImage.tiffRepresentation
    }

    func zoomButtonRect() -> (x: Double, y: Double, width: Double, height: Double)? {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
            let buttonRef = buttonRef
        else { return nil }
        let button = unsafeBitCast(buttonRef, to: AXUIElement.self)

        var pointRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            button, kAXPositionAttribute as CFString, &pointRef) == .success,
            AXUIElementCopyAttributeValue(
                button, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let pointRef = pointRef, let sizeRef = sizeRef
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(pointRef, to: AXValue.self), .cgPoint, &point)
        AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        return (Double(point.x), Double(point.y), Double(size.width), Double(size.height))
    }

    func spaces() -> [Int] {
        let cid = SLSMainConnectionID()
        let windowList = [NSNumber(value: windowID)] as CFArray
        guard let spacesRef = SLSCopySpacesForWindows(cid, 0x7, windowList) else { return [] }
        let arr = spacesRef as NSArray
        return arr.compactMap { ($0 as? NSNumber)?.intValue }
    }

    // MARK: - Private helpers

    private func axStringAttr(_ a: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, a as CFString, &ref) == .success,
              let ref = ref
        else { return nil }
        return ref as? String
    }

    private func axBoolAttr(_ a: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, a as CFString, &ref) == .success,
              let val = ref as? NSNumber
        else { return false }
        return val.boolValue
    }

    private func findTabGroup(_ axElement: AXUIElement) -> AXUIElement? {
        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(
            axElement, kAXChildrenAttribute as CFString, 0, 100, &childrenRef) == .success,
            let children = childrenRef
        else { return nil }
        let count = CFArrayGetCount(children)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(children, i) else { continue }
            let child = unsafeBitCast(rawPtr, to: AXUIElement.self)
            if axStringAttrOn(child, NSAccessibility.Attribute.role.rawValue)
                == kAXTabGroupRole as String
            { return child }
        }
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(children, i) else { continue }
            let child = unsafeBitCast(rawPtr, to: AXUIElement.self)
            guard axStringAttrOn(child, NSAccessibility.Attribute.role.rawValue)
                    == kAXGroupRole as String
            else { continue }
            var attrNamesRef: CFArray?
            guard AXUIElementCopyAttributeNames(child, &attrNamesRef) == .success,
                  let names = attrNamesRef as? [String]
            else { continue }
            if names.contains(kAXTabsAttribute as String) { return child }
        }
        return nil
    }

    private func axStringAttrOn(_ e: AXUIElement, _ a: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &ref) == .success,
              let ref = ref
        else { return nil }
        return ref as? String
    }
}
