import Cocoa
import Carbon
import LuaSkin

// MARK: - Constants

private let USERDATA_TAG = "hs.eventtap"
private var refTable: LSRefTable = 0

// MARK: - Eventtap struct (mirrors the C struct)

private struct eventtap_t {
    var fn: Int32 = 0
    var mask: CGEventMask = 0
    var tap: CFMachPort? = nil
    var runloopsrc: CFRunLoopSource? = nil
    var lsCanary: LSGCCanary = 0
}

// MARK: - Event tap callback

private func eventtap_callback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.l!

    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let e = refcon.assumingMemoryBound(to: eventtap_t.self)

    // Guard against this callback being delivered at a point where LuaSkin has been reset
    if !skin.checkGCCanary(e.pointee.lsCanary) {
        return Unmanaged.passUnretained(event)
    }

    _lua_stackguard_entry(L)

    // Guard against a crash where e->fn is a LUA_NOREF/LUA_REFNIL
    if e.pointee.fn == LUA_NOREF || e.pointee.fn == LUA_REFNIL {
        skin.logBreadcrumb("eventtap_callback called with LUA_NOREF/LUA_REFNIL")
        _lua_stackguard_exit(L)
        return Unmanaged.passUnretained(event)
    }

    // OS X disables eventtaps if it thinks they are slow or odd
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        skin.logBreadcrumb("eventtap restarted: (\(type.rawValue))")
        CGEvent.tapEnable(tap: e.pointee.tap!, enable: true)
        _lua_stackguard_exit(L)
        return Unmanaged.passUnretained(event)
    }

    skin.pushLuaRef(refTable, ref: e.pointee.fn)
    new_eventtap_event(L, event: event.takeUnretainedValue() as! CGEventRef)

    if !skin.protectedCallAndTraceback(1, nresults: 2) {
        if let errorMsg = lua_tostring(L, -1) {
            let str = String(cString: errorMsg)
            skin.logError("hs.eventtap callback error: \(str)")
        } else {
            skin.logBreadcrumb("ERROR: eventtap_callback callback returned something that isn't a string: \(lua_type(L, -1))")
        }
        lua_pop(L, 1)
        _lua_stackguard_exit(L)
        return nil
    }

    let ignoreevent = lua_toboolean(L, -2) != 0

    if lua_istable(L, -1) != 0 {
        lua_pushnil(L)
        while lua_next(L, -2) != 0 {
            if lua_type(L, -1) == LUA_TUSERDATA && luaL_testudata(L, -1, EVENT_USERDATA_TAG) != nil {
                let newEvent = hs_to_eventtap_event(L, idx: -1)
                CGEventTapPostEvent(proxy, newEvent)
            }
            lua_pop(L, 1)
        }
    }

    lua_pop(L, 2)
    _lua_stackguard_exit(L)

    if ignoreevent {
        return nil
    } else {
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Module functions

/// hs.eventtap.keyStrokes(text[, application])
/// Function
/// Generates and emits keystroke events for the supplied text
///
/// Parameters:
///  * text - A string containing the text to be typed
///  * application - An optional hs.application object to send the keystrokes to
///
/// Returns:
///  * None
///
/// Notes:
///  * If you want to send a single keystroke with keyboard modifiers (e.g. sending ⌘-v to paste), see `hs.eventtap.keyStroke()`
private func eventtap_keyStrokes(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TANY | LS_TOPTIONAL, LS_TBREAK)

    let theString = skin.toNSObject(atIndex: 1) as! NSString
    var targetPid: pid_t = 0

    if lua_type(L, 2) == LUA_TUSERDATA && luaL_checkudata(L, 2, "hs.application") != nil {
        let app = skin.toNSObject(atIndex: 2) as! HSapplication
        targetPid = app.pid
    }

    guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        return 0
    }

    var buffer: UniChar = 0
    for i in 0..<theString.length {
        theString.getCharacters(&buffer, range: NSRange(location: i, length: 1))

        // Send the keydown
        keyDownEvent.flags = CGEventFlags(rawValue: 0)
        keyDownEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
        if targetPid != 0 {
            keyDownEvent.postToPid(targetPid)
        } else {
            keyDownEvent.post(tap: .cghidEventTap)
        }

        // Send the keyup
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
///
/// Parameters:
///  * types - A table that should contain values from `hs.eventtap.event.types`
///  * fn - A function that will be called when the specified event types occur. The function should take a single parameter, which will be an event object. It can optionally return two values. Firstly, a boolean, true if the event should be deleted, false if it should propagate to any other applications watching for that event. Secondly, a table of events to post.
///
/// Returns:
///  * An event tap object
///
/// Notes:
///  * If you specify the argument `types` as the special table {"all"[, events to ignore]}, then *all* events (except those you optionally list *after* the "all" string) will trigger a callback, even events which are not defined in the [Quartz Event Reference](https://developer.apple.com/library/mac/documentation/Carbon/Reference/QuartzEventServicesRef/Reference/reference.html).
private func eventtap_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    luaL_checktype(L, 1, LUA_TTABLE)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    let eventtapPtr = lua_newuserdata(L, MemoryLayout<eventtap_t>.size)!
        .assumingMemoryBound(to: eventtap_t.self)
    memset(eventtapPtr, 0, MemoryLayout<eventtap_t>.size)

    eventtapPtr.pointee.tap = nil
    eventtapPtr.pointee.lsCanary = skin.createGCCanary()

    lua_pushnil(L)
    while lua_next(L, 1) != 0 {
        if lua_isinteger(L, -1) != 0 {
            let type = CGEventType(rawValue: UInt32(lua_tointeger(L, -1)))!
            eventtapPtr.pointee.mask ^= CGEventMask(1 << type.rawValue)
        } else if lua_isstring(L, -1) != 0 {
            let label = String(cString: lua_tostring(L, -1))
            if label == "all" {
                eventtapPtr.pointee.mask = CGEventMask(CGEventMask.max) // kCGEventMaskForAllEvents
            } else {
                return luaL_error(L, "Invalid event type specified. Must be a table of numbers or {\"all\"}.")
            }
        } else {
            return luaL_error(L, "Invalid event types specified. Must be a table of numbers.")
        }
        lua_pop(L, 1)
    }

    lua_pushvalue(L, 2)
    eventtapPtr.pointee.fn = skin.luaRef(refTable)

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.eventtap:start()
/// Method
/// Starts an event tap
///
/// Parameters:
///  * None
///
/// Returns:
///  * The event tap object
private func eventtap_start(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let e = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: eventtap_t.self)

    if !(e.pointee.tap != nil && CGEvent.tapIsEnabled(tap: e.pointee.tap!)) {
        // Just in case; don't want dangling ports and loops and such lying around.
        if let tap = e.pointee.tap, !CGEvent.tapIsEnabled(tap: tap) {
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), e.pointee.runloopsrc, .commonModes)
            CFRelease(e.pointee.runloopsrc!)
            CFRelease(tap)
        }

        e.pointee.tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: e.pointee.mask,
            callback: { proxy, type, event, refcon in
                eventtap_callback(proxy: proxy, type: type, event: event, refcon: refcon)
            },
            userInfo: e
        )

        if let tap = e.pointee.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            e.pointee.runloopsrc = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), e.pointee.runloopsrc, .commonModes)
        } else {
            skin.logError("hs.eventtap:start() Unable to create eventtap. Is Accessibility enabled?")
        }
    }
    lua_settop(L, 1)
    return 1
}

/// hs.eventtap:stop()
/// Method
/// Stops an event tap
///
/// Parameters:
///  * None
///
/// Returns:
///  * The event tap object
private func eventtap_stop(_ L: OpaquePointer!) -> Int32 {
    let e = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: eventtap_t.self)

    if let tap = e.pointee.tap {
        if CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), e.pointee.runloopsrc, .commonModes)
        CFRelease(e.pointee.runloopsrc!)
        CFRelease(tap)
        e.pointee.tap = nil
    }
    lua_settop(L, 1)
    return 1
}

/// hs.eventtap:isEnabled() -> bool
/// Method
/// Determine whether or not an event tap object is enabled.
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the event tap is enabled or false if it is not.
private func eventtap_isEnabled(_ L: OpaquePointer!) -> Int32 {
    let e = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: eventtap_t.self)
    let enabled = e.pointee.tap != nil && CGEvent.tapIsEnabled(tap: e.pointee.tap!)
    lua_pushboolean(L, enabled ? 1 : 0)
    return 1
}

/// hs.eventtap.checkKeyboardModifiers([raw]) -> table
/// Function
/// Returns a table containing the current key modifiers being pressed or in effect *at this instant* for the keyboard most recently used.
///
/// Parameters:
///  * raw - an optional boolean value which, if true, includes the _raw key containing the numeric representation of all of the keyboard/modifier flags.
///
/// Returns:
///  * Returns a table containing boolean values indicating which keyboard modifiers were held down when the function was invoked; The possible keys are:
///     * cmd (or ⌘)
///     * alt (or ⌥)
///     * shift (or ⇧)
///     * ctrl (or ⌃)
///     * capslock
///     * fn
///   and optionally
///     * _raw - a numeric representation of the numeric representation of all of the keyboard/modifier flags.
///
/// Notes:
///  * This is an instantaneous poll of the current keyboard modifiers for the most recently used keyboard, not a callback.  This is useful primarily in conjunction with other modules, such as `hs.menubar`, when a callback is already in progress or waiting for an event callback is not practical or possible.
///  * the numeric value returned is useful if you need to detect device dependent flags or flags which we normally ignore because they are not present (or are accessible another way) on most keyboards.
private func checkKeyboardModifiers(_ L: OpaquePointer!) -> Int32 {
    let theFlags = NSEvent.modifierFlags

    lua_newtable(L)

    if lua_isboolean(L, 1) != 0 && lua_toboolean(L, 1) != 0 {
        lua_pushinteger(L, lua_Integer(theFlags.rawValue))
        lua_setfield(L, -2, "_raw")
    }

    if theFlags.contains(.command) {
        lua_pushboolean(L, 1); lua_setfield(L, -2, "cmd")
        lua_pushboolean(L, 1); lua_setfield(L, -2, "⌘")
    }
    if theFlags.contains(.shift) {
        lua_pushboolean(L, 1); lua_setfield(L, -2, "shift")
        lua_pushboolean(L, 1); lua_setfield(L, -2, "⇧")
    }
    if theFlags.contains(.option) {
        lua_pushboolean(L, 1); lua_setfield(L, -2, "alt")
        lua_pushboolean(L, 1); lua_setfield(L, -2, "⌥")
    }
    if theFlags.contains(.control) {
        lua_pushboolean(L, 1); lua_setfield(L, -2, "ctrl")
        lua_pushboolean(L, 1); lua_setfield(L, -2, "⌃")
    }
    if theFlags.contains(.function) {
        lua_pushboolean(L, 1); lua_setfield(L, -2, "fn")
    }
    if theFlags.contains(.capsLock) {
        lua_pushboolean(L, 1); lua_setfield(L, -2, "capslock")
    }

    return 1
}

/// hs.eventtap.isSecureInputEnabled() -> boolean
/// Function
/// Checks if macOS is preventing keyboard events from being sent to event taps
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if secure input is enabled, otherwise false
///
/// Notes:
///  * If secure input is enabled, Hammerspoon is not able to intercept keyboard events
///  * Secure input is enabled generally only in situations where an password field is focused in a web browser, system dialog or terminal
private func secureInputEnabled(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)

    let isSecure = IsSecureEventInputEnabled()
    lua_pushboolean(L, isSecure ? 1 : 0)
    return 1
}

/// hs.eventtap.checkMouseButtons() -> table
/// Function
/// Returns a table containing the current mouse buttons being pressed *at this instant*.
///
/// Parameters:
///  * None
///
/// Returns:
///  * Returns an array containing indices starting from 1 up to the highest numbered button currently being pressed where the index is `true` if the button is currently pressed or `false` if it is not.
///  * Special hash tag synonyms for `left` (button 1), `right` (button 2), and `middle` (button 3) are also set to true if these buttons are currently being pressed.
///
/// Notes:
///  * This is an instantaneous poll of the current mouse buttons, not a callback.  This is useful primarily in conjunction with other modules, such as `hs.menubar`, when a callback is already in progress or waiting for an event callback is not practical or possible.
private func checkMouseButtons(_ L: OpaquePointer!) -> Int32 {
    var theButtons = NSEvent.pressedMouseButtons
    var i: Int = 0

    lua_newtable(L)

    while theButtons != 0 {
        if theButtons & 0x1 != 0 {
            if i == 0 {
                lua_pushboolean(L, 1)
                lua_setfield(L, -2, "left")
            } else if i == 1 {
                lua_pushboolean(L, 1)
                lua_setfield(L, -2, "right")
            } else if i == 2 {
                lua_pushboolean(L, 1)
                lua_setfield(L, -2, "middle")
            }
        }
        lua_pushinteger(L, lua_Integer(i + 1))
        lua_pushboolean(L, Int32(theButtons & 0x1))
        lua_settable(L, -3)
        i += 1
        theButtons >>= 1
    }
    return 1
}

/// hs.eventtap.keyRepeatInterval() -> number
/// Function
/// Returns the system-wide setting for the interval between repeated keyboard events
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of seconds between keyboard events, if a key is held down
private func eventtap_keyRepeatInterval(_ L: OpaquePointer!) -> Int32 {
    lua_pushnumber(L, NSEvent.keyRepeatInterval)
    return 1
}

/// hs.eventtap.keyRepeatDelay() -> number
/// Function
/// Returns the system-wide setting for the delay before keyboard repeat events begin
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of seconds before repeat events begin, after a key is held down
private func eventtap_keyRepeatDelay(_ L: OpaquePointer!) -> Int32 {
    lua_pushnumber(L, NSEvent.keyRepeatDelay)
    return 1
}

/// hs.eventtap.doubleClickInterval() -> number
/// Function
/// Returns the system-wide setting for the delay between two clicks, to register a double click event
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the maximum number of seconds between two mouse click events, for a double click event to be registered
private func eventtap_doubleClickInterval(_ L: OpaquePointer!) -> Int32 {
    lua_pushnumber(L, NSEvent.doubleClickInterval)
    return 1
}

// MARK: - GC and metatable functions

private func eventtap_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    let eventtap = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: eventtap_t.self)

    if let tap = eventtap.pointee.tap {
        if CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), eventtap.pointee.runloopsrc, .commonModes)
        CFRelease(eventtap.pointee.runloopsrc!)
        CFRelease(tap)
        eventtap.pointee.tap = nil
    }

    eventtap.pointee.fn = skin.luaUnref(refTable, ref: eventtap.pointee.fn)
    skin.destroyGCCanary(&eventtap.pointee.lsCanary)

    return 0
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let e = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: eventtap_t.self)

    let str = String(format: "%@: Eventtap Mask: 0x%llx (%p)", USERDATA_TAG, e.pointee.mask, lua_topointer(L, 1)!)
    lua_pushstring(L, str)
    return 1
}

// MARK: - luaL_Reg tables

// Metatable for created objects when _new invoked
private let eventtap_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: eventtap_start),
    luaL_Reg(name: strdup("stop"),       func: eventtap_stop),
    luaL_Reg(name: strdup("isEnabled"),  func: eventtap_isEnabled),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"),       func: eventtap_gc),
    luaL_Reg(name: nil,                  func: nil),
]

// Functions for returned object when module loads
private var eventtaplib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),                    func: eventtap_new),
    luaL_Reg(name: strdup("keyStrokes"),             func: eventtap_keyStrokes),
    luaL_Reg(name: strdup("checkKeyboardModifiers"), func: checkKeyboardModifiers),
    luaL_Reg(name: strdup("checkMouseButtons"),      func: checkMouseButtons),
    luaL_Reg(name: strdup("keyRepeatDelay"),         func: eventtap_keyRepeatDelay),
    luaL_Reg(name: strdup("keyRepeatInterval"),      func: eventtap_keyRepeatInterval),
    luaL_Reg(name: strdup("doubleClickInterval"),    func: eventtap_doubleClickInterval),
    luaL_Reg(name: strdup("isSecureInputEnabled"),   func: secureInputEnabled),
    luaL_Reg(name: nil,                              func: nil),
]

// Metatable for returned object when module loads
private let meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libeventtap")
public func luaopen_hs_libeventtap(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: eventtaplib,
                                    metaFunctions: meta_gcLib,
                                    objectFunctions: eventtap_metalib)
    return 1
}
