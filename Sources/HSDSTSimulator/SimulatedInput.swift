import Foundation
import HSDSTCore

public final class SimulatedInput: InputProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var postedEvents: [InputEvent] = []
    public var eventTaps: [UInt64: EventTapInfo] = [:]
    public var mousePosition: (x: Double, y: Double) = (0, 0)

    private var nextTapID: UInt64 = 1
    private var tapCallbacks: [UInt64: (InputEvent) -> InputEvent?] = [:]

    /// Simulated event properties keyed by (eventType, property).
    private var eventProperties: [UInt64: Int64] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func createKeyboardEvent(keyCode: Int64, keyDown: Bool, flags: UInt64) -> InputEvent {
        // CGEventType: keyDown = 10, keyUp = 11
        let eventType: UInt32 = keyDown ? 10 : 11
        return InputEvent(
            eventType: eventType,
            keyCode: keyCode,
            flags: flags,
            timestamp: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        )
    }

    public func createMouseEvent(eventType: UInt32, position: (x: Double, y: Double), mouseButton: Int32) -> InputEvent {
        InputEvent(
            eventType: eventType,
            mouseButton: mouseButton,
            mousePosition: position,
            timestamp: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        )
    }

    public func createScrollEvent(deltaX: Int32, deltaY: Int32) -> InputEvent {
        // CGEventType: scrollWheel = 22
        InputEvent(
            eventType: 22,
            scrollDelta: (x: deltaX, y: deltaY),
            timestamp: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        )
    }

    public func postEvent(_ event: InputEvent, tapLocation: Int32) -> Bool {
        if faults.accessibilityPermissionDenied { return false }

        postedEvents.append(event)

        // Update mouse position when posting mouse-move or mouse-drag events
        let mouseMoveTypes: Set<UInt32> = [5, 6, 7, 27]  // mouseMoved, leftDragged, rightDragged, otherDragged
        if mouseMoveTypes.contains(event.eventType) {
            mousePosition = event.mousePosition
        }

        // Route through active event taps
        for (tapID, info) in eventTaps where info.isEnabled {
            let mask: UInt64 = 1 << UInt64(event.eventType)
            if info.eventsOfInterest & mask != 0, let callback = tapCallbacks[tapID] {
                _ = callback(event)
            }
        }

        return true
    }

    public func createEventTap(location: Int32, placement: Int32, options: Int32,
                                eventsOfInterest: UInt64,
                                callback: @escaping (InputEvent) -> InputEvent?) -> UInt64? {
        if faults.accessibilityPermissionDenied { return nil }

        let tapID = nextTapID
        nextTapID += 1

        eventTaps[tapID] = EventTapInfo(
            tapID: tapID,
            eventsOfInterest: eventsOfInterest,
            location: location,
            isEnabled: true
        )
        tapCallbacks[tapID] = callback

        return tapID
    }

    public func enableEventTap(tapID: UInt64, enable: Bool) -> Bool {
        guard var info = eventTaps[tapID] else { return false }
        info.isEnabled = enable
        eventTaps[tapID] = info
        return true
    }

    public func removeEventTap(tapID: UInt64) -> Bool {
        guard eventTaps.removeValue(forKey: tapID) != nil else { return false }
        tapCallbacks.removeValue(forKey: tapID)
        return true
    }

    public func getEventProperty(_ event: InputEvent, property: UInt32) -> Int64? {
        // Return well-known properties from the event struct itself
        switch property {
        case 9:  // keyboardEventKeycode
            return event.keyCode
        case 1:  // mouseEventNumber — return 0 as simulated default
            return 0
        default:
            let key = UInt64(event.eventType) << 32 | UInt64(property)
            return eventProperties[key]
        }
    }

    public func setEventProperty(_ event: inout InputEvent, property: UInt32, value: Int64) -> Bool {
        switch property {
        case 9:  // keyboardEventKeycode
            event.keyCode = value
        default:
            let key = UInt64(event.eventType) << 32 | UInt64(property)
            eventProperties[key] = value
        }
        return true
    }

    public func currentMousePosition() -> (x: Double, y: Double) {
        mousePosition
    }
}
