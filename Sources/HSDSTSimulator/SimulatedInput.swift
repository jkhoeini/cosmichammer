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

    public func createEventSource() -> Any? { nil }

    public struct SystemHotkeyCombo: Hashable {
        public let keyCode: UInt32
        public let mods: UInt32

        public init(keyCode: UInt32, mods: UInt32) {
            self.keyCode = keyCode
            self.mods = mods
        }
    }

    final class HotkeySystem {
        private struct RegistrationKey: Hashable {
            let ownerID: UInt64
            let hotkeyID: UInt32
        }

        private struct Registration {
            let combo: SystemHotkeyCombo
            let callback: (_ hotkeyID: Int32, _ eventKind: Int32) -> Void
        }

        var reservedHotkeys: Set<SystemHotkeyCombo> = []
        private var nextOwnerID: UInt64 = 1
        private var registrations: [RegistrationKey: Registration] = [:]
        private var registrationKeysByCombo: [SystemHotkeyCombo: RegistrationKey] = [:]

        func makeOwnerID() -> UInt64 {
            defer { nextOwnerID += 1 }
            return nextOwnerID
        }

        func register(
            ownerID: UInt64,
            hotkeyID: UInt32,
            combo: SystemHotkeyCombo,
            callback: @escaping (_ hotkeyID: Int32, _ eventKind: Int32) -> Void
        ) -> Bool {
            let key = RegistrationKey(ownerID: ownerID, hotkeyID: hotkeyID)
            guard registrations[key] == nil,
                  registrationKeysByCombo[combo] == nil,
                  !reservedHotkeys.contains(combo) else { return false }

            registrations[key] = Registration(combo: combo, callback: callback)
            registrationKeysByCombo[combo] = key
            return true
        }

        func unregister(ownerID: UInt64, hotkeyID: UInt32) {
            let key = RegistrationKey(ownerID: ownerID, hotkeyID: hotkeyID)
            guard let registration = registrations.removeValue(forKey: key) else { return }
            registrationKeysByCombo.removeValue(forKey: registration.combo)
        }

        func dispatch(combo: SystemHotkeyCombo, eventKind: Int32) {
            guard let key = registrationKeysByCombo[combo],
                  let registration = registrations[key] else { return }
            registration.callback(Int32(key.hotkeyID), eventKind)
        }
    }

    private let hotkeySystem: HotkeySystem
    private let hotkeyOwnerID: UInt64

    /// Hotkey combinations already owned by simulated system services or other processes.
    public var systemReservedHotkeys: Set<SystemHotkeyCombo> {
        get { hotkeySystem.reservedHotkeys }
        set { hotkeySystem.reservedHotkeys = newValue }
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
        let hotkeySystem = HotkeySystem()
        self.rng = rng
        self.faults = faults
        self.hotkeySystem = hotkeySystem
        self.hotkeyOwnerID = hotkeySystem.makeOwnerID()
    }

    init(rng: RPRNG, faults: FaultConfig, hotkeySystem: HotkeySystem) {
        self.rng = rng
        self.faults = faults
        self.hotkeySystem = hotkeySystem
        self.hotkeyOwnerID = hotkeySystem.makeOwnerID()
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
        hotkeySystem.register(
            ownerID: hotkeyOwnerID,
            hotkeyID: id,
            combo: SystemHotkeyCombo(keyCode: keyCode, mods: mods),
            callback: callback
        )
    }

    public func unregisterHotkey(id: UInt32) {
        hotkeySystem.unregister(ownerID: hotkeyOwnerID, hotkeyID: id)
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

        // Dispatch to the process-wide hotkey registration matching this keyboard event.
        // CGEventType: keyDown = 10, keyUp = 11.
        if event.eventType == 10 || event.eventType == 11 {
            let combo = SystemHotkeyCombo(
                keyCode: UInt32(event.keyCode),
                mods: SimulatedInput.cgFlagsToCarbonMods(event.flags)
            )
            // Carbon: kEventHotKeyPressed = 5, kEventHotKeyReleased = 6.
            let eventKind: Int32 = event.eventType == 10 ? 5 : 6
            hotkeySystem.dispatch(combo: combo, eventKind: eventKind)
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

    // MARK: - System event posting (DST: convert to InputEvent and route)

    public func postSystemEvent(eventType: UInt32, keyCode: Int64, flags: UInt64,
                                mousePosition: (x: Double, y: Double), timestamp: Double,
                                cgEvent: Any, applicationPID: Int32?) {
        let inputEvent = InputEvent(
            eventType: eventType,
            keyCode: keyCode,
            flags: flags,
            mousePosition: mousePosition,
            timestamp: timestamp
        )
        _ = postEvent(inputEvent, tapLocation: 0)
    }

    // MARK: - Hotkey dispatcher (no-op in simulation)

    public func installHotkeyDispatcher(callback: Any, handler: inout OpaquePointer?) {
        // No-op: in DST mode, hotkeys are dispatched via postEvent -> registeredHotkeys.
    }
}
