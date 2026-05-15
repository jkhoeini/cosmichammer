import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.eventtap"
private var refTable: LSRefTable = LUA_NOREF

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

// MARK: - Eventtap State

private class Eventtap {
    var fn: Int32 = LUA_NOREF
    var mask: CGEventMask = 0
    var tap: CFMachPort?
    var runloopsrc: CFRunLoopSource?
    var lsCanary: LSGCCanary = LSGCCanary()
}

private func getEventtap(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> Eventtap? {
    guard let ud = luaL_checkudata(L, idx, USERDATA_TAG) else { return nil }
    let ptr = ud.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<Eventtap>.fromOpaque(rawPtr).takeUnretainedValue()
}

// MARK: - CGEventTap Callback

private let eventtapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let e = Unmanaged<Eventtap>.fromOpaque(userInfo).takeUnretainedValue()

    let skin = LuaSkin.skin(with: nil)
    let L = skin.l

    if !skin.check(e.lsCanary) {
        return Unmanaged.passUnretained(event)
    }

    if e.fn == LUA_NOREF || e.fn == LUA_REFNIL {
        skin.logBreadcrumb("eventtap_callback called with LUA_NOREF/LUA_REFNIL")
        return Unmanaged.passUnretained(event)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        skin.logBreadcrumb("eventtap restarted: (\(type.rawValue))")
        if let tap = e.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    skin.pushLuaRef(refTable, ref: e.fn)
    newEventtapEvent(L, event)

    if !skin.protectedCallAndTraceback(1, nresults: 2) {
        let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
        skin.logError("hs.eventtap callback error: \(errorMsg)")
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
private func eventtap_keyStrokes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TANY | LS_TOPTIONAL, LS_TBREAK)

    let theString = skin.toNSObject(at: 1) as! NSString
    var targetPid: pid_t = 0

    if lua_type(L, 2) == LUA_TUSERDATA && luaL_checkudata(L, 2, "hs.application") != nil {
        if let app = skin.toNSObject(at: 2) as? HSapplicationProtocol {
            targetPid = app.pid
        }
    }

    guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        return 0
    }

    for i in 0..<theString.length {
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
    let skin = LuaSkin.skin(with: L)

    luaL_checktype(L, 1, LUA_TTABLE)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    let eventtap = Eventtap()
    eventtap.lsCanary = skin.createGCCanary()

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
                return luaL_error(L, "Invalid event type specified. Must be a table of numbers or {\"all\"}.")
            }
        } else {
            return luaL_error(L, "Invalid event types specified. Must be a table of numbers.")
        }
        lua_pop(L, 1)
    }

    lua_pushvalue(L, 2)
    eventtap.fn = skin.luaRef(refTable)

    let ud = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    ud.pointee = Unmanaged.passRetained(eventtap).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.eventtap:start()
/// Method
/// Starts an event tap
private func eventtap_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    guard let e = getEventtap(L, at: 1) else { return 0 }

    let tapEnabled = e.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false

    if !tapEnabled {
        if let oldTap = e.tap {
            CFMachPortInvalidate(oldTap)
            if let src = e.runloopsrc {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                // CFRelease handled by Swift ARC for CFRunLoopSource
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
            skin.logError("hs.eventtap:start() Unable to create eventtap. Is Accessibility enabled?")
        }
    }
    lua_settop(L, 1)
    return 1
}

/// hs.eventtap:stop()
/// Method
/// Stops an event tap
private func eventtap_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let e = getEventtap(L, at: 1) else { return 0 }

    if let tap = e.tap {
        if CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: false) }
        CFMachPortInvalidate(tap)
        if let src = e.runloopsrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        e.tap = nil
        e.runloopsrc = nil
    }
    lua_settop(L, 1)
    return 1
}

/// hs.eventtap:isEnabled() -> bool
/// Method
/// Determine whether or not an event tap object is enabled.
private func eventtap_isEnabled(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let e = getEventtap(L, at: 1) else {
        lua_pushboolean(L, 0)
        return 1
    }
    let enabled = e.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    lua_pushboolean(L, enabled ? 1 : 0)
    return 1
}

/// hs.eventtap.checkKeyboardModifiers([raw]) -> table
/// Function
/// Returns a table containing the current key modifiers being pressed
private func checkKeyboardModifiers(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theFlags = NSEvent.modifierFlags

    lua_newtable(L)

    if lua_isboolean(L, 1) && lua_toboolean(L, 1) != 0 {
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
private func secureInputEnabled(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    lua_pushboolean(L, IsSecureEventInputEnabled() ? 1 : 0)
    return 1
}

/// hs.eventtap.checkMouseButtons() -> table
/// Function
/// Returns a table containing the current mouse buttons being pressed
private func checkMouseButtons(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var theButtons = NSEvent.pressedMouseButtons
    var i = 0

    lua_newtable(L)

    while theButtons != 0 {
        if theButtons & 0x1 != 0 {
            if i == 0 {
                lua_pushboolean(L, 1); lua_setfield(L, -2, "left")
            } else if i == 1 {
                lua_pushboolean(L, 1); lua_setfield(L, -2, "right")
            } else if i == 2 {
                lua_pushboolean(L, 1); lua_setfield(L, -2, "middle")
            }
        }
        lua_pushinteger(L, lua_Integer(i + 1))
        lua_pushboolean(L, (theButtons & 0x1) != 0 ? 1 : 0)
        lua_settable(L, -3)
        i += 1
        theButtons >>= 1
    }
    return 1
}

/// hs.eventtap.keyRepeatInterval() -> number
/// Function
/// Returns the system-wide setting for the interval between repeated keyboard events
private func eventtap_keyRepeatInterval(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushnumber(L, NSEvent.keyRepeatInterval)
    return 1
}

/// hs.eventtap.keyRepeatDelay() -> number
/// Function
/// Returns the system-wide setting for the delay before keyboard repeat events begin
private func eventtap_keyRepeatDelay(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushnumber(L, NSEvent.keyRepeatDelay)
    return 1
}

/// hs.eventtap.doubleClickInterval() -> number
/// Function
/// Returns the system-wide setting for the delay between two clicks
private func eventtap_doubleClickInterval(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushnumber(L, NSEvent.doubleClickInterval)
    return 1
}

// MARK: - Infrastructure

private func eventtap_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ud = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ud.pointee {
        let e = Unmanaged<Eventtap>.fromOpaque(rawPtr).takeRetainedValue()

        if let tap = e.tap {
            if CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: false) }
            CFMachPortInvalidate(tap)
            if let src = e.runloopsrc {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            e.tap = nil
            e.runloopsrc = nil
        }

        e.fn = skin.luaUnref(refTable, ref: e.fn)
        var canary = e.lsCanary
        skin.destroy(&canary)
        e.lsCanary = canary

        ud.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let e = getEventtap(L, at: 1) else {
        lua_pushstring(L, "\(USERDATA_TAG): (nil)")
        return 1
    }
    lua_pushstring(L, "\(USERDATA_TAG): Eventtap Mask: 0x\(String(e.mask, radix: 16)) (\(String(describing: lua_topointer(L, 1)!)))")
    return 1
}

// MARK: - Registration

private let userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: eventtap_start),
    luaL_Reg(name: strdup("stop"),       func: eventtap_stop),
    luaL_Reg(name: strdup("isEnabled"),  func: eventtap_isEnabled),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"),       func: eventtap_gc),
    luaL_Reg(name: nil, func: nil),
]

private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),                    func: eventtap_new),
    luaL_Reg(name: strdup("keyStrokes"),             func: eventtap_keyStrokes),
    luaL_Reg(name: strdup("checkKeyboardModifiers"), func: checkKeyboardModifiers),
    luaL_Reg(name: strdup("checkMouseButtons"),      func: checkMouseButtons),
    luaL_Reg(name: strdup("keyRepeatDelay"),         func: eventtap_keyRepeatDelay),
    luaL_Reg(name: strdup("keyRepeatInterval"),      func: eventtap_keyRepeatInterval),
    luaL_Reg(name: strdup("doubleClickInterval"),    func: eventtap_doubleClickInterval),
    luaL_Reg(name: strdup("isSecureInputEnabled"),   func: secureInputEnabled),
    luaL_Reg(name: nil, func: nil),
]

private let module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libeventtap")
public func luaopen_hs_libeventtap(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: moduleLib,
                                    metaFunctions: module_metaLib,
                                    objectFunctions: userdata_metaLib)
    return 1
}
