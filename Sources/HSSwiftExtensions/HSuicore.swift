// HSuicore.swift — Swift port of HSuicore.m
// Compiled as part of HSSwiftExtensions (pure Swift target).
// External access from ObjC uses @objc(ClassName) + NSClassFromString.

import Foundation
import AppKit
import ApplicationServices
import CLua
import CoreGraphics
import Lua
import Darwin
import os.log

// MARK: - Private C API declarations

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSEventIsAppUnresponsive")
func CGSEventIsAppUnresponsive(_ cid: Int32, _ psn: UnsafePointer<ProcessSerialNumber>) -> Bool

// GetProcessForPID is deprecated and unavailable in Swift; load via silgen_name
@_silgen_name("GetProcessForPID")
@discardableResult
func _GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// CGWindowListCreate is marked unavailable in Swift SDK; load via silgen_name
@_silgen_name("CGWindowListCreate")
func _CGWindowListCreate(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID) -> CFArray?

// MARK: - CGWindowListCreateImage via dlsym (obsoleted in macOS 15 SDK)

private let hs_CGWindowListCreateImage: ((CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?)? = {
    typealias Fn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?
    guard let sym = dlsym(nil, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: Fn.self)
}()

// MARK: - System-wide AX element singleton

private let _systemWideElement: AXUIElement = AXUIElementCreateSystemWide()

// MARK: - get_window_tabs helper

// Returns a +1 retained AXUIElement, or nil. Caller must CFRelease if non-nil.
// In Swift we return a managed AXUIElement and rely on ARC.
private func getWindowTabs(_ win: AXUIElement) -> AXUIElement? {
    var childrenRef: CFArray?
    guard AXUIElementCopyAttributeValues(win, kAXChildrenAttribute as CFString, 0, 100, &childrenRef) == .success,
          let children = childrenRef else {
        return nil
    }

    let count = CFArrayGetCount(children)

    // First pass: look for AXTabGroup role
    for i in 0 ..< count {
        guard let rawPtr = CFArrayGetValueAtIndex(children, i) else { continue }
        let child = unsafeBitCast(rawPtr, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { continue }
        if role == (kAXTabGroupRole as String) {
            return child
        }
    }

    // Second pass: Safari 14+ puts tabs inside AXGroup with an AXTabs attribute
    for i in 0 ..< count {
        guard let rawPtr = CFArrayGetValueAtIndex(children, i) else { continue }
        let child = unsafeBitCast(rawPtr, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String,
              role == (kAXGroupRole as String) else { continue }
        var attrNamesRef: CFArray?
        guard AXUIElementCopyAttributeNames(child, &attrNamesRef) == .success,
              let attrNames = attrNamesRef as? [String] else { continue }
        if attrNames.contains(kAXTabsAttribute as String) {
            return child
        }
    }

    return nil
}

// MARK: - HSuielement

@objc(HSuielement) class HSuielement: NSObject, HSuielementProtocol {

    // MARK: Stored properties

    private var _elementRef: AXUIElement

    var elementRef: AXUIElement { _elementRef }
    var selfRefCount: Int32 = 0

    // MARK: Init / deinit

    init(withElement ref: AXUIElement) {
        _elementRef = ref
        selfRefCount = 0
        super.init()
    }

    // MARK: Protocol-required factory method matching ObjC selector initWithElementRef:

    @objc(initWithElementRef:) func initWithElementRef(_ ref: AXUIElement) -> NSObject? {
        return HSuielement(withElement: ref)
    }

    // MARK: Class methods

    @objc(focusedElement) static func focusedElement() -> NSObject? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard error == .success, let focusedRef = focusedRef else { return nil }
        return HSuielement(withElement: unsafeBitCast(focusedRef, to: AXUIElement.self))
    }

    // MARK: Computed properties

    var isApplication: Bool {
        role == (kAXApplicationRole as String)
    }

    var isWindow: Bool {
        isWindowForRole(role)
    }

    var role: String {
        getRole()
    }

    var selectedText: String {
        getSelectedText() ?? ""
    }

    // MARK: Instance methods

    func newWatcher(atIndex callbackRefIndex: Int32,
                    withUserdataAtIndex userDataRefIndex: Int32,
                    withLuaState L: UnsafeMutablePointer<lua_State>!) -> NSObject? {
        let handlerCb = L.ref(index: callbackRefIndex)
        var userDataVal: LuaValue? = nil
        if lua_type(L, userDataRefIndex) != LUA_TNONE {
            userDataVal = L.ref(index: userDataRefIndex)
        }
        let watcher = HSuielementWatcher(element: self,
                                        handlerCallback: handlerCb,
                                        userDataValue: userDataVal)
        watcher.lsCanary = lua_currentStateGeneration()
        return watcher
    }

    func getElementProperty(_ property: String, withDefaultValue defaultValue: Any?) -> Any? {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef, property as CFString, &valueRef) == .success,
           let valueRef = valueRef {
            return valueRef as AnyObject
        }
        return defaultValue
    }

    func getRole() -> String {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef,
                                         NSAccessibility.Attribute.role.rawValue as CFString,
                                         &valueRef) == .success,
           let str = valueRef as? String {
            return str
        }
        return ""
    }

    func getSelectedText() -> String? {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef, kAXSelectedTextAttribute as CFString, &valueRef) == .success,
           let str = valueRef as? String {
            return str
        }
        return nil
    }

    // isWindow with explicit role parameter (matches ObjC interface)
    func isWindow(_ roleParam: String) -> Bool {
        return isWindowForRole(roleParam)
    }

    private func isWindowForRole(_ roleParam: String) -> Bool {
        if roleParam == (kAXWindowRole as String) { return true }
        // Duck-typing: check for minimized attribute presence
        return getElementProperty(NSAccessibility.Attribute.minimized.rawValue, withDefaultValue: nil) != nil
    }
}

// MARK: - Watcher callback (global C function pointer)

private let watcherCallback: AXObserverCallback = { _, element, notificationName, contextData in
    guard let contextData = contextData else { return }
    let watcher = Unmanaged<HSuielementWatcher>.fromOpaque(contextData).takeUnretainedValue()

    guard let L = lua_getCurrentState() else { return }
    guard lua_isStateGenerationValid(watcher.lsCanary) else { return }

    // Push callback function
    guard let cb = watcher.handlerCallback else { return }
    cb.push(onto: L)

    // Determine what kind of object to push as parameter 1
    let elementObj = HSuielement(withElement: element)
    if elementObj.isWindow {
        _ = pushHSwindow(L, HSwindow(axuiElementRef: element))
    } else if elementObj.isApplication {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let app = HSapplication(pid: pid, withState: L) {
            _ = pushHSapplication(L, app)
        } else {
            _ = pushHSuielement(L, elementObj)
        }
    } else {
        _ = pushHSuielement(L, elementObj)
    }

    // Parameter 2: event name
    L.push(notificationName as String)

    // Parameter 3: watcher
    if let ws = watcher.watcherSelfRef {
        ws.push(onto: L)
    } else {
        lua_pushnil(L)
    }

    // Parameter 4: userData
    if let ud = watcher.userDataValue {
        ud.push(onto: L)
    } else {
        lua_pushnil(L)
    }

    if lua_pcall(L, 4, 0, 0) != LUA_OK {
        if let errorMsg = lua_tostring(L, -1) {
            os_log(.error, "%{public}s", String(cString: errorMsg))
        }
        lua_pop(L, 1)
    }
}

// MARK: - HSuielementWatcher

@objc(HSuielementWatcher) class HSuielementWatcher: NSObject, HSuielementWatcherProtocol {

    var selfRefCount: Int32 = 0
    private var _elementRef: AXUIElement
    var elementRef: AXUIElement {
        get { _elementRef }
        set { _elementRef = newValue }
    }
    var refTable: Int32
    var handlerRef: Int32
    var userDataRef: Int32
    var watcherRef: Int32
    private var _observer: AXObserver?
    var observer: AXObserver {
        get { _observer! }
        set { _observer = newValue }
    }
    var running: Bool = false
    var pid: pid_t = 0
    var watchDestroyed: Bool = false
    var lsCanary: UInt64 = 0

    // LuaValue-based callback/ref storage (replaces raw luaL_ref integers)
    var handlerCallback: LuaValue?
    var userDataValue: LuaValue?
    var watcherSelfRef: LuaValue?
    private var tornDown = false

    init(element: HSuielement, handlerCallback: LuaValue, userDataValue: LuaValue?) {
        refTable = LUA_REGISTRYINDEX_VALUE
        _elementRef = element.elementRef
        handlerRef = LUA_NOREF
        userDataRef = LUA_NOREF
        watcherRef = LUA_NOREF
        running = false
        watchDestroyed = false
        super.init()
        self.handlerCallback = handlerCallback
        self.userDataValue = userDataValue
        AXUIElementGetPid(_elementRef, &pid)
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stop()
        handlerCallback = nil
        userDataValue = nil
        watcherSelfRef = nil
    }

    func start(_ events: [String], withState L: UnsafeMutablePointer<lua_State>!) {
        guard !running else { return }

        var obs: AXObserver?
        let err = AXObserverCreate(pid, watcherCallback, &obs)
        guard err == .success, let obs = obs else {
            os_log(.default, "BREADCRUMB: AXObserverCreate error: %d", err.rawValue)
            return
        }

        // Pass self as unretained pointer; watcher's lifetime is managed by Lua
        let contextPtr = Unmanaged.passUnretained(self).toOpaque()
        for event in events {
            AXObserverAddNotification(obs, _elementRef, event as CFString, contextPtr)
        }

        _observer = obs
        running = true

        CFRunLoopAddSource(RunLoop.current.getCFRunLoop(),
                           AXObserverGetRunLoopSource(obs),
                           CFRunLoopMode.defaultMode)
    }

    func stop() {
        guard running, let obs = _observer else { return }
        CFRunLoopRemoveSource(RunLoop.current.getCFRunLoop(),
                              AXObserverGetRunLoopSource(obs),
                              CFRunLoopMode.defaultMode)
        running = false
    }
}

// MARK: - HSapplication

@objc(HSapplication) class HSapplication: NSObject, HSapplicationProtocol {

    private var _elementRef: AXUIElement
    var elementRef: AXUIElement { _elementRef }
    private(set) var pid: pid_t
    private(set) var runningApp: NSRunningApplication
    private(set) var uiElement: NSObject
    var selfRefCount: Int32 = 0

    // MARK: Init / deinit

    convenience init?(pid thePID: pid_t, withState L: UnsafeMutablePointer<lua_State>!) {
        guard let app = NSRunningApplication(processIdentifier: thePID) else {
            os_log(.error, "Unable to fetch NSRunningApplication for pid: %d", thePID)
            return nil
        }
        self.init(nsRunningApplication: app, withState: L)
    }

    convenience init?(nsRunningApplication app: NSRunningApplication,
                      withState L: UnsafeMutablePointer<lua_State>!) {
        guard let app2 = app as NSRunningApplication? else {
            os_log(.error, "HSapplication::initWithNSRunningApplication called with invalid application")
            return nil
        }
        let appRef = AXUIElementCreateApplication(app2.processIdentifier)
        self.init(runningApp: app2, elementRef: appRef)
    }

    private init(runningApp app: NSRunningApplication, elementRef ref: AXUIElement) {
        pid = app.processIdentifier
        _elementRef = ref
        runningApp = app
        uiElement = HSuielement(withElement: ref)
        selfRefCount = 0
        super.init()
    }

    // MARK: Class factory methods

    static func frontmostApplication(withState L: UnsafeMutablePointer<lua_State>!) -> HSapplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            os_log(.error, "Unable to fetch frontmost application")
            return nil
        }
        let result = HSapplication(nsRunningApplication: app, withState: L)
        if result == nil {
            os_log(.error, "HSapplication::frontmostApplication failed for app: %{public}s", app.localizedName ?? "<unknown>")
        }
        return result
    }

    static func application(forNSRunningApplication app: NSRunningApplication,
                            withState L: UnsafeMutablePointer<lua_State>!) -> HSapplication? {
        return HSapplication(nsRunningApplication: app, withState: L)
    }

    static func application(forPID thePID: pid_t,
                            withState L: UnsafeMutablePointer<lua_State>!) -> HSapplication? {
        return HSapplication(pid: thePID, withState: L)
    }

    @objc static func name(forBundleID bundleID: String) -> String? {
        guard let path = Self.path(forBundleID: bundleID),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
    }

    @objc static func path(forBundleID bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    @objc static func info(forBundleID bundleID: String) -> NSDictionary? {
        guard let path = Self.path(forBundleID: bundleID) else { return nil }
        return Self.info(forBundlePath: path)
    }

    @objc static func info(forBundlePath bundlePath: String) -> NSDictionary? {
        Bundle(path: bundlePath)?.infoDictionary as NSDictionary?
    }

    @objc static func preferredLocalizations(forBundleID bundleID: String) -> [String]? {
        guard let path = Self.path(forBundleID: bundleID) else { return nil }
        return Self.preferredLocalizations(forBundlePath: path)
    }

    @objc static func preferredLocalizations(forBundlePath bundlePath: String) -> [String]? {
        Bundle(path: bundlePath)?.preferredLocalizations
    }

    @objc static func localizations(forBundleID bundleID: String) -> [String]? {
        guard let path = Self.path(forBundleID: bundleID) else { return nil }
        return Self.localizations(forBundlePath: path)
    }

    @objc static func localizations(forBundlePath bundlePath: String) -> [String]? {
        Bundle(path: bundlePath)?.localizations
    }

    static func runningApplications(withState L: UnsafeMutablePointer<lua_State>!) -> [HSapplication] {
        NSWorkspace.shared.runningApplications.compactMap {
            HSapplication(nsRunningApplication: $0, withState: L)
        }
    }

    static func applications(forBundleID bundleID: String,
                             withState L: UnsafeMutablePointer<lua_State>!) -> [HSapplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap {
            HSapplication(nsRunningApplication: $0, withState: L)
        }
    }

    @objc static func launchByName(_ name: String) -> Bool {
        NSWorkspace.shared.launchApplication(name)
    }

    @objc static func launchByBundleID(_ bundleID: String) -> Bool {
        NSWorkspace.shared.launchApplication(
            withBundleIdentifier: bundleID,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifier: nil)
    }

    // MARK: hidden property

    // Protocol declares `hidden: Bool { get set }` — expose as a plain computed property.
    var hidden: Bool {
        get { isHidden() }
        set { _setHidden(newValue) }
    }

    func isHidden() -> Bool {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef,
                                         NSAccessibility.Attribute.hidden.rawValue as CFString,
                                         &valueRef) == .success,
           let num = valueRef as? NSNumber {
            return num.boolValue
        }
        return false
    }

    // Renamed to avoid ObjC selector conflict with the `hidden` property setter.
    func _setHidden(_ shouldHide: Bool) {
        AXUIElementSetAttributeValue(_elementRef,
                                     NSAccessibility.Attribute.hidden.rawValue as CFString,
                                     shouldHide ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // MARK: Instance methods

    func allWindows() -> [Any]? {
        var windowsRef: CFArray?
        guard AXUIElementCopyAttributeValues(_elementRef, kAXWindowsAttribute as CFString, 0, 100, &windowsRef) == .success,
              let windows = windowsRef else { return [] }
        let count = CFArrayGetCount(windows)
        var result: [HSwindow] = []
        result.reserveCapacity(count)
        for i in 0 ..< count {
            guard let rawPtr = CFArrayGetValueAtIndex(windows, i) else { continue }
            let win = unsafeBitCast(rawPtr, to: AXUIElement.self)
            result.append(HSwindow(axuiElementRef: win))
        }
        return result
    }

    func mainWindow() -> Any? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(_elementRef, kAXMainWindowAttribute as CFString, &valueRef) == .success,
              let valueRef = valueRef else { return nil }
        return HSwindow(axuiElementRef: unsafeBitCast(valueRef, to: AXUIElement.self))
    }

    func focusedWindow() -> Any? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(_elementRef, kAXFocusedWindowAttribute as CFString, &valueRef) == .success,
              let valueRef = valueRef else { return nil }
        return HSwindow(axuiElementRef: unsafeBitCast(valueRef, to: AXUIElement.self))
    }

    func activate(_ allWindows: Bool) -> Bool {
        var options: NSApplication.ActivationOptions = []
        if allWindows { options.insert(.activateAllWindows) }
        return runningApp.activate(options: options)
    }

    func isResponsive() -> Bool {
        var psn = ProcessSerialNumber()
        _GetProcessForPID(pid, &psn)
        let conn = CGSMainConnectionID()
        return !CGSEventIsAppUnresponsive(conn, &psn)
    }

    func isRunning(withState L: UnsafeMutablePointer<lua_State>!) -> Bool {
        return HSapplication(pid: runningApp.processIdentifier, withState: L) != nil
    }

    func setFrontmost(_ allWindows: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        var options: NSApplication.ActivationOptions = []
        if allWindows { options.insert(.activateAllWindows) }
        return app.activate(options: options)
    }

    func isFrontmost() -> Bool {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef,
                                         NSAccessibility.Attribute.frontmost.rawValue as CFString,
                                         &valueRef) == .success,
           let num = valueRef as? NSNumber {
            return num.boolValue
        }
        return false
    }

    func title() -> String? {
        return runningApp.localizedName
    }

    func bundleID() -> String? {
        return runningApp.bundleIdentifier
    }

    func path() -> String? {
        guard let url = runningApp.bundleURL else { return nil }
        return Bundle(url: url)?.bundlePath
    }

    func kill() {
        runningApp.terminate()
    }

    func kill9() {
        runningApp.forceTerminate()
    }

    func kind() -> Int32 {
        switch runningApp.activationPolicy {
        case .accessory:   return 0
        case .prohibited:  return -1
        default:           return 1
        }
    }
}

// MARK: - HSwindow

@objc(HSwindow) class HSwindow: NSObject, HSwindowProtocol {

    private var _elementRef: AXUIElement
    var elementRef: AXUIElement { _elementRef }
    private(set) var pid: pid_t = 0
    private(set) var winID: CGWindowID = 0
    private(set) var uiElement: HSuielement
    var selfRefCount: Int32 = 0

    // MARK: Init / deinit

    @objc(initWithAXUIElementRef:) init(axuiElementRef winRef: AXUIElement) {
        _elementRef = winRef
        uiElement = HSuielement(withElement: winRef)
        selfRefCount = 0
        super.init()

        var thePID: pid_t = 0
        if AXUIElementGetPid(winRef, &thePID) == .success {
            pid = thePID
        }

        var wID: CGWindowID = 0
        if _AXUIElementGetWindow(winRef, &wID) == .success {
            winID = wID
        }
    }

    // MARK: Class methods

    @objc static func orderedWindowIDs() -> [NSNumber] {
        guard let wins = _CGWindowListCreate([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else {
            os_log(.default, "BREADCRUMB: hs.window._orderedwinids CGWindowListCreate returned NULL")
            return []
        }
        guard let windowDescs = CGWindowListCreateDescriptionFromArray(wins) else { return [] }
        var result: [NSNumber] = []
        let count = CFArrayGetCount(wins)
        result.reserveCapacity(count)
        for i in 0 ..< count {
            guard let dictRaw = CFArrayGetValueAtIndex(windowDescs, i) else { continue }
            let dict = unsafeBitCast(dictRaw, to: CFDictionary.self)
            guard let numRaw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCGWindowNumber as CFString).toOpaque()) else { continue }
            let num = unsafeBitCast(numRaw, to: CFNumber.self)
            result.append(num as NSNumber)
        }
        return result
    }

    @objc static func snapshot(forID windowID: CGWindowID, keepTransparency: Bool) -> NSImage? {
        let imageOption: CGWindowImageOption = keepTransparency ? [] : .shouldBeOpaque
        let windowRect = CGRect.null
        guard let windowImage = hs_CGWindowListCreateImage?(
            windowRect,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, imageOption]) else { return nil }
        return NSImage(cgImage: windowImage, size: windowRect.size)
    }

    @objc static func focusedWindow() -> HSwindow? {
        var appRef: CFTypeRef?
        AXUIElementCopyAttributeValue(_systemWideElement, kAXFocusedApplicationAttribute as CFString, &appRef)
        guard let appRef = appRef else { return nil }

        let appElement = unsafeBitCast(appRef, to: AXUIElement.self)
        var winRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement,
                                                    NSAccessibility.Attribute.focusedWindow.rawValue as CFString,
                                                    &winRef)
        guard result == .success, let winRef = winRef else { return nil }
        return HSwindow(axuiElementRef: unsafeBitCast(winRef, to: AXUIElement.self))
    }

    // MARK: Property helpers

    func getWindowProperty(_ property: String, withDefaultValue defaultValue: Any?) -> Any? {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef, property as CFString, &valueRef) == .success,
           let valueRef = valueRef {
            return valueRef as AnyObject
        }
        return defaultValue
    }

    @discardableResult func setWindowProperty(_ property: String, withValue value: Any?) -> Bool {
        guard let value = value as? NSNumber else { return false }
        return AXUIElementSetAttributeValue(_elementRef, property as CFString, value) == .success
    }

    // MARK: Protocol methods

    func title() -> String? {
        getWindowProperty(NSAccessibility.Attribute.title.rawValue, withDefaultValue: "") as? String
    }

    func subRole() -> String? {
        getWindowProperty(NSAccessibility.Attribute.subrole.rawValue, withDefaultValue: "") as? String
    }

    func role() -> String? {
        getWindowProperty(NSAccessibility.Attribute.role.rawValue, withDefaultValue: "") as? String
    }

    func isStandard() -> Bool {
        subRole() == kAXStandardWindowSubrole as String
    }

    func getTopLeft() -> NSPoint {
        var topLeft = CGPoint.zero
        var positionRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef,
                                          NSAccessibility.Attribute.position.rawValue as CFString,
                                          &positionRef) == .success,
           let positionRef = positionRef {
            AXValueGetValue(unsafeBitCast(positionRef, to: AXValue.self), .cgPoint, &topLeft)
        }
        return NSPoint(x: topLeft.x, y: topLeft.y)
    }

    func setTopLeft(_ topLeft: NSPoint) {
        var point = CGPoint(x: topLeft.x, y: topLeft.y)
        if let positionStorage = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(_elementRef,
                                          NSAccessibility.Attribute.position.rawValue as CFString,
                                          positionStorage)
        }
    }

    func getSize() -> NSSize {
        var size = CGSize.zero
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(_elementRef,
                                          NSAccessibility.Attribute.size.rawValue as CFString,
                                          &sizeRef) == .success,
           let sizeRef = sizeRef {
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        }
        return NSSize(width: size.width, height: size.height)
    }

    func setSize(_ size: NSSize) {
        var cgSize = CGSize(width: size.width, height: size.height)
        if let sizeStorage = AXValueCreate(.cgSize, &cgSize) {
            AXUIElementSetAttributeValue(_elementRef,
                                          NSAccessibility.Attribute.size.rawValue as CFString,
                                          sizeStorage)
        }
    }

    func setFrame(_ frame: NSRect) {
        // Temporarily disable AXEnhancedUserInterface for reliability
        let appElement = AXUIElementCreateApplication(pid)
        var enhancedRef: CFTypeRef?
        var hadEnhancedUI = false

        if AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &enhancedRef) == .success,
           let enhancedRef = enhancedRef,
           let boolVal = enhancedRef as? NSNumber {
            hadEnhancedUI = boolVal.boolValue
            if hadEnhancedUI {
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        // Size → Position → Size (handles cross-display moves)
        setSize(frame.size)
        setTopLeft(frame.origin)
        setSize(frame.size)

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    @discardableResult func pushButton(_ buttonId: CFString) -> Bool {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(_elementRef, buttonId, &buttonRef) == .success,
              let buttonRef = buttonRef else { return false }
        return AXUIElementPerformAction(unsafeBitCast(buttonRef, to: AXUIElement.self), kAXPressAction as CFString) == .success
    }

    func toggleZoom() {
        pushButton(kAXZoomButtonAttribute as CFString)
    }

    func getZoomButtonRect() -> NSRect {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(_elementRef,
                                             kAXZoomButtonAttribute as CFString,
                                             &buttonRef) == .success,
              let buttonRef = buttonRef else { return .zero }
        let button = unsafeBitCast(buttonRef, to: AXUIElement.self)

        var pointRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &pointRef) == .success,
              AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pointRef = pointRef,
              let sizeRef = sizeRef else { return .zero }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(pointRef, to: AXValue.self), .cgPoint, &point)
        AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        return NSMakeRect(point.x, point.y, size.width, size.height)
    }

    func close() -> Bool {
        pushButton(kAXCloseButtonAttribute as CFString)
    }

    func getTabCount() -> Int32 {
        guard let tabs = getWindowTabs(_elementRef) else { return 0 }
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(tabs, kAXTabsAttribute as CFString, &count)
        return Int32(count)
    }

    func focusTab(_ index: Int32) -> Bool {
        guard let tabs = getWindowTabs(_elementRef) else { return false }

        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(tabs, kAXTabsAttribute as CFString, 0, 100, &childrenRef) == .success,
              let children = childrenRef else { return false }

        let count = CFArrayGetCount(children)
        var i: CFIndex = CFIndex(index)
        if i > count || i <= 0 {
            i = count - 1
        } else {
            i = i - 1  // Lua style: indices start at 1
        }

        guard let tabRaw = CFArrayGetValueAtIndex(children, i) else { return false }
        let tab = unsafeBitCast(tabRaw, to: AXUIElement.self)
        return AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
    }

    func isFullscreen() -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(_elementRef, "AXFullScreen" as CFString, &valueRef) == .success,
              let valueRef = valueRef,
              let boolVal = valueRef as? NSNumber else { return false }
        return boolVal.boolValue
    }

    func setFullscreen(_ fullscreen: Bool) {
        AXUIElementSetAttributeValue(_elementRef,
                                     "AXFullScreen" as CFString,
                                     fullscreen ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func isMinimized() -> Bool {
        let val = getWindowProperty(NSAccessibility.Attribute.minimized.rawValue, withDefaultValue: NSNumber(value: false))
        return (val as? NSNumber)?.boolValue ?? false
    }

    func setMinimized(_ minimize: Bool) {
        setWindowProperty(NSAccessibility.Attribute.minimized.rawValue, withValue: NSNumber(value: minimize))
    }

    func getApplication() -> Any? {
        // Not implemented in ObjC source — placeholder
        return nil
    }

    func becomeMain() {
        setWindowProperty(NSAccessibility.Attribute.main.rawValue, withValue: NSNumber(value: true))
    }

    func raise() {
        AXUIElementPerformAction(_elementRef, kAXRaiseAction as CFString)
    }

    func snapshot(_ keepTransparency: Bool) -> NSImage? {
        var wID: CGWindowID = 0
        guard _AXUIElementGetWindow(_elementRef, &wID) == .success else { return nil }
        return HSwindow.snapshot(forID: wID, keepTransparency: keepTransparency)
    }
}
