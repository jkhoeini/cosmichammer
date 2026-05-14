import Foundation
import AppKit
import LuaSkin

// CGWindowListCreateImage is marked obsoleted in macOS 15 SDK but still works at runtime.
// We load it dynamically to bypass the SDK's availability annotation until ScreenCaptureKit migration.
private typealias CGWindowListCreateImageFunc = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?

private let hs_CGWindowListCreateImage: CGWindowListCreateImageFunc? = {
    guard let sym = dlsym(RTLD_DEFAULT, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
}()

// MARK: - HSuielement

@objcMembers
class HSuielement: NSObject {
    private(set) var elementRef: AXUIElement
    var selfRefCount: Int32 = 0

    var isWindow: Bool {
        return isWindow(role: role)
    }

    var isApplication: Bool {
        return role == kAXApplicationRole as String
    }

    var role: String {
        return getElementProperty(NSAccessibilityRoleAttribute, defaultValue: "") as? String ?? ""
    }

    var selectedText: String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXSelectedTextAttribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: Class methods

    class func focusedElement() -> HSuielement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard error == .success, let ref = focusedRef else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return HSuielement(elementRef: ref as! AXUIElement)
    }

    // MARK: Initialiser

    init(elementRef: AXUIElement) {
        self.elementRef = elementRef
        CFRetain(elementRef)
        super.init()
    }

    deinit {
        // No explicit CFRelease needed — Swift manages the AXUIElement retain count via ARC on CFTypeRef
    }

    // MARK: Instance methods

    func newWatcher(callbackRefIndex: Int32, userdataRefIndex: Int32, luaState L: OpaquePointer) -> HSuielementWatcher {
        let skin = LuaSkin.shared(withState: L)!

        let callbackRef = skin.luaRef(LUA_REGISTRYINDEX, atIndex: callbackRefIndex)

        var userDataRef = LUA_REFNIL
        if lua_type(L, userdataRefIndex) != LUA_TNONE {
            userDataRef = skin.luaRef(LUA_REGISTRYINDEX, atIndex: userdataRefIndex)
        }

        let watcher = HSuielementWatcher(element: self, callbackRef: callbackRef, userdataRef: userDataRef)
        watcher.lsCanary = skin.createGCCanary()
        return watcher
    }

    func getElementProperty(_ property: String, defaultValue: Any?) -> Any? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(elementRef, property as CFString, &value) == .success {
            return value
        }
        return defaultValue
    }

    func isWindow(role: String) -> Bool {
        // Most windows have a role of kAXWindowRole, but some apps are weird (e.g. Emacs)
        // so we also do a duck-typing test for an expected window attribute
        return role == (kAXWindowRole as String)
            || getElementProperty(NSAccessibilityMinimizedAttribute, defaultValue: nil) != nil
    }
}

// MARK: - HSuielementWatcher

/// C callback for AXObserver — bridges into the HSuielementWatcher's Lua handler.
private func watcherObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                     _ notificationName: CFString, _ contextData: UnsafeMutableRawPointer?) {
    guard let contextData else { return }
    let watcher = Unmanaged<HSuielementWatcher>.fromOpaque(contextData).takeUnretainedValue()
    let skin = LuaSkin.shared(withState: nil)!
    skin.checkGCCanary(watcher.lsCanary)
    _lua_stackguard_entry(skin.L)

    skin.pushLuaRef(watcher.refTable, ref: watcher.handlerRef) // Callback function

    let elementObj = HSuielement(elementRef: element)
    let pushObj: NSObject
    if elementObj.isWindow {
        pushObj = HSwindow(axUIElementRef: element)
    } else if elementObj.role == (kAXApplicationRole as String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let app = HSapplication(pid: pid, state: skin.L) {
            pushObj = app
        } else {
            pushObj = elementObj
        }
    } else {
        // This isn't a window or an application, so we'll send it as an hs.uielement object
        pushObj = elementObj
    }

    skin.pushNSObject(pushObj)  // Parameter 1: element
    lua_pushstring(skin.L, CFStringGetCStringPtr(notificationName, CFStringBuiltInEncodings.ASCII.rawValue))  // Parameter 2: event
    skin.pushLuaRef(watcher.refTable, ref: watcher.watcherRef)  // Parameter 3: watcher
    if watcher.userDataRef == LUA_NOREF || watcher.userDataRef == LUA_REFNIL {
        lua_pushnil(skin.L)
    } else {
        skin.pushLuaRef(watcher.refTable, ref: watcher.userDataRef)  // Parameter 4: userData
    }

    if !skin.protectedCallAndTraceback(4, nresults: 0) {
        let errorMsg = String(cString: lua_tostring(skin.L, -1))
        skin.logError(errorMsg)
        lua_pop(skin.L, 1)  // remove error message
    }

    _lua_stackguard_exit(skin.L)
}

@objcMembers
class HSuielementWatcher: NSObject {
    var selfRefCount: Int32 = 0
    var elementRef: AXUIElement
    var refTable: LSRefTable = LUA_REGISTRYINDEX
    var handlerRef: Int32
    var userDataRef: Int32
    var watcherRef: Int32 = LUA_NOREF
    var observer: AXObserver?
    var running: Bool = false
    var pid: pid_t = 0
    var watchDestroyed: Bool = false
    var lsCanary: LSGCCanary = 0

    // NOTE THAT THE LUA REF ARGUMENTS MUST BE ON LUA_REGISTRYINDEX AND NOT SOME OTHER REFTABLE
    init(element: HSuielement, callbackRef: Int32, userdataRef: Int32) {
        self.elementRef = element.elementRef
        CFRetain(self.elementRef)
        self.handlerRef = callbackRef
        self.userDataRef = userdataRef
        super.init()
        AXUIElementGetPid(self.elementRef, &self.pid)
    }

    deinit {
        // AXUIElement release handled by ARC
    }

    // MARK: Instance methods

    func start(events: [String], state L: OpaquePointer) {
        let skin = LuaSkin.shared(withState: L)!
        guard !running else { return }

        // Create our observer
        var observerRef: AXObserver?
        let err = AXObserverCreate(pid, { observer, element, notificationName, contextData in
            watcherObserverCallback(observer, element, notificationName, contextData)
        }, &observerRef)
        guard err == .success, let observerRef else {
            skin.logBreadcrumb("AXObserverCreate error: \(err.rawValue)")
            return
        }

        // Add specified events to the observer
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for event in events {
            AXObserverAddNotification(observerRef, elementRef, event as CFString, selfPtr)
        }

        self.observer = observerRef
        self.running = true

        // Begin observing events
        CFRunLoopAddSource(RunLoop.current.getCFRunLoop(),
                           AXObserverGetRunLoopSource(observerRef),
                           .defaultMode)
    }

    func stop() {
        guard running, let observer else { return }

        CFRunLoopRemoveSource(RunLoop.current.getCFRunLoop(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
        self.observer = nil
        self.running = false
    }
}

// MARK: - HSapplication

@objcMembers
class HSapplication: NSObject {
    private(set) var pid: pid_t
    private(set) var elementRef: AXUIElement
    private(set) var runningApp: NSRunningApplication
    private(set) var uiElement: HSuielement
    var selfRefCount: Int32 = 0

    var isHidden: Bool {
        get {
            var _isHidden: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(elementRef,
                                                       NSAccessibilityHiddenAttribute as CFString,
                                                       &_isHidden)
            if result == .success, let val = _isHidden as? NSNumber {
                return val.boolValue
            }
            return false
        }
        set {
            AXUIElementSetAttributeValue(elementRef,
                                         NSAccessibilityHiddenAttribute as CFString,
                                         newValue ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    // MARK: Class methods

    class func frontmostApplication(state L: OpaquePointer) -> HSapplication? {
        let skin = LuaSkin.shared(withState: L)!
        guard let runningApp = NSWorkspace.shared.frontmostApplication else {
            skin.logError("Unable to fetch frontmost application")
            return nil
        }
        guard let app = HSapplication.application(for: runningApp, state: L) else {
            skin.logError("HSapplication::frontmostApplication failed for app: \(runningApp.localizedName ?? "unknown")")
            return nil
        }
        return app
    }

    class func application(for app: NSRunningApplication, state L: OpaquePointer) -> HSapplication? {
        return HSapplication(nsRunningApplication: app, state: L)
    }

    class func application(forPID pid: pid_t, state L: OpaquePointer) -> HSapplication? {
        return HSapplication(pid: pid, state: L)
    }

    class func name(forBundleID bundleID: String) -> String? {
        guard let path = self.path(forBundleID: bundleID), let app = Bundle(path: path) else { return nil }
        return app.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
    }

    class func path(forBundleID bundleID: String) -> String? {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    class func info(forBundleID bundleID: String) -> [String: Any]? {
        guard let appPath = path(forBundleID: bundleID) else { return nil }
        return info(forBundlePath: appPath)
    }

    class func info(forBundlePath bundlePath: String) -> [String: Any]? {
        return Bundle(path: bundlePath)?.infoDictionary
    }

    class func preferredLocalizations(forBundleID bundleID: String) -> [String]? {
        guard let appPath = path(forBundleID: bundleID) else { return nil }
        return preferredLocalizations(forBundlePath: appPath)
    }

    class func preferredLocalizations(forBundlePath bundlePath: String) -> [String]? {
        return Bundle(path: bundlePath)?.preferredLocalizations
    }

    class func localizations(forBundleID bundleID: String) -> [String]? {
        guard let appPath = path(forBundleID: bundleID) else { return nil }
        return localizations(forBundlePath: appPath)
    }

    class func localizations(forBundlePath bundlePath: String) -> [String]? {
        return Bundle(path: bundlePath)?.localizations
    }

    class func runningApplications(state L: OpaquePointer) -> [HSapplication] {
        return NSWorkspace.shared.runningApplications.compactMap {
            HSapplication.application(for: $0, state: L)
        }
    }

    class func applications(forBundleID bundleID: String, state L: OpaquePointer) -> [HSapplication] {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap {
            HSapplication.application(for: $0, state: L)
        }
    }

    @discardableResult
    class func launch(byName name: String) -> Bool {
        return NSWorkspace.shared.launchApplication(name)
    }

    @discardableResult
    class func launch(byBundleID bundleID: String) -> Bool {
        return NSWorkspace.shared.launchApplication(
            withBundleIdentifier: bundleID,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifier: nil
        )
    }

    // MARK: Initialisers

    init?(pid: pid_t, state L: OpaquePointer) {
        let skin = LuaSkin.shared(withState: L)!

        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            skin.logError("Unable to fetch NSRunningApplication for pid: \(pid)")
            return nil
        }

        guard let result = HSapplication.makeFields(for: runningApp, skin: skin) else {
            return nil
        }
        self.pid = result.pid
        self.elementRef = result.elementRef
        self.runningApp = runningApp
        self.uiElement = result.uiElement
        super.init()
    }

    init?(nsRunningApplication app: NSRunningApplication, state L: OpaquePointer) {
        let skin = LuaSkin.shared(withState: L)!

        guard let result = HSapplication.makeFields(for: app, skin: skin) else {
            return nil
        }
        self.pid = result.pid
        self.elementRef = result.elementRef
        self.runningApp = app
        self.uiElement = result.uiElement
        super.init()
    }

    /// Shared initialisation logic — creates the AXUIElementRef and uiElement, or returns nil on failure.
    private static func makeFields(for app: NSRunningApplication, skin: LuaSkin)
        -> (pid: pid_t, elementRef: AXUIElement, uiElement: HSuielement)? {

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        // AXUIElementCreateApplication always returns non-nil, but guard for safety
        let pid = app.processIdentifier
        let uiElement = HSuielement(elementRef: appRef)
        return (pid, appRef, uiElement)
    }

    deinit {
        // AXUIElement release handled by ARC
    }

    // MARK: Instance methods

    func allWindows() -> [HSwindow] {
        var windows: CFArray?
        let result = AXUIElementCopyAttributeValues(elementRef, kAXWindowsAttribute, 0, 100, &windows)
        guard result == .success, let windowArray = windows else { return [] }

        let count = CFArrayGetCount(windowArray)
        var allWindows: [HSwindow] = []
        allWindows.reserveCapacity(count)
        for i in 0..<count {
            let win = CFArrayGetValueAtIndex(windowArray, i)!
            let axElement = Unmanaged<AXUIElement>.fromOpaque(win).takeUnretainedValue()
            allWindows.append(HSwindow(axUIElementRef: axElement))
        }
        return allWindows
    }

    func mainWindow() -> HSwindow? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXMainWindowAttribute, &window) == .success,
              let win = window else { return nil }
        // swiftlint:disable:next force_cast
        return HSwindow(axUIElementRef: win as! AXUIElement)
    }

    func focusedWindow() -> HSwindow? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXFocusedWindowAttribute, &window) == .success,
              let win = window else { return nil }
        // swiftlint:disable:next force_cast
        return HSwindow(axUIElementRef: win as! AXUIElement)
    }

    @discardableResult
    func activate(allWindows: Bool) -> Bool {
        var options: NSApplication.ActivationOptions = []
        if allWindows {
            options.insert(.activateAllWindows)
        }
        return runningApp.activate(options: options)
    }

    var isResponsive: Bool {
        // Private API declarations
        typealias CGSConnectionID = Int32
        typealias CGSMainConnectionIDFunc = @convention(c) () -> CGSConnectionID
        typealias CGSEventIsAppUnresponsiveFunc = @convention(c) (CGSConnectionID, UnsafePointer<ProcessSerialNumber>) -> Bool

        guard let mainConnSym = dlsym(RTLD_DEFAULT, "CGSMainConnectionID"),
              let unrespSym = dlsym(RTLD_DEFAULT, "CGSEventIsAppUnresponsive") else {
            return true
        }

        let CGSMainConnectionID = unsafeBitCast(mainConnSym, to: CGSMainConnectionIDFunc.self)
        let CGSEventIsAppUnresponsive = unsafeBitCast(unrespSym, to: CGSEventIsAppUnresponsiveFunc.self)

        var psn = ProcessSerialNumber()
        GetProcessForPID(pid, &psn)

        let conn = CGSMainConnectionID()
        return !CGSEventIsAppUnresponsive(conn, &psn)
    }

    func isRunning(state L: OpaquePointer) -> Bool {
        // FIXME: Figure out why we can't use NSRunningApplication.terminated here - it always seems to say NO
        let test = HSapplication.application(forPID: runningApp.processIdentifier, state: L)
        return test != nil
    }

    @discardableResult
    func setFrontmost(allWindows: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        var options: NSApplication.ActivationOptions = []
        if allWindows {
            options.insert(.activateAllWindows)
        }
        return app.activate(options: options)
    }

    var isFrontmost: Bool {
        var _isFrontmost: CFTypeRef?
        if AXUIElementCopyAttributeValue(elementRef,
                                         NSAccessibilityFrontmostAttribute as CFString,
                                         &_isFrontmost) == .success,
           let val = _isFrontmost as? NSNumber {
            return val.boolValue
        }
        return false
    }

    var title: String? {
        return runningApp.localizedName
    }

    var bundleID: String? {
        return runningApp.bundleIdentifier
    }

    var path: String? {
        guard let url = runningApp.bundleURL else { return nil }
        return Bundle(url: url)?.bundlePath
    }

    func kill() {
        runningApp.terminate()
    }

    func kill9() {
        runningApp.forceTerminate()
    }

    var kind: Int32 {
        switch runningApp.activationPolicy {
        case .accessory: return 0
        case .prohibited: return -1
        default: return 1
        }
    }
}

// MARK: - HSwindow helpers

/// Returns a lazily-initialized system-wide AXUIElement.
private let systemWideElement: AXUIElement = AXUIElementCreateSystemWide()

/// Returns the tab-group element for a window, searching for AXTabGroup first, then falling back
/// to an AXGroup that has an AXTabs attribute (Safari 14+).
private func getWindowTabs(_ win: AXUIElement) -> AXUIElement? {
    var children: CFArray?
    guard AXUIElementCopyAttributeValues(win, kAXChildrenAttribute, 0, 100, &children) == AXError.success,
          let childArray = children else {
        return nil
    }

    let count = CFArrayGetCount(childArray)

    // First pass: look for AXTabGroup
    for i in 0..<count {
        let child = Unmanaged<AXUIElement>.fromOpaque(CFArrayGetValueAtIndex(childArray, i)!).takeUnretainedValue()
        var typeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute, &typeRef) == AXError.success,
              let role = typeRef as? String else { continue }
        if role == (kAXTabGroupRole as String) {
            CFRetain(child)
            return child
        }
    }

    // Second pass: Safari 14 puts tabs into an AXGroup, not an AXTabGroup
    for i in 0..<count {
        let child = Unmanaged<AXUIElement>.fromOpaque(CFArrayGetValueAtIndex(childArray, i)!).takeUnretainedValue()
        var typeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute, &typeRef) == AXError.success,
              let role = typeRef as? String else { continue }
        if role == (kAXGroupRole as String) {
            var attributeNames: CFArray?
            guard AXUIElementCopyAttributeNames(child, &attributeNames) == AXError.success,
                  let names = attributeNames else { continue }
            if CFArrayContainsValue(names, CFRangeMake(0, CFArrayGetCount(names)), kAXTabsAttribute) {
                CFRetain(child)
                return child
            }
        }
    }

    return nil
}

// MARK: - HSwindow

@objcMembers
class HSwindow: NSObject {
    private(set) var pid: pid_t = 0
    private(set) var elementRef: AXUIElement
    private(set) var winID: CGWindowID = 0
    private(set) var uiElement: HSuielement
    var selfRefCount: Int32 = 0

    var title: String {
        return getWindowProperty(NSAccessibilityTitleAttribute, defaultValue: "") as? String ?? ""
    }

    var role: String {
        return getWindowProperty(NSAccessibilityRoleAttribute, defaultValue: "") as? String ?? ""
    }

    var subRole: String {
        return getWindowProperty(NSAccessibilitySubroleAttribute, defaultValue: "") as? String ?? ""
    }

    var isStandard: Bool {
        return subRole == (kAXStandardWindowSubrole as String)
    }

    var topLeft: NSPoint {
        get {
            var point = CGPoint.zero
            var positionStorage: CFTypeRef?
            if AXUIElementCopyAttributeValue(elementRef,
                                             NSAccessibilityPositionAttribute as CFString,
                                             &positionStorage) == .success,
               let storage = positionStorage {
                // swiftlint:disable:next force_cast
                if !AXValueGetValue(storage as! AXValue, .cgPoint, &point) {
                    point = .zero
                }
            }
            return NSPoint(x: point.x, y: point.y)
        }
        set {
            var point = newValue
            guard let positionStorage = AXValueCreate(.cgPoint, &point) else { return }
            AXUIElementSetAttributeValue(elementRef,
                                         NSAccessibilityPositionAttribute as CFString,
                                         positionStorage)
        }
    }

    var size: NSSize {
        get {
            var sz = CGSize.zero
            var sizeStorage: CFTypeRef?
            if AXUIElementCopyAttributeValue(elementRef,
                                             NSAccessibilitySizeAttribute as CFString,
                                             &sizeStorage) == .success,
               let storage = sizeStorage {
                // swiftlint:disable:next force_cast
                if !AXValueGetValue(storage as! AXValue, .cgSize, &sz) {
                    sz = .zero
                }
            }
            return NSSize(width: sz.width, height: sz.height)
        }
        set {
            var sz = newValue
            guard let sizeStorage = AXValueCreate(.cgSize, &sz) else { return }
            AXUIElementSetAttributeValue(elementRef,
                                         NSAccessibilitySizeAttribute as CFString,
                                         sizeStorage)
        }
    }

    var fullscreen: Bool {
        get {
            var _fullscreen: CFTypeRef?
            if AXUIElementCopyAttributeValue(elementRef,
                                             "AXFullScreen" as CFString,
                                             &_fullscreen) == AXError.success,
               let val = _fullscreen {
                // swiftlint:disable:next force_cast
                return CFBooleanGetValue(val as! CFBoolean)
            }
            return false
        }
        set {
            AXUIElementSetAttributeValue(elementRef,
                                         "AXFullScreen" as CFString,
                                         newValue ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    var minimized: Bool {
        get {
            guard let val = getWindowProperty(NSAccessibilityMinimizedAttribute, defaultValue: NSNumber(value: false)) as? NSNumber else {
                return false
            }
            return val.boolValue
        }
        set {
            setWindowProperty(NSAccessibilityMinimizedAttribute, value: NSNumber(value: newValue))
        }
    }

    var application: Any? {
        return getApplication()
    }

    var zoomButtonRect: NSRect {
        return getZoomButtonRect()
    }

    var tabCount: Int32 {
        return getTabCount()
    }

    // MARK: Class methods

    class func orderedWindowIDs() -> [NSNumber] {
        guard let wins = CGWindowListCreate([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else {
            LuaSkin.logBreadcrumb("hs.window._orderedwinids CGWindowListCreate returned NULL")
            return []
        }
        guard let windowDescs = CGWindowListCreateDescriptionFromArray(wins) as? [[CFString: Any]] else {
            return []
        }
        var windowIDs: [NSNumber] = []
        windowIDs.reserveCapacity(CFArrayGetCount(wins))
        for desc in windowDescs {
            if let winID = desc[kCGWindowNumber] as? NSNumber {
                windowIDs.append(winID)
            }
        }
        return windowIDs
    }

    class func snapshot(forID windowID: CGWindowID, keepTransparency: Bool) -> NSImage? {
        let makeOpaque: CGWindowImageOption = keepTransparency ? [] : .shouldBeOpaque
        let windowRect = CGRect.null
        guard let createImage = hs_CGWindowListCreateImage,
              let windowImage = createImage(windowRect, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, makeOpaque]) else {
            return nil
        }
        return NSImage(cgImage: windowImage, size: windowRect.size)
    }

    class func focusedWindow() -> HSwindow? {
        var app: CFTypeRef?
        AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute, &app)
        guard let appRef = app else { return nil }

        var win: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            // swiftlint:disable:next force_cast
            appRef as! AXUIElement,
            NSAccessibilityFocusedWindowAttribute as CFString,
            &win
        )
        guard result == .success, let winRef = win else { return nil }
        // swiftlint:disable:next force_cast
        return HSwindow(axUIElementRef: winRef as! AXUIElement)
    }

    // MARK: Initialiser

    init(axUIElementRef winRef: AXUIElement) {
        CFRetain(winRef)
        self.elementRef = winRef

        var pid: pid_t = 0
        if AXUIElementGetPid(winRef, &pid) == .success {
            self.pid = pid
        }

        var wID: CGWindowID = 0
        if _AXUIElementGetWindow(winRef, &wID) == AXError.success {
            self.winID = wID
        }

        self.uiElement = HSuielement(elementRef: winRef)
        super.init()
    }

    deinit {
        // AXUIElement release handled by ARC
    }

    // MARK: Instance methods

    private func getWindowProperty(_ property: String, defaultValue: Any?) -> Any? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(elementRef, property as CFString, &value) == .success {
            return value
        }
        return defaultValue
    }

    @discardableResult
    private func setWindowProperty(_ property: String, value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return AXUIElementSetAttributeValue(elementRef, property as CFString, number) == .success
    }

    func setFrame(_ frame: NSRect) {
        // Disable Enhanced UI during operation for better reliability
        let appElement = AXUIElementCreateApplication(pid)
        var hadEnhancedUI = false

        var enhancedUI: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &enhancedUI) == .success,
           let val = enhancedUI {
            // swiftlint:disable:next force_cast
            hadEnhancedUI = CFBooleanGetValue(val as! CFBoolean)
            if hadEnhancedUI {
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        // Step 1: Set size first (prepares for potential cross-display move)
        self.size = frame.size
        // Step 2: Set position (may move window to different display)
        self.topLeft = frame.origin
        // Step 3: Set size again (ensures correct size on target display)
        self.size = frame.size

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    @discardableResult
    func pushButton(_ buttonId: CFString) -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, buttonId, &button) == AXError.success,
              let btn = button else { return false }
        // swiftlint:disable:next force_cast
        return AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction) == AXError.success
    }

    func toggleZoom() {
        pushButton(kAXZoomButtonAttribute)
    }

    func getZoomButtonRect() -> NSRect {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elementRef, kAXZoomButtonAttribute, &button) == AXError.success,
              let btn = button else { return .zero }

        // swiftlint:disable:next force_cast
        let btnElement = btn as! AXUIElement
        var pointRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(btnElement, kAXPositionAttribute, &pointRef) == AXError.success,
              AXUIElementCopyAttributeValue(btnElement, kAXSizeAttribute, &sizeRef) == AXError.success,
              let pRef = pointRef, let sRef = sizeRef else { return .zero }

        var point = CGPoint.zero
        var sz = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(pRef as! AXValue, .cgPoint, &point),
              // swiftlint:disable:next force_cast
              AXValueGetValue(sRef as! AXValue, .cgSize, &sz) else { return .zero }

        return NSRect(x: point.x, y: point.y, width: sz.width, height: sz.height)
    }

    @discardableResult
    func close() -> Bool {
        return pushButton(kAXCloseButtonAttribute)
    }

    func getTabCount() -> Int32 {
        guard let tabs = getWindowTabs(elementRef) else { return 0 }
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(tabs, kAXTabsAttribute, &count)
        CFRelease(tabs)
        return Int32(count)
    }

    @discardableResult
    func focusTab(_ index: Int32) -> Bool {
        guard let tabs = getWindowTabs(elementRef) else { return false }
        defer { CFRelease(tabs) }

        var children: CFArray?
        guard AXUIElementCopyAttributeValues(tabs, kAXTabsAttribute, 0, 100, &children) == AXError.success,
              let childArray = children else { return false }

        let count = CFArrayGetCount(childArray)
        let i: CFIndex
        if index > count || index <= 0 {
            i = count - 1
        } else {
            i = CFIndex(index) - 1  // adjust because Lua style indexes start at 1
        }

        let tab = Unmanaged<AXUIElement>.fromOpaque(CFArrayGetValueAtIndex(childArray, i)!).takeUnretainedValue()
        return AXUIElementPerformAction(tab, kAXPressAction) == AXError.success
    }

    func getApplication() -> HSapplication? {
        // This is a placeholder — the ObjC version returned `id`.
        // Callers typically use this to get the HSapplication for the window's PID.
        return nil
    }

    func becomeMain() {
        setWindowProperty(NSAccessibilityMainAttribute, value: NSNumber(value: true))
    }

    func raiseWindow() {
        AXUIElementPerformAction(elementRef, kAXRaiseAction)
    }

    func snapshot(keepTransparency: Bool) -> NSImage? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(elementRef, &windowID) == .success else { return nil }
        return HSwindow.snapshot(forID: windowID, keepTransparency: keepTransparency)
    }
}
