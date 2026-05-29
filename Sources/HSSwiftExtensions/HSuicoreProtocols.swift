import Cocoa
import ApplicationServices
import CLua

// @objc protocols mirroring HSuicore.h types from the HSExtensions ObjC target.
// Swift files in HSSwiftExtensions cannot import ObjC types directly; instead they
// cast instances obtained via NSClassFromString / luaObject(at:toClass:) through
// these protocols.  The ObjC runtime matches selectors, so method names must
// exactly match the ObjC class interfaces.

// MARK: - HSuielement

@objc protocol HSuielementProtocol: NSObjectProtocol {
    var elementRef: AXUIElement { get }
    var selfRefCount: Int32 { get set }
    var isWindow: Bool { get }
    var isApplication: Bool { get }
    var role: String { get }
    var selectedText: String { get }

    @objc(focusedElement) static func focusedElement() -> NSObject?
    @objc(initWithElementRef:) func initWithElementRef(_ ref: AXUIElement) -> NSObject?
    func newWatcher(atIndex callbackRefIndex: Int32, withUserdataAtIndex userDataRefIndex: Int32, withLuaState L: UnsafeMutablePointer<lua_State>!) -> NSObject?
    func getElementProperty(_ property: String, withDefaultValue defaultValue: Any?) -> Any?
}

// MARK: - HSuielementWatcher

@objc protocol HSuielementWatcherProtocol: NSObjectProtocol {
    var selfRefCount: Int32 { get set }
    var elementRef: AXUIElement { get set }
    var refTable: Int32 { get set }
    var handlerRef: Int32 { get set }
    var userDataRef: Int32 { get set }
    var watcherRef: Int32 { get set }
    var observer: AXObserver { get set }
    var running: Bool { get set }
    var pid: pid_t { get set }
    var watchDestroyed: Bool { get set }
    var lsCanary: UInt64 { get set }

    func start(_ events: [String], withState L: UnsafeMutablePointer<lua_State>!)
    func stop()
}

// MARK: - HSapplication

@objc protocol HSapplicationProtocol: NSObjectProtocol {
    var pid: pid_t { get }
    var elementRef: AXUIElement { get }
    var runningApp: NSRunningApplication { get }
    var uiElement: NSObject { get }
    var selfRefCount: Int32 { get set }
    var hidden: Bool { get set }

    func allWindows() -> [Any]?
    func mainWindow() -> Any?
    func focusedWindow() -> Any?
    func activate(_ allWindows: Bool) -> Bool
    func isResponsive() -> Bool
    func isRunning(withState L: UnsafeMutablePointer<lua_State>!) -> Bool
    func setFrontmost(_ allWindows: Bool) -> Bool
    func isFrontmost() -> Bool
    func title() -> String?
    func bundleID() -> String?
    func path() -> String?
    func kill()
    func kill9()
    func kind() -> Int32
}

// MARK: - HSwindow

@objc protocol HSwindowProtocol: NSObjectProtocol {
    var pid: pid_t { get }
    var elementRef: AXUIElement { get }
    var winID: CGWindowID { get }
    var selfRefCount: Int32 { get set }

    func title() -> String?
    func role() -> String?
    func subRole() -> String?
    func isStandard() -> Bool
    func getTopLeft() -> NSPoint
    func setTopLeft(_ topLeft: NSPoint)
    func getSize() -> NSSize
    func setSize(_ size: NSSize)
    func setFrame(_ frame: NSRect)
    func pushButton(_ buttonId: CFString) -> Bool
    func toggleZoom()
    func getZoomButtonRect() -> NSRect
    func close() -> Bool
    func focusTab(_ index: Int32) -> Bool
    func getTabCount() -> Int32
    func isFullscreen() -> Bool
    func setFullscreen(_ fullscreen: Bool)
    func isMinimized() -> Bool
    func setMinimized(_ minimize: Bool)
    func getApplication() -> Any?
    func becomeMain()
    func raise()
    func snapshot(_ keepTransparency: Bool) -> NSImage?
}

// MARK: - Runtime helpers

enum HSuicore {
    static var uielementClass: NSObject.Type? { NSClassFromString("HSuielement") as? NSObject.Type }
    static var uielementWatcherClass: NSObject.Type? { NSClassFromString("HSuielementWatcher") as? NSObject.Type }
    static var applicationClass: NSObject.Type? { NSClassFromString("HSapplication") as? NSObject.Type }
    static var windowClass: NSObject.Type? { NSClassFromString("HSwindow") as? NSObject.Type }
}
