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

    // MARK: - Hotkey simulation

    public var isSimulated: Bool { true }

    private struct HotkeyEntry {
        let keyCode: UInt32
        let mods: UInt32 // Carbon modifier flags
        let callback: (_ hotkeyID: Int32, _ eventKind: Int32) -> Void
    }
    private var registeredHotkeys: [UInt32: HotkeyEntry] = [:]

    /// Key combos reserved by the system (keyCode, carbonMods).
    /// Mirrors the most common macOS Mission Control / Spaces shortcuts
    /// that RegisterEventHotKey would reject with eventHotKeyExistsErr.
    public var systemReservedHotkeys: Set<SystemHotkeyCombo> = {
        // Carbon modifier constants: controlKey = 4096
        let ctrl: UInt32 = 4096
        // Virtual keycodes: Up = 126, Down = 125, Left = 123, Right = 124
        return [
            SystemHotkeyCombo(keyCode: 126, mods: ctrl),  // Ctrl+Up (Mission Control)
            SystemHotkeyCombo(keyCode: 125, mods: ctrl),  // Ctrl+Down (App Exposé)
            SystemHotkeyCombo(keyCode: 123, mods: ctrl),  // Ctrl+Left (Space left)
            SystemHotkeyCombo(keyCode: 124, mods: ctrl),  // Ctrl+Right (Space right)
        ]
    }()

    public struct SystemHotkeyCombo: Hashable {
        public let keyCode: UInt32
        public let mods: UInt32
        public init(keyCode: UInt32, mods: UInt32) {
            self.keyCode = keyCode
            self.mods = mods
        }
    }

    /// Convert CGEvent modifier flags to Carbon modifier flags.
    private static func cgFlagsToCarbonMods(_ cgFlags: UInt64) -> UInt32 {
        // CGEventFlags: maskCommand=0x100000, maskControl=0x40000,
        //               maskAlternate=0x80000, maskShift=0x20000
        // Carbon: cmdKey=256, controlKey=4096, optionKey=2048, shiftKey=512
        var mods: UInt32 = 0
        if cgFlags & 0x100000 != 0 { mods |= 256 }   // cmdKey
        if cgFlags & 0x40000  != 0 { mods |= 4096 }  // controlKey
        if cgFlags & 0x80000  != 0 { mods |= 2048 }  // optionKey
        if cgFlags & 0x20000  != 0 { mods |= 512 }   // shiftKey
        return mods
    }

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

    @discardableResult
    public func registerHotkey(id: UInt32, keyCode: UInt32, mods: UInt32,
                               callback: @escaping (_ hotkeyID: Int32, _ eventKind: Int32) -> Void) -> Bool {
        // Reject combos reserved by the system (same as Carbon's eventHotKeyExistsErr).
        if systemReservedHotkeys.contains(SystemHotkeyCombo(keyCode: keyCode, mods: mods)) {
            return false
        }
        registeredHotkeys[id] = HotkeyEntry(keyCode: keyCode, mods: mods, callback: callback)
        return true
    }

    public func unregisterHotkey(id: UInt32) {
        registeredHotkeys.removeValue(forKey: id)
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

        // Dispatch to registered hotkeys for keyboard events.
        // CGEventType: keyDown = 10, keyUp = 11
        if event.eventType == 10 || event.eventType == 11 {
            let carbonMods = SimulatedInput.cgFlagsToCarbonMods(event.flags)
            // Carbon: kEventHotKeyPressed = 5, kEventHotKeyReleased = 6
            let eventKind: Int32 = (event.eventType == 10) ? 5 : 6
            for (id, entry) in registeredHotkeys {
                if entry.keyCode == UInt32(event.keyCode) && entry.mods == carbonMods {
                    entry.callback(Int32(id), eventKind)
                }
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
