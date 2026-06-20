import Cocoa
import HSDSTCore
import os.log

/// Production implementation of ApplicationProtocol.
/// Delegates to NSRunningApplication, NSWorkspace, AXUIElement, and Launch Services.
public final class ProductionApplication: ApplicationProtocol {

    public init() {}

    // MARK: - Application lookup

    public func frontmostApplication() -> ApplicationInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return appInfo(from: app)
    }

    public func runningApplications() -> [ApplicationInfo] {
        let traceState = CHTrace.signposter.beginInterval("RunningApplications")
        defer { CHTrace.signposter.endInterval("RunningApplications", traceState) }
        return NSWorkspace.shared.runningApplications.map { appInfo(from: $0) }
    }

    public func applicationForPID(_ pid: Int32) -> ApplicationInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return appInfo(from: app)
    }

    public func applicationsForBundleID(_ bundleID: String) -> [ApplicationInfo] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { appInfo(from: $0) }
    }

    // MARK: - Bundle info

    public func nameForBundleID(_ bundleID: String) -> String? {
        guard let path = pathForBundleID(bundleID),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
    }

    public func pathForBundleID(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    public func infoForBundleID(_ bundleID: String) -> [String: Any]? {
        guard let path = pathForBundleID(bundleID) else { return nil }
        return infoForBundlePath(path)
    }

    public func infoForBundlePath(_ bundlePath: String) -> [String: Any]? {
        Bundle(path: bundlePath)?.infoDictionary
    }

    public func preferredLocalizationsForBundleID(_ bundleID: String) -> [String]? {
        guard let path = pathForBundleID(bundleID) else { return nil }
        return preferredLocalizationsForBundlePath(path)
    }

    public func preferredLocalizationsForBundlePath(_ bundlePath: String) -> [String]? {
        Bundle(path: bundlePath)?.preferredLocalizations
    }

    public func localizationsForBundleID(_ bundleID: String) -> [String]? {
        guard let path = pathForBundleID(bundleID) else { return nil }
        return localizationsForBundlePath(path)
    }

    public func localizationsForBundlePath(_ bundlePath: String) -> [String]? {
        Bundle(path: bundlePath)?.localizations
    }

    // MARK: - Launch Services

    public func defaultAppForUTI(_ uti: String) -> String? {
        let cfUTI = uti as CFString
        if let handler = LSCopyDefaultRoleHandlerForContentType(cfUTI, LSRolesMask.all) {
            return handler.takeRetainedValue() as String
        }
        if let handler = LSCopyDefaultHandlerForURLScheme(cfUTI) {
            return handler.takeRetainedValue() as String
        }
        return nil
    }

    // MARK: - App launch

    public func launchOrFocus(_ name: String) -> Bool {
        NSWorkspace.shared.launchApplication(name)
    }

    public func launchOrFocusByBundleID(_ bundleID: String) -> Bool {
        NSWorkspace.shared.launchApplication(
            withBundleIdentifier: bundleID,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifier: nil)
    }

    // MARK: - Instance operations

    public func activate(pid: Int32, allWindows: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        var options: NSApplication.ActivationOptions = []
        if allWindows { options.insert(.activateAllWindows) }
        return app.activate(options: options)
    }

    public func setFrontmost(pid: Int32, allWindows: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        var options: NSApplication.ActivationOptions = []
        if allWindows { options.insert(.activateAllWindows) }
        return app.activate(options: options)
    }

    public func hide(pid: Int32) -> Bool {
        let elementRef = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(elementRef,
                                     NSAccessibility.Attribute.hidden.rawValue as CFString,
                                     kCFBooleanTrue)
        return isHidden(pid: pid)
    }

    public func unhide(pid: Int32) -> Bool {
        let elementRef = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(elementRef,
                                     NSAccessibility.Attribute.hidden.rawValue as CFString,
                                     kCFBooleanFalse)
        return !isHidden(pid: pid)
    }

    public func isHidden(pid: Int32) -> Bool {
        let elementRef = AXUIElementCreateApplication(pid)
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elementRef,
                                         NSAccessibility.Attribute.hidden.rawValue as CFString,
                                         &valueRef) == .success,
           let num = valueRef as? NSNumber {
            return num.boolValue
        }
        return false
    }

    public func isFrontmost(pid: Int32) -> Bool {
        let elementRef = AXUIElementCreateApplication(pid)
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elementRef,
                                         NSAccessibility.Attribute.frontmost.rawValue as CFString,
                                         &valueRef) == .success,
           let num = valueRef as? NSNumber {
            return num.boolValue
        }
        return false
    }

    public func kill(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate()
    }

    public func kill9(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.forceTerminate()
    }

    public func isRunning(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    public func isResponsive(pid: Int32) -> Bool {
        var psn = ProcessSerialNumber()
        _GetProcessForPID(pid, &psn)
        let conn = CGSMainConnectionID()
        return !CGSEventIsAppUnresponsive(conn, &psn)
    }

    public func kind(pid: Int32) -> Int32 {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return -1 }
        switch app.activationPolicy {
        case .accessory:   return 0
        case .prohibited:  return -1
        default:           return 1
        }
    }

    public func title(pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName
    }

    public func bundleID(pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.bundleIdentifier
    }

    public func path(pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard let url = app.bundleURL else { return nil }
        return Bundle(url: url)?.bundlePath
    }

    // MARK: - Window queries

    public func allWindows(pid: Int32) -> [AXWindowInfo] {
        let elementRef = AXUIElementCreateApplication(pid)
        var windowsRef: CFArray?
        guard AXUIElementCopyAttributeValues(elementRef, kAXWindowsAttribute as CFString, 0, 100, &windowsRef) == .success,
              let windows = windowsRef else { return [] }
        let count = CFArrayGetCount(windows)
        var result: [AXWindowInfo] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(windows, i) else { continue }
            let win = unsafeBitCast(rawPtr, to: AXUIElement.self)
            if let info = axWindowInfo(from: win, pid: pid) {
                result.append(info)
            }
        }
        return result
    }

    public func mainWindow(pid: Int32) -> AXWindowInfo? {
        let elementRef = AXUIElementCreateApplication(pid)
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXMainWindowAttribute as CFString, &valueRef) == .success,
              let valueRef = valueRef else { return nil }
        return axWindowInfo(from: unsafeBitCast(valueRef, to: AXUIElement.self), pid: pid)
    }

    public func focusedWindow(pid: Int32) -> AXWindowInfo? {
        let elementRef = AXUIElementCreateApplication(pid)
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXFocusedWindowAttribute as CFString, &valueRef) == .success,
              let valueRef = valueRef else { return nil }
        return axWindowInfo(from: unsafeBitCast(valueRef, to: AXUIElement.self), pid: pid)
    }

    // MARK: - Menu queries

    public func getMenuItems(pid: Int32) -> [[String: Any]]? {
        let elementRef = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return nil }
        let result = getMenuStructure(menuBar as! AXUIElement)
        return result as? [[String: Any]]
    }

    public func findMenuItemByPath(pid: Int32, path: [String]) -> (enabled: Bool, marked: Bool)? {
        let elementRef = AXUIElementCreateApplication(pid)
        guard let item = findMenuItemByPathAX(elementRef, path) else { return nil }
        return menuItemState(item)
    }

    public func findMenuItemByName(pid: Int32, name: String, isRegex: Bool) -> (enabled: Bool, marked: Bool)? {
        let elementRef = AXUIElementCreateApplication(pid)
        guard let item = findMenuItemByNameAX(elementRef, name, isRegex) else { return nil }
        return menuItemState(item)
    }

    public func selectMenuItemByPath(pid: Int32, path: [String]) -> Bool {
        let elementRef = AXUIElementCreateApplication(pid)
        guard let item = findMenuItemByPathAX(elementRef, path) else { return false }
        return performPress(item)
    }

    public func selectMenuItemByName(pid: Int32, name: String, isRegex: Bool) -> Bool {
        let elementRef = AXUIElementCreateApplication(pid)
        guard let item = findMenuItemByNameAX(elementRef, name, isRegex) else { return false }
        return performPress(item)
    }

    // MARK: - Private helpers

    private func appInfo(from app: NSRunningApplication) -> ApplicationInfo {
        let kindVal: Int32
        switch app.activationPolicy {
        case .accessory:   kindVal = 0
        case .prohibited:  kindVal = -1
        default:           kindVal = 1
        }

        return ApplicationInfo(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            path: app.bundleURL.flatMap { Bundle(url: $0)?.bundlePath },
            isHidden: app.isHidden,
            isFrontmost: app.isActive,
            isRunning: true,
            kind: kindVal,
            isResponsive: true
        )
    }

    private func axWindowInfo(from win: AXUIElement, pid: Int32) -> AXWindowInfo? {
        var winIDValue: CGWindowID = 0
        _AXUIElementGetWindow(win, &winIDValue)
        guard winIDValue != 0 else { return nil }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "AXWindow"

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String

        var minimizedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedRef)
        let isMinimized = (minimizedRef as? NSNumber)?.boolValue ?? false

        var fullscreenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fullscreenRef)
        let isFullScreen = (fullscreenRef as? NSNumber)?.boolValue ?? false

        var posValue = CGPoint.zero
        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &posValue)
        }
        var sizeValue = CGSize.zero
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &sizeValue)
        }

        return AXWindowInfo(
            id: winIDValue,
            title: title,
            role: role,
            subrole: subrole,
            frame: (Double(posValue.x), Double(posValue.y), Double(sizeValue.width), Double(sizeValue.height)),
            pid: pid,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen,
            level: 0,
            alpha: 1.0,
            isStandard: subrole == "AXStandardWindow",
            isVisible: !isMinimized,
            isMaximizable: true,
            tabCount: 0,
            cornerRadius: 10.0
        )
    }

    // MARK: - Menu AX helpers

    private func findMenuItemByNameAX(_ app: AXUIElement, _ name: String, _ nameIsRegex: Bool) -> AXUIElement? {
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return nil }

        var count: CFIndex = -1
        guard AXUIElementGetAttributeValueCount(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &count) == .success else { return nil }
        var cfChildren: CFArray?
        guard AXUIElementCopyAttributeValues(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, 0, count, &cfChildren) == .success,
              let children = cfChildren else { return nil }

        let toCheck = NSMutableArray()
        toCheck.addObjects(from: (children as? [Any]) ?? [])

        var i = 5000
        while i > 0 {
            i -= 1
            if toCheck.count == 0 { break }
            let element = toCheck[0] as! AXUIElement
            toCheck.remove(toCheck[0])

            var cfTitle: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &cfTitle)
            let title = cfTitle as? String

            var childcount: CFIndex = -1
            guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childcount) == .success else { continue }
            if childcount > 0 {
                var cfMenuchildren: CFArray?
                guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, childcount, &cfMenuchildren) == .success,
                      let menuchildren = cfMenuchildren else { continue }
                toCheck.addObjects(from: (menuchildren as? [Any]) ?? [])
            } else if childcount == 0 {
                if !nameIsRegex && name == title {
                    return element
                } else if nameIsRegex {
                    let matchTest = NSPredicate(format: "SELF MATCHES %@", name)
                    if matchTest.evaluate(with: title) {
                        return element
                    }
                }
            }
        }
        return nil
    }

    private func findMenuItemByPathAX(_ app: AXUIElement, _ path: [String]) -> AXUIElement? {
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return nil }

        var searchItem: AXUIElement = menuBar as! AXUIElement
        var remaining = path

        var i = 5000
        while i > 0 {
            i -= 1
            guard let children = fetchChildrenUnwrappingMenu(searchItem) else { break }
            guard !remaining.isEmpty else { break }
            let nextTitle = remaining.removeFirst()
            guard let matched = findChildByTitle(children, nextTitle) else { break }
            searchItem = matched
            if remaining.isEmpty { return searchItem }
        }
        return nil
    }

    private func fetchChildrenUnwrappingMenu(_ element: AXUIElement) -> CFArray? {
        var count: CFIndex = -1
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else { return nil }
        var cfChildren: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &cfChildren) == .success,
              var children = cfChildren else { return nil }
        if count > 0, let unwrapped = unwrapAXMenuChildren(children) {
            children = unwrapped
        }
        return children
    }

    private func unwrapAXMenuChildren(_ children: CFArray) -> CFArray? {
        guard let firstPtr = CFArrayGetValueAtIndex(children, 0) else { return nil }
        let firstElement = Unmanaged<AXUIElement>.fromOpaque(firstPtr).takeUnretainedValue()
        var cfRole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(firstElement, kAXRoleAttribute as CFString, &cfRole) == .success else { return nil }
        guard CFStringCompare(cfRole as! CFString, kAXMenuRole as CFString, []) == .compareEqualTo else { return nil }
        var axMenuCount: CFIndex = -1
        guard AXUIElementGetAttributeValueCount(firstElement, kAXChildrenAttribute as CFString, &axMenuCount) == .success else { return nil }
        var axMenuChildren: CFArray?
        guard AXUIElementCopyAttributeValues(firstElement, kAXChildrenAttribute as CFString, 0, axMenuCount, &axMenuChildren) == .success,
              let result = axMenuChildren else { return nil }
        return result
    }

    private func findChildByTitle(_ children: CFArray, _ title: String) -> AXUIElement? {
        let childCount = CFArrayGetCount(children)
        for j in 0..<childCount {
            let ptr = CFArrayGetValueAtIndex(children, j)!
            let element = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            var cfTitle: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &cfTitle) == .success else { continue }
            if title == (cfTitle as? String ?? "") { return element }
        }
        return nil
    }

    private func menuItemState(_ item: AXUIElement) -> (enabled: Bool, marked: Bool) {
        var enabledRef: CFTypeRef?
        let enabledOk = AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledRef) == .success
        let enabled = enabledOk && (enabledRef as? NSNumber)?.boolValue == true

        var markRef: CFTypeRef?
        let markError = AXUIElementCopyAttributeValue(item, kAXMenuItemMarkCharAttribute as CFString, &markRef)
        let marked = (markError != .noValue && markError == .success)

        return (enabled, marked)
    }

    private func performPress(_ item: AXUIElement) -> Bool {
        var axError: AXError = .success
        if let _ = catchingObjCException({
            axError = AXUIElementPerformAction(item, kAXPressAction as CFString)
        }) {
            return false
        }
        return axError == .success
    }

    // Carbon enum constants
    private let kAXMenuItemModifierNone: Int      = 0
    private let kAXMenuItemModifierShift: Int     = 1 << 0
    private let kAXMenuItemModifierOption: Int    = 1 << 1
    private let kAXMenuItemModifierControl: Int   = 1 << 2
    private let kAXMenuItemModifierNoCommand: Int = 1 << 3

    private func getMenuStructure(_ menuItem: AXUIElement) -> Any {
        let attributeNames = NSMutableArray(array: [
            kAXTitleAttribute as String,
            kAXRoleAttribute as String,
            kAXMenuItemMarkCharAttribute as String,
            kAXMenuItemCmdCharAttribute as String,
            kAXMenuItemCmdModifiersAttribute as String,
            kAXEnabledAttribute as String,
            kAXMenuItemCmdGlyphAttribute as String,
        ])

        var cfAttributeValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(menuItem, attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &cfAttributeValues)

        if result != AXError.success { return NSNull() }

        // Skip Apple menu
        if let cfValues = cfAttributeValues,
           let firstPtr = CFArrayGetValueAtIndex(cfValues, 0) {
            let typeID = CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(firstPtr).takeUnretainedValue())
            if typeID == CFStringGetTypeID() {
                let firstStr = Unmanaged<CFString>.fromOpaque(firstPtr).takeUnretainedValue()
                if CFStringCompare(firstStr, "Apple" as CFString, []) == .compareEqualTo {
                    return NSNull()
                }
            }
        }

        guard let cfValues = cfAttributeValues else { return NSNull() }
        let attributeValues = NSMutableArray(array: (cfValues as? [Any]) ?? [])

        // Replace AXError values
        for j in 0..<attributeValues.count {
            if CFGetTypeID(attributeValues[j] as CFTypeRef) == AXValueGetTypeID() {
                if AXValueGetType(attributeValues[j] as! AXValue) == .axError {
                    attributeValues[j] = ""
                }
            }
        }

        // Replace modifiers
        let modifiersIndex = attributeNames.index(of: kAXMenuItemCmdModifiersAttribute as String)
        if let modsNum = attributeValues[modifiersIndex] as? NSNumber {
            let modsInt = modsNum.intValue
            let modsArr = NSMutableArray()
            if (modsInt & kAXMenuItemModifierNoCommand) == 0 { modsArr.add("cmd") }
            if (modsInt & kAXMenuItemModifierShift) != 0     { modsArr.add("shift") }
            if (modsInt & kAXMenuItemModifierOption) != 0    { modsArr.add("alt") }
            if (modsInt & kAXMenuItemModifierControl) != 0   { modsArr.add("ctrl") }
            attributeValues[modifiersIndex] = modsArr
        } else {
            attributeValues[modifiersIndex] = NSNull()
        }

        // Collect children
        var cfChildren: CFArray?
        var children: NSMutableArray?
        if AXUIElementCopyAttributeValues(menuItem, kAXChildrenAttribute as CFString, 0, CFIndex(INT32_MAX), &cfChildren) == .success,
           let cfChildrenUnwrapped = cfChildren {
            children = NSMutableArray()
            let numChildren = CFArrayGetCount(cfChildrenUnwrapped)
            for i in 0..<numChildren {
                let childPtr = CFArrayGetValueAtIndex(cfChildrenUnwrapped, i)!
                let child = Unmanaged<AXUIElement>.fromOpaque(childPtr).takeUnretainedValue()
                let childValues = getMenuStructure(child)
                if !(childValues is NSNull) { children!.add(childValues) }
            }
        }

        if let children = children, children.count > 0 {
            attributeNames.add(kAXChildrenAttribute as String)
            attributeValues.add(children)
        }

        let roleValue = attributeValues[1] as? String ?? ""
        if roleValue == "AXMenuItem" || roleValue == "AXMenuBarItem" {
            let thisMenuItem = NSMutableDictionary(objects: attributeValues as! [Any], forKeys: attributeNames as! [NSCopying])
            if thisMenuItem.count > 0 { return thisMenuItem }
        } else {
            if let children = children, children.count > 0 { return children }
        }
        return NSNull()
    }
}
