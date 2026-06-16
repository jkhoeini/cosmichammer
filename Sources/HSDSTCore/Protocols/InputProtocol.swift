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
}
