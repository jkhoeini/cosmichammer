import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HSDSTCore
import os.log

// NOTE: The following private API declarations are already module-visible from HSuicore.swift:
//   _AXUIElementGetWindow, _CGWindowListCreate, CGSMainConnectionID
// And from Spaces.swift:
//   SLSCopySpacesForWindows, SLSMainConnectionID

// CGWindowListCreateImage via dlsym (may be obsoleted in newer SDKs)
private let _productionCGWindowListCreateImage: (
    (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?
)? = {
    typealias Fn = @convention(c) (CGRect, CGWindowListOption, CGWindowID,
                                   CGWindowImageOption) -> CGImage?
    guard let sym = dlsym(nil, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: Fn.self)
}()

private let _prodSystemWideElement: AXUIElement = AXUIElementCreateSystemWide()

// SkyLight private API for querying window corner radii via the window iterator.
@_silgen_name("SLSWindowQueryWindows")
private func _prodSLSWindowQueryWindows(_ cid: Int32, _ windows: CFArray,
                                        _ options: UInt32) -> CFTypeRef?
@_silgen_name("SLSWindowQueryResultCopyWindows")
private func _prodSLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> CFTypeRef?
@_silgen_name("SLSWindowIteratorGetCount")
private func _prodSLSWindowIteratorGetCount(_ iterator: CFTypeRef) -> Int32
@_silgen_name("SLSWindowIteratorAdvance")
private func _prodSLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool
@_silgen_name("SLSWindowIteratorGetCornerRadii")
private func _prodSLSWindowIteratorGetCornerRadii(_ iterator: CFTypeRef) -> CFArray?

final class ProductionWindow: WindowProtocol {
    private var timeoutSeconds: Float = 2.0

    // MARK: - Window creation (no-op in production)

    func createWindow(title: String, pid: Int32, role: String, subrole: String?,
                      frame: (x: Double, y: Double, width: Double, height: Double)) -> UInt32 {
        // Production windows are created by the OS, not by us.
        return 0
    }

    // MARK: - Desktop

    func desktopWindow() -> AXWindowInfo? {
        // Find Finder and look for the AXScrollArea (desktop) window
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else { return nil }
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windowsRef = windowsRef
        else { return nil }
        let windowsArray = unsafeBitCast(windowsRef, to: CFArray.self)
        let count = CFArrayGetCount(windowsArray)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(windowsArray, i) else { continue }
            let winElement = unsafeBitCast(raw, to: AXUIElement.self)
            if let info = axWindowInfoFromElement(winElement), info.role == "AXScrollArea" {
                return info
            }
        }
        return nil
    }

    // MARK: - Listing and lookup

    func allWindows() -> [AXWindowInfo] {
        var result: [AXWindowInfo] = []
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular
        {
            result.append(contentsOf: windows(forAppPID: app.processIdentifier))
        }
        return result
    }

    func focusedWindow() -> AXWindowInfo? {
        var appRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            _prodSystemWideElement, kAXFocusedApplicationAttribute as CFString, &appRef)
        guard let appRef = appRef else { return nil }
        let appElement = unsafeBitCast(appRef, to: AXUIElement.self)

        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            NSAccessibility.Attribute.focusedWindow.rawValue as CFString,
            &winRef) == .success,
            let winRef = winRef
        else { return nil }

        let winElement = unsafeBitCast(winRef, to: AXUIElement.self)
        return axWindowInfoFromElement(winElement)
    }

    func orderedWindowIDs() -> [UInt32] {
        guard let wins = _CGWindowListCreate(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID)
        else { return [] }
        guard let descs = CGWindowListCreateDescriptionFromArray(wins) else { return [] }
        var result: [UInt32] = []
        let count = CFArrayGetCount(wins)
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let dictRaw = CFArrayGetValueAtIndex(descs, i) else { continue }
            let dict = unsafeBitCast(dictRaw, to: CFDictionary.self)
            guard let numRaw = CFDictionaryGetValue(
                dict, Unmanaged.passUnretained(kCGWindowNumber as CFString).toOpaque())
            else { continue }
            let num = unsafeBitCast(numRaw, to: CFNumber.self)
            var windowID: UInt32 = 0
            CFNumberGetValue(num, .sInt32Type, &windowID)
            result.append(windowID)
        }
        return result
    }

    func windowInfo(forID id: UInt32) -> AXWindowInfo? {
        guard let winElement = findWindowElement(id: id) else { return nil }
        return axWindowInfoFromElement(winElement)
    }

    func windows(forAppPID pid: Int32) -> [AXWindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windowsRef = windowsRef
        else { return [] }

        let windowsArray = unsafeBitCast(windowsRef, to: CFArray.self)
        let count = CFArrayGetCount(windowsArray)
        var result: [AXWindowInfo] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(windowsArray, i) else { continue }
            let winElement = unsafeBitCast(raw, to: AXUIElement.self)
            if let info = axWindowInfoFromElement(winElement) {
                result.append(info)
            }
        }
        return result
    }

    // MARK: - Position and size

    func setTopLeft(_ point: (x: Double, y: Double), forWindowID id: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: id) else { return false }
        var cgPoint = CGPoint(x: point.x, y: point.y)
        guard let posValue = AXValueCreate(.cgPoint, &cgPoint) else { return false }
        return AXUIElementSetAttributeValue(
            winElement,
            NSAccessibility.Attribute.position.rawValue as CFString,
            posValue) == .success
    }

    func setSize(_ size: (width: Double, height: Double), forWindowID id: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: id) else { return false }
        var cgSize = CGSize(width: size.width, height: size.height)
        guard let sizeValue = AXValueCreate(.cgSize, &cgSize) else { return false }
        return AXUIElementSetAttributeValue(
            winElement,
            NSAccessibility.Attribute.size.rawValue as CFString,
            sizeValue) == .success
    }

    func setFrame(_ frame: (x: Double, y: Double, width: Double, height: Double),
                  forWindowID id: UInt32) -> Bool
    {
        guard let winElement = findWindowElement(id: id) else { return false }

        var pid: pid_t = 0
        AXUIElementGetPid(winElement, &pid)
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
                winElement, NSAccessibility.Attribute.size.rawValue as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &cgPoint) {
            AXUIElementSetAttributeValue(
                winElement, NSAccessibility.Attribute.position.rawValue as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &cgSize) {
            AXUIElementSetAttributeValue(
                winElement, NSAccessibility.Attribute.size.rawValue as CFString, sizeValue)
        }

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return true
    }

    // MARK: - State changes

    func minimize(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        return AXUIElementSetAttributeValue(
            winElement, NSAccessibility.Attribute.minimized.rawValue as CFString,
            NSNumber(value: true)) == .success
    }

    func unminimize(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        return AXUIElementSetAttributeValue(
            winElement, NSAccessibility.Attribute.minimized.rawValue as CFString,
            NSNumber(value: false)) == .success
    }

    func close(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            winElement, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
            let buttonRef = buttonRef
        else { return false }
        return AXUIElementPerformAction(
            unsafeBitCast(buttonRef, to: AXUIElement.self),
            kAXPressAction as CFString) == .success
    }

    func raise(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        return AXUIElementPerformAction(winElement, kAXRaiseAction as CFString) == .success
    }

    func focus(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        AXUIElementPerformAction(winElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            winElement, NSAccessibility.Attribute.main.rawValue as CFString,
            NSNumber(value: true))
        var pid: pid_t = 0
        if AXUIElementGetPid(winElement, &pid) == .success {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            }
        }
        return true
    }

    func toggleZoom(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            winElement, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
            let buttonRef = buttonRef
        else { return false }
        return AXUIElementPerformAction(
            unsafeBitCast(buttonRef, to: AXUIElement.self),
            kAXPressAction as CFString) == .success
    }

    func setFullScreen(_ fullScreen: Bool, forWindowID id: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: id) else { return false }
        return AXUIElementSetAttributeValue(
            winElement, "AXFullScreen" as CFString,
            fullScreen ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    @_silgen_name("CGSSetDebugOptions")
    private static func cgsSetDebugOptions(_ options: Int32)

    private static let kCGSDebugOptionNormal: Int32 = 0
    private static let kCGSDebugOptionNoShadows: Int32 = 16384

    func setShadows(_ enabled: Bool) {
        ProductionWindow.cgsSetDebugOptions(enabled ? ProductionWindow.kCGSDebugOptionNormal : ProductionWindow.kCGSDebugOptionNoShadows)
    }

    func setTimeout(_ seconds: Float) -> Bool {
        timeoutSeconds = seconds
        AXUIElementSetMessagingTimeout(_prodSystemWideElement, seconds)
        return true
    }

    func focusTab(_ tabIndex: Int32, forWindowID id: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: id) else { return false }
        guard let tabGroup = findTabGroup(winElement) else { return false }
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

    func snapshot(windowID: UInt32, keepTransparency: Bool) -> Data? {
        return snapshotForID(windowID, keepTransparency: keepTransparency)
    }

    func snapshotForID(_ windowID: UInt32, keepTransparency: Bool) -> Data? {
        let imageOption: CGWindowImageOption = keepTransparency ? [] : .shouldBeOpaque
        guard let cgImage = _productionCGWindowListCreateImage?(
            CGRect.null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, imageOption])
        else { return nil }
        let nsImage = NSImage(cgImage: cgImage,
                               size: NSSize(width: cgImage.width, height: cgImage.height))
        return nsImage.tiffRepresentation
    }

    func cornerRadius(forWindowID id: UInt32) -> Double {
        guard id != 0 else { return 0 }
        let cid = SLSMainConnectionID()
        let windowArray = [NSNumber(value: id)] as CFArray
        guard let query = _prodSLSWindowQueryWindows(cid, windowArray, 0x0) else { return 0 }
        guard let iterator = _prodSLSWindowQueryResultCopyWindows(query) else { return 0 }
        guard _prodSLSWindowIteratorGetCount(iterator) > 0 else { return 0 }
        guard _prodSLSWindowIteratorAdvance(iterator) else { return 0 }
        guard let radiiRef = _prodSLSWindowIteratorGetCornerRadii(iterator) else { return 0 }
        let radii = radiiRef as NSArray
        guard radii.count > 0, let value = radii[0] as? NSNumber else { return 0 }
        let radius = CGFloat(value.doubleValue)
        return radius > 0 ? Double(radius) : 0
    }

    func becomeMain(windowID: UInt32) -> Bool {
        guard let winElement = findWindowElement(id: windowID) else { return false }
        return AXUIElementSetAttributeValue(
            winElement, NSAccessibility.Attribute.main.rawValue as CFString,
            NSNumber(value: true)) == .success
    }

    func zoomButtonRect(forWindowID id: UInt32) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let winElement = findWindowElement(id: id) else { return nil }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            winElement, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
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

    func isMaximizable(forWindowID id: UInt32) -> Bool? {
        guard let winElement = findWindowElement(id: id) else { return nil }
        var buttonRef: CFTypeRef?
        var isEnabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            winElement, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
            let buttonElement = buttonRef,
            AXUIElementCopyAttributeValue(
                buttonElement as! AXUIElement, kAXEnabledAttribute as CFString,
                &isEnabled) == .success
        else { return nil }
        guard let boolVal = isEnabled else { return nil }
        return CFBooleanGetValue(unsafeBitCast(boolVal, to: CFBoolean.self))
    }

    func listWindowInfo(allWindows: Bool) -> [[String: Any]] {
        var windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID) as? [NSDictionary] ?? []

        if !allWindows {
            var dockWindowNumber: CGWindowID = 0
            for win in windows {
                if let name = win[kCGWindowName as String] as? String, name == "Dock",
                   let num = win[kCGWindowNumber as String] as? NSNumber {
                    dockWindowNumber = CGWindowID(num.uint32Value)
                    break
                }
            }
            if dockWindowNumber != 0 {
                windows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenBelowWindow, .excludeDesktopElements],
                    dockWindowNumber) as? [NSDictionary] ?? []
            }
        }

        return windows.map { $0 as! [String: Any] }
    }

    func spaces(forWindowID id: UInt32) -> [Int] {
        let cid = SLSMainConnectionID()
        let windowList = [NSNumber(value: id)] as CFArray
        guard let spacesRef = SLSCopySpacesForWindows(cid, 0x7, windowList) else { return [] }
        let arr = spacesRef as NSArray
        return arr.compactMap { ($0 as? NSNumber)?.intValue }
    }

    // MARK: - Private

    private func findWindowElement(id: UInt32) -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular
        {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                let windowsRef = windowsRef
            else { continue }
            let windowsArray = unsafeBitCast(windowsRef, to: CFArray.self)
            let count = CFArrayGetCount(windowsArray)
            for i in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(windowsArray, i) else { continue }
                let winElement = unsafeBitCast(raw, to: AXUIElement.self)
                var wID: CGWindowID = 0
                if _AXUIElementGetWindow(winElement, &wID) == .success && wID == id {
                    return winElement
                }
            }
        }
        return nil
    }

    private func axWindowInfoFromElement(_ element: AXUIElement) -> AXWindowInfo? {
        var wID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wID) == .success else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let title = axStringAttr(element, NSAccessibility.Attribute.title.rawValue)
        let role = axStringAttr(element, NSAccessibility.Attribute.role.rawValue) ?? "AXWindow"
        let subrole = axStringAttr(element, NSAccessibility.Attribute.subrole.rawValue)

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

        let isMinimized = axBoolAttr(element, NSAccessibility.Attribute.minimized.rawValue)
        let isFullScreen = axBoolAttr(element, "AXFullScreen")
        let isStandard = subrole == kAXStandardWindowSubrole as String

        return AXWindowInfo(
            id: wID, title: title, role: role, subrole: subrole,
            frame: (Double(position.x), Double(position.y),
                    Double(size.width), Double(size.height)),
            pid: pid, isMinimized: isMinimized, isFullScreen: isFullScreen,
            level: 0, alpha: 1.0, isStandard: isStandard,
            isVisible: !isMinimized, isMaximizable: true,
            tabCount: 1, cornerRadius: 10.0
        )
    }

    private func axStringAttr(_ e: AXUIElement, _ a: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &ref) == .success,
              let ref = ref
        else { return nil }
        return ref as? String
    }

    private func axBoolAttr(_ e: AXUIElement, _ a: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &ref) == .success,
              let val = ref as? NSNumber
        else { return false }
        return val.boolValue
    }

    private func findTabGroup(_ element: AXUIElement) -> AXUIElement? {
        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(
            element, kAXChildrenAttribute as CFString, 0, 100, &childrenRef) == .success,
            let children = childrenRef
        else { return nil }
        let count = CFArrayGetCount(children)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(children, i) else { continue }
            let child = unsafeBitCast(rawPtr, to: AXUIElement.self)
            if axStringAttr(child, NSAccessibility.Attribute.role.rawValue)
                == kAXTabGroupRole as String
            { return child }
        }
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(children, i) else { continue }
            let child = unsafeBitCast(rawPtr, to: AXUIElement.self)
            guard axStringAttr(child, NSAccessibility.Attribute.role.rawValue)
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
}
