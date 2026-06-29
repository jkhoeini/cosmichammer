import Cocoa
import CLua
import Lua
import Carbon
import os.log

private let USERDATA_TAG = "hs.eventtap"

/// Maximum number of characters that ``eventtap_keyStrokes`` will
/// synthesise in a single call.  Longer strings are truncated and an
/// error is logged.
private let kMaxKeystrokeSynthesisLength = 10_000

// Shared with libeventtap_event_new.swift (same module)
let EVENTTAP_EVENT_USERDATA_TAG = "hs.eventtap.event"

func newEventtapEvent(_ L: UnsafeMutablePointer<lua_State>!, _ event: CGEvent) {
    let ud = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    ud.pointee = Unmanaged.passRetained(event).toOpaque()
    luaL_getmetatable(L, EVENTTAP_EVENT_USERDATA_TAG)
    lua_setmetatable(L, -2)
}

func getEventtapEvent(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> CGEvent? {
    guard let ud = luaL_checkudata(L, idx, EVENTTAP_EVENT_USERDATA_TAG) else { return nil }
    let ptr = ud.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<CGEvent>.fromOpaque(rawPtr).takeUnretainedValue()
}

// MARK: - HSEventtap class

private class HSEventtap {
    var fn: LuaValue?
    var mask: CGEventMask = 0
    var tap: CFMachPort?
    var runloopsrc: CFRunLoopSource?
    var lsCanary: UInt64 = UInt64()
    private var tornDown = false

    /// Idempotent teardown: stop the event tap, drop the Lua callback reference.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopTap()
        fn = nil    // drops the LuaValue ref while L is still open
    }

    func stopTap() {
        if let tap = tap {
            if CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: false) }
            CFMachPortInvalidate(tap)
            if let src = runloopsrc {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            self.tap = nil
            runloopsrc = nil
        }
    }
}

// MARK: - CGEventTap Callback

private let eventtapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let e = Unmanaged<HSEventtap>.fromOpaque(userInfo).takeUnretainedValue()

    let L = lua_getCurrentState()!

    if !lua_isStateGenerationValid(e.lsCanary) {
        e.teardown()
        return Unmanaged.passUnretained(event)
    }

    guard let cb = e.fn else {
        os_log(.debug, "%{public}s", "eventtap_callback called with nil callback")
        return Unmanaged.passUnretained(event)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        os_log(.debug, "%{public}s", "eventtap restarted: (\(type.rawValue))")
        if let tap = e.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    cb.push(onto: L)
    newEventtapEvent(L, event)

    if luaTelemetryPCall(
        L,
        nargs: 1,
        nresults: 2,
        callbackName: "hs.eventtap",
        attributes: ["eventtap.event_type": type.rawValue]
    ) != LUA_OK {
        let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
        os_log(.error, "%{public}s", "hs.eventtap callback error: \(errorMsg)")
        lua_pop(L, 1)
        return nil
    }

    let ignoreEvent = lua_toboolean(L, -2) != 0

    if lua_istable(L, -1) {
        lua_pushnil(L)
        while lua_next(L, -2) != 0 {
            if lua_type(L, -1) == LUA_TUSERDATA && luaL_testudata(L, -1, EVENTTAP_EVENT_USERDATA_TAG) != nil {
                if let newEvent = getEventtapEvent(L, at: -1) {
                    newEvent.tapPostEvent(proxy)
                }
            }
            lua_pop(L, 1)
        }
    }

    lua_pop(L, 2)

    if ignoreEvent {
        return nil
    } else {
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Module Functions

/// hs.eventtap.keyStrokes(text[, application])
/// Function
/// Generates and emits keystroke events for the supplied text
private func eventtap_keyStrokes(_ L: LuaState) throws -> CInt {

    let theString = lua_tovalue(L, at: 1) as! NSString
    var targetPid: pid_t = 0

    if lua_type(L, 2) == LUA_TUSERDATA && luaL_checkudata(L, 2, "hs.application") != nil {
        if let app = lua_toAnyObject(L, at: 2) as? HSapplicationProtocol {
            targetPid = app.pid
        }
    }

    guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        return 0
    }

    var length = theString.length
    if length > kMaxKeystrokeSynthesisLength {
        os_log(.error, "hs.eventtap.keyStrokes: string length %d exceeds %d-character limit — truncating", length, kMaxKeystrokeSynthesisLength)
        length = kMaxKeystrokeSynthesisLength
    }

    for i in 0..<length {
        var buffer = theString.character(at: i)

        keyDownEvent.flags = CGEventFlags(rawValue: 0)
        keyDownEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
        if targetPid != 0 {
            keyDownEvent.postToPid(targetPid)
        } else {
            keyDownEvent.post(tap: .cghidEventTap)
        }

        keyUpEvent.flags = CGEventFlags(rawValue: 0)
        keyUpEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
        if targetPid != 0 {
            keyUpEvent.postToPid(targetPid)
        } else {
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }

    return 0
}

/// hs.eventtap.new(types, fn) -> eventtap
/// Constructor
/// Create a new event tap object
private func eventtap_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    luaL_checktype(L, 1, LUA_TTABLE)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    let eventtap = HSEventtap()
    eventtap.lsCanary = lua_currentStateGeneration()

    lua_pushnil(L)
    while lua_next(L, 1) != 0 {
        if lua_isinteger(L, -1) != 0 {
            let typeVal = CGEventType(rawValue: UInt32(lua_tointeger(L, -1)))!
            eventtap.mask ^= (1 << typeVal.rawValue)
        } else if lua_isstring(L, -1) != 0 {
            let label = String(cString: lua_tostring(L, -1)!)
            if label == "all" {
                eventtap.mask = CGEventMask(UInt64.max)
            } else {
                luaL_error(L, "Invalid event type specified. Must be a table of numbers or {\"all\"}.")
                return 0
            }
        } else {
            luaL_error(L, "Invalid event types specified. Must be a table of numbers.")
            return 0
        }
        lua_pop(L, 1)
    }

    eventtap.fn = L.ref(index: 2)

    L.push(userdata: eventtap)

    return 1
}

/// hs.eventtap.checkKeyboardModifiers([raw]) -> table
/// Function
/// Returns a table containing the current key modifiers being pressed
private func checkKeyboardModifiers(_ L: LuaState) throws -> CInt {
    let theFlags = NSEvent.modifierFlags

    lua_newtable(L)

    if lua_isboolean(L, 1) && lua_toboolean(L, 1) != 0 {
        L.push(lua_Integer(theFlags.rawValue))
        lua_setfield(L, -2, "_raw")
    }

    if theFlags.contains(.command) {
        L.push(true); lua_setfield(L, -2, "cmd")
        L.push(true); lua_setfield(L, -2, "\u{2318}")
    }
    if theFlags.contains(.shift) {
        L.push(true); lua_setfield(L, -2, "shift")
        L.push(true); lua_setfield(L, -2, "\u{21E7}")
    }
    if theFlags.contains(.option) {
        L.push(true); lua_setfield(L, -2, "alt")
        L.push(true); lua_setfield(L, -2, "\u{2325}")
    }
    if theFlags.contains(.control) {
        L.push(true); lua_setfield(L, -2, "ctrl")
        L.push(true); lua_setfield(L, -2, "\u{2303}")
    }
    if theFlags.contains(.function) {
        L.push(true); lua_setfield(L, -2, "fn")
    }
    if theFlags.contains(.capsLock) {
        L.push(true); lua_setfield(L, -2, "capslock")
    }

    return 1
}

/// hs.eventtap.isSecureInputEnabled() -> boolean
/// Function
/// Checks if macOS is preventing keyboard events from being sent to event taps
private func secureInputEnabled(_ L: LuaState) throws -> CInt {
    L.push(IsSecureEventInputEnabled())
    return 1
}

/// hs.eventtap.checkMouseButtons() -> table
/// Function
/// Returns a table containing the current mouse buttons being pressed
private func checkMouseButtons(_ L: LuaState) throws -> CInt {
    var theButtons = NSEvent.pressedMouseButtons
    var i = 0

    lua_newtable(L)

    while theButtons != 0 {
        if theButtons & 0x1 != 0 {
            if i == 0 {
                L.push(true); lua_setfield(L, -2, "left")
            } else if i == 1 {
                L.push(true); lua_setfield(L, -2, "right")
            } else if i == 2 {
                L.push(true); lua_setfield(L, -2, "middle")
            }
        }
        L.push(lua_Integer(i + 1))
        L.push((theButtons & 0x1) != 0)
        lua_settable(L, -3)
        i += 1
        theButtons >>= 1
    }
    return 1
}

/// hs.eventtap.keyRepeatInterval() -> number
/// Function
/// Returns the system-wide setting for the interval between repeated keyboard events
private func eventtap_keyRepeatInterval(_ L: LuaState) throws -> CInt {
    L.push(NSEvent.keyRepeatInterval)
    return 1
}

/// hs.eventtap.keyRepeatDelay() -> number
/// Function
/// Returns the system-wide setting for the delay before keyboard repeat events begin
private func eventtap_keyRepeatDelay(_ L: LuaState) throws -> CInt {
    L.push(NSEvent.keyRepeatDelay)
    return 1
}

/// hs.eventtap.doubleClickInterval() -> number
/// Function
/// Returns the system-wide setting for the delay between two clicks
private func eventtap_doubleClickInterval(_ L: LuaState) throws -> CInt {
    L.push(NSEvent.doubleClickInterval)
    return 1
}

// MARK: - Registration

@_cdecl("luaopen_hs_libeventtap")
public func luaopen_hs_libeventtap(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSEventtap> with LuaSwift.
    L.register(Metatable<HSEventtap>(
        fields: [
            "start": .closure { L in
                let e: HSEventtap = try L.checkArgument(1)

                let tapEnabled = e.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false

                if !tapEnabled {
                    if let oldTap = e.tap {
                        CFMachPortInvalidate(oldTap)
                        if let src = e.runloopsrc {
                            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                        }
                    }

                    let userInfo = Unmanaged.passUnretained(e).toOpaque()
                    e.tap = CGEvent.tapCreate(
                        tap: .cgSessionEventTap,
                        place: .headInsertEventTap,
                        options: .defaultTap,
                        eventsOfInterest: e.mask,
                        callback: eventtapCallback,
                        userInfo: userInfo
                    )

                    if let tap = e.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        e.runloopsrc = CFMachPortCreateRunLoopSource(nil, tap, 0)
                        if let src = e.runloopsrc {
                            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
                        }
                    } else {
                        os_log(.error, "%{public}s", "hs.eventtap:start() Unable to create eventtap. Is Accessibility enabled?")
                    }
                }
                lua_settop(L, 1)
                return 1
            },
            "stop": .closure { L in
                let e: HSEventtap = try L.checkArgument(1)
                e.stopTap()
                lua_settop(L, 1)
                return 1
            },
            "isEnabled": .closure { L in
                let e: HSEventtap = try L.checkArgument(1)
                let enabled = e.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
                L.push(enabled)
                return 1
            },
        ],
        tostring: .closure { L in
            let e: HSEventtap = try L.checkArgument(1)
            L.push("\(USERDATA_TAG): Eventtap Mask: 0x\(String(e.mask, radix: 16)) (\(String(describing: lua_topointer(L, 1)!)))")
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // Replace __gc with our explicit teardown + deinitialize
    L.pushMetatable(for: HSEventtap.self)

    L.push({ (L: LuaState!) -> CInt in
        if let e: HSEventtap = L.touserdata(1) {
            e.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        rawptr.assumingMemoryBound(to: Any.self).deinitialize(count: 1)
        return 0
    })
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.eventtap") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 8)
    L.push(eventtap_new)
    lua_setfield(L, -2, "new")
    L.push(eventtap_keyStrokes)
    lua_setfield(L, -2, "keyStrokes")
    L.push(checkKeyboardModifiers)
    lua_setfield(L, -2, "checkKeyboardModifiers")
    L.push(checkMouseButtons)
    lua_setfield(L, -2, "checkMouseButtons")
    L.push(eventtap_keyRepeatDelay)
    lua_setfield(L, -2, "keyRepeatDelay")
    L.push(eventtap_keyRepeatInterval)
    lua_setfield(L, -2, "keyRepeatInterval")
    L.push(eventtap_doubleClickInterval)
    lua_setfield(L, -2, "doubleClickInterval")
    L.push(secureInputEnabled)
    lua_setfield(L, -2, "isSecureInputEnabled")

    // Set module metatable (for __gc)
    lua_createtable(L, 0, 1)
    L.push({ (L: LuaState!) -> CInt in
        return 0
    })
    lua_setfield(L, -2, "__gc")
    lua_setmetatable(L, -2)

    return 1
}
