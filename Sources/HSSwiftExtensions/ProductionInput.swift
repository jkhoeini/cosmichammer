import AppKit
import CoreGraphics
import Foundation
import HSDSTCore

final class ProductionInput: InputProtocol {
    private var nextTapID: UInt64 = 1
    private var taps: [UInt64: TapState] = [:]

    private class TapState {
        var machPort: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var callback: (InputEvent) -> InputEvent?
        var isEnabled: Bool = true

        init(callback: @escaping (InputEvent) -> InputEvent?) {
            self.callback = callback
        }
    }

    func createKeyboardEvent(keyCode: Int64, keyDown: Bool, flags: UInt64) -> InputEvent {
        var event = InputEvent()
        event.eventType = keyDown
            ? CGEventType.keyDown.rawValue
            : CGEventType.keyUp.rawValue
        event.keyCode = keyCode
        event.flags = flags
        event.timestamp = ProcessInfo.processInfo.systemUptime
        return event
    }

    func createMouseEvent(eventType: UInt32, position: (x: Double, y: Double),
                          mouseButton: Int32) -> InputEvent
    {
        var event = InputEvent()
        event.eventType = eventType
        event.mousePosition = position
        event.mouseButton = mouseButton
        event.timestamp = ProcessInfo.processInfo.systemUptime
        return event
    }

    func createScrollEvent(deltaX: Int32, deltaY: Int32) -> InputEvent {
        var event = InputEvent()
        event.eventType = CGEventType.scrollWheel.rawValue
        event.scrollDelta = (x: deltaX, y: deltaY)
        event.timestamp = ProcessInfo.processInfo.systemUptime
        return event
    }

    func postEvent(_ event: InputEvent, tapLocation: Int32) -> Bool {
        let location = CGEventTapLocation(rawValue: UInt32(tapLocation)) ?? .cghidEventTap
        let cgEvent: CGEvent?

        guard let eventType = CGEventType(rawValue: UInt32(event.eventType)) else { return false }

        switch eventType {
        case .keyDown, .keyUp:
            cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(event.keyCode),
                keyDown: eventType == .keyDown
            )
            cgEvent?.flags = CGEventFlags(rawValue: event.flags)

        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .mouseMoved, .leftMouseDragged,
             .rightMouseDragged:
            let point = CGPoint(x: event.mousePosition.x, y: event.mousePosition.y)
            let button = CGMouseButton(rawValue: UInt32(event.mouseButton)) ?? .left
            cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: eventType,
                mouseCursorPosition: point,
                mouseButton: button
            )
            cgEvent?.flags = CGEventFlags(rawValue: event.flags)

        case .scrollWheel:
            cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: event.scrollDelta.y,
                wheel2: event.scrollDelta.x,
                wheel3: 0
            )

        default:
            return false
        }

        guard let cg = cgEvent else { return false }
        cg.post(tap: location)
        return true
    }

    func createEventTap(location: Int32, placement: Int32, options: Int32,
                        eventsOfInterest: UInt64,
                        callback: @escaping (InputEvent) -> InputEvent?) -> UInt64?
    {
        let id = nextTapID
        nextTapID += 1
        let state = TapState(callback: callback)
        taps[id] = state

        let unmanaged = Unmanaged.passRetained(state)

        let tapCallback: CGEventTapCallBack = { _, type, event, userInfo -> Unmanaged<CGEvent>? in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let tapState = Unmanaged<TapState>.fromOpaque(userInfo).takeUnretainedValue()

            // Re-enable if disabled by timeout
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tapState.machPort {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            var inputEvent = InputEvent()
            inputEvent.eventType = type.rawValue
            inputEvent.keyCode = Int64(event.getIntegerValueField(.keyboardEventKeycode))
            inputEvent.flags = event.flags.rawValue
            inputEvent.mousePosition = (x: Double(event.location.x), y: Double(event.location.y))
            inputEvent.timestamp = Double(event.timestamp)

            if let _ = tapState.callback(inputEvent) {
                return Unmanaged.passUnretained(event)
            }
            return nil  // Callback returned nil = swallow
        }

        let tapLoc = CGEventTapLocation(rawValue: UInt32(location)) ?? .cgSessionEventTap
        let tapPlace = CGEventTapPlacement(rawValue: UInt32(placement)) ?? .headInsertEventTap
        let tapOptions = CGEventTapOptions(rawValue: UInt32(options)) ?? .defaultTap

        guard let machPort = CGEvent.tapCreate(
            tap: tapLoc,
            place: tapPlace,
            options: tapOptions,
            eventsOfInterest: eventsOfInterest,
            callback: tapCallback,
            userInfo: unmanaged.toOpaque()
        ) else {
            unmanaged.release()
            taps.removeValue(forKey: id)
            return nil
        }

        state.machPort = machPort
        let source = CFMachPortCreateRunLoopSource(nil, machPort, 0)
        state.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        return id
    }

    func enableEventTap(tapID: UInt64, enable: Bool) -> Bool {
        guard let state = taps[tapID], let port = state.machPort else { return false }
        CGEvent.tapEnable(tap: port, enable: enable)
        state.isEnabled = enable
        return true
    }

    func removeEventTap(tapID: UInt64) -> Bool {
        guard let state = taps.removeValue(forKey: tapID) else { return false }
        if let source = state.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = state.machPort {
            CFMachPortInvalidate(port)
        }
        return true
    }

    func getEventProperty(_ event: InputEvent, property: UInt32) -> Int64? {
        guard let field = CGEventField(rawValue: property) else { return nil }
        switch field {
        case .keyboardEventKeycode:
            return event.keyCode
        case .mouseEventButtonNumber:
            return Int64(event.mouseButton)
        default:
            return nil
        }
    }

    func setEventProperty(_ event: inout InputEvent, property: UInt32, value: Int64) -> Bool {
        guard let field = CGEventField(rawValue: property) else { return false }
        switch field {
        case .keyboardEventKeycode:
            event.keyCode = value
            return true
        case .mouseEventButtonNumber:
            event.mouseButton = Int32(value)
            return true
        default:
            return false
        }
    }

    func currentMousePosition() -> (x: Double, y: Double) {
        let loc = NSEvent.mouseLocation
        // Convert from AppKit (bottom-left origin) to CG (top-left origin)
        guard let screen = NSScreen.main else { return (x: Double(loc.x), y: Double(loc.y)) }
        let y = screen.frame.maxY - loc.y
        return (x: Double(loc.x), y: Double(y))
    }
}
