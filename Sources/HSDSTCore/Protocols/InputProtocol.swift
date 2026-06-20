import Foundation

public struct InputEvent: Sendable {
    public var eventType: UInt32
    public var keyCode: Int64
    public var flags: UInt64
    public var mouseButton: Int32
    public var mousePosition: (x: Double, y: Double)
    public var scrollDelta: (x: Int32, y: Int32)
    public var characters: String?
    public var timestamp: Double

    public init(eventType: UInt32 = 0, keyCode: Int64 = 0, flags: UInt64 = 0,
                mouseButton: Int32 = 0,
                mousePosition: (x: Double, y: Double) = (0, 0),
                scrollDelta: (x: Int32, y: Int32) = (0, 0),
                characters: String? = nil, timestamp: Double = 0) {
        self.eventType = eventType
        self.keyCode = keyCode
        self.flags = flags
        self.mouseButton = mouseButton
        self.mousePosition = mousePosition
        self.scrollDelta = scrollDelta
        self.characters = characters
        self.timestamp = timestamp
    }
}

public struct EventTapInfo: Sendable {
    public var tapID: UInt64
    public var eventsOfInterest: UInt64
    public var location: Int32
    public var isEnabled: Bool

    public init(tapID: UInt64 = 0, eventsOfInterest: UInt64 = 0,
                location: Int32 = 0, isEnabled: Bool = true) {
        self.tapID = tapID
        self.eventsOfInterest = eventsOfInterest
        self.location = location
        self.isEnabled = isEnabled
    }
}

public protocol InputProtocol: AnyObject {
    func createKeyboardEvent(keyCode: Int64, keyDown: Bool, flags: UInt64) -> InputEvent
    func createMouseEvent(eventType: UInt32, position: (x: Double, y: Double), mouseButton: Int32) -> InputEvent
    func createScrollEvent(deltaX: Int32, deltaY: Int32) -> InputEvent
    func postEvent(_ event: InputEvent, tapLocation: Int32) -> Bool
    func createEventTap(location: Int32, placement: Int32, options: Int32,
                        eventsOfInterest: UInt64,
                        callback: @escaping (InputEvent) -> InputEvent?) -> UInt64?
    func enableEventTap(tapID: UInt64, enable: Bool) -> Bool
    func removeEventTap(tapID: UInt64) -> Bool
    func getEventProperty(_ event: InputEvent, property: UInt32) -> Int64?
    func setEventProperty(_ event: inout InputEvent, property: UInt32, value: Int64) -> Bool
    func currentMousePosition() -> (x: Double, y: Double)
    func createEventSource() -> Any?

    /// Register a hotkey so that ``postEvent`` can dispatch keyboard events
    /// matching `keyCode`/`mods` to the provided callback.
    /// Returns false if the key combo is reserved by the system.
    /// Production implementations register with Carbon's RegisterEventHotKey;
    /// simulated implementations record in an in-memory table.
    func registerHotkey(id: UInt32, keyCode: UInt32, mods: UInt32,
                        callback: @escaping (_ hotkeyID: Int32, _ eventKind: Int32) -> Void) -> Bool
    /// Remove a previously registered hotkey.
    /// Production implementations call Carbon's UnregisterEventHotKey;
    /// simulated implementations remove from the in-memory table.
    func unregisterHotkey(id: UInt32)

    /// Post a system event. Production implementations use the opaque
    /// `cgEvent` (cast to CGEvent) to call ``CGEvent.post(tap:)`` or
    /// ``CGEvent.postToPid(_:)``. Simulated implementations build an
    /// InputEvent from the explicit parameters and route through the
    /// event tap / hotkey dispatch pipeline.
    ///
    /// - Parameters:
    ///   - eventType: The CGEventType raw value.
    ///   - keyCode: The keyboard event keycode.
    ///   - flags: The CGEventFlags raw value.
    ///   - mousePosition: The cursor position.
    ///   - timestamp: The event timestamp.
    ///   - cgEvent: The opaque CGEvent (type-erased because HSDSTCore
    ///     cannot import CoreGraphics).
    ///   - applicationPID: If non-nil, post to this PID instead of
    ///     the session event tap.
    func postSystemEvent(eventType: UInt32, keyCode: Int64, flags: UInt64,
                         mousePosition: (x: Double, y: Double), timestamp: Double,
                         cgEvent: Any, applicationPID: Int32?)

    /// Install the global hotkey event dispatcher. Production implementations
    /// install a Carbon event handler via ``InstallEventHandler``.
    /// Simulated implementations do nothing (hotkeys are dispatched via
    /// ``postEvent``).
    ///
    /// - Parameters:
    ///   - callback: The Carbon EventHandlerProcPtr (type-erased).
    ///   - handler: Receives the installed EventHandlerRef (as OpaquePointer).
    func installHotkeyDispatcher(callback: Any, handler: inout OpaquePointer?)
}

// Default implementations so existing conformers don't break.
public extension InputProtocol {
    func createEventSource() -> Any? { nil }
    @discardableResult
    func registerHotkey(id: UInt32, keyCode: UInt32, mods: UInt32,
                        callback: @escaping (_ hotkeyID: Int32, _ eventKind: Int32) -> Void) -> Bool { true }
    func unregisterHotkey(id: UInt32) {}
    func postSystemEvent(eventType: UInt32, keyCode: Int64, flags: UInt64,
                         mousePosition: (x: Double, y: Double), timestamp: Double,
                         cgEvent: Any, applicationPID: Int32?) {}
    func installHotkeyDispatcher(callback: Any, handler: inout OpaquePointer?) {}
}
