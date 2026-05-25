import Cocoa
import Carbon
import LuaSkin
import IOKit
import IOKit.hidsystem

// MARK: - Private Constants

private let FLAGS_TAG = "hs.eventtap.event.flags"
private let APPLICATION_USERDATA_TAG = "hs.application"

// IOHIDEventPhase constants (from private IOHIDEventTypes.h)
private let kIOHIDEventPhaseBegan: UInt32    = 1 << 0
private let kIOHIDEventPhaseEnded: UInt32    = 1 << 2

// TouchEvents.h gesture subtypes
private let kTLInfoSubtypeRotate: UInt32       = 0x05
private let kTLInfoSubtypeMagnify: UInt32      = 0x08
private let kTLInfoSubtypeSwipe: UInt32        = 0x10
private let kTLInfoSubtypeSmartMagnify: UInt32 = 0x16

// TouchEvents.h swipe directions
private let kTLInfoSwipeUp: UInt32    = 1
private let kTLInfoSwipeDown: UInt32  = 2
private let kTLInfoSwipeLeft: UInt32  = 4
private let kTLInfoSwipeRight: UInt32 = 8

// CFString keys from TouchEvents.h — resolved at runtime via dlsym
private func loadCFString(_ name: String) -> CFString {
    guard let handle = dlopen(nil, RTLD_LAZY),
          let sym = dlsym(handle, name) else {
        return name as CFString
    }
    return Unmanaged<CFString>.fromOpaque(sym.assumingMemoryBound(to: UnsafeRawPointer.self).pointee).takeUnretainedValue()
}

private let kTLInfoKeyGestureSubtype = loadCFString("kTLInfoKeyGestureSubtype")
private let kTLInfoKeyGesturePhase   = loadCFString("kTLInfoKeyGesturePhase")
private let kTLInfoKeyMagnification  = loadCFString("kTLInfoKeyMagnification")
private let kTLInfoKeyRotation       = loadCFString("kTLInfoKeyRotation")
private let kTLInfoKeySwipeDirection  = loadCFString("kTLInfoKeySwipeDirection")

// tl_CGEventCreateFromGesture from TouchEvents — a private SPI
private typealias TLCGEventCreateFromGestureFunc = @convention(c) (CFDictionary, CFArray) -> Unmanaged<CGEvent>?
private let tl_CGEventCreateFromGesture: TLCGEventCreateFromGestureFunc? = {
    guard let handle = dlopen(nil, RTLD_LAZY),
          let sym = dlsym(handle, "tl_CGEventCreateFromGesture") else { return nil }
    return unsafeBitCast(sym, to: TLCGEventCreateFromGestureFunc.self)
}()

// Event source (module-level, like the ObjC static)
private var eventSource: CGEventSource? = nil

// MARK: - Helpers

private func getEvent(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> CGEvent {
    let ptr = luaL_checkudata(L, idx, EVENTTAP_EVENT_USERDATA_TAG)!
    return Unmanaged<CGEvent>.fromOpaque(
        ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()
}

private func parseFlagsFromTable(_ L: UnsafeMutablePointer<lua_State>!, _ arg: Int32) -> CGEventFlags {
    luaL_checktype(L, arg, LUA_TTABLE)
    var flags = CGEventFlags(rawValue: 0)
    lua_getfield(L, arg, "cmd");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskCommand) };   lua_pop(L, 1)
    lua_getfield(L, arg, "alt");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskAlternate) }; lua_pop(L, 1)
    lua_getfield(L, arg, "ctrl");  if lua_toboolean(L, -1) != 0 { flags.insert(.maskControl) };   lua_pop(L, 1)
    lua_getfield(L, arg, "shift"); if lua_toboolean(L, -1) != 0 { flags.insert(.maskShift) };     lua_pop(L, 1)
    lua_getfield(L, arg, "fn");    if lua_toboolean(L, -1) != 0 { flags.insert(.maskSecondaryFn) }; lua_pop(L, 1)
    return flags
}

private func parseFlagsFromArray(_ L: UnsafeMutablePointer<lua_State>!, _ arg: Int32) -> CGEventFlags {
    luaL_checktype(L, arg, LUA_TTABLE)
    var flags = CGEventFlags(rawValue: 0)
    lua_pushnil(L)
    while lua_next(L, arg) != 0 {
        guard let modifier = lua_tostring(L, -1).map({ String(cString: $0) }) else {
            lua_pop(L, 1); continue
        }
        switch modifier {
        case "cmd", "\u{2318}":   flags.insert(.maskCommand)
        case "ctrl", "\u{2303}":  flags.insert(.maskControl)
        case "alt", "\u{2325}":   flags.insert(.maskAlternate)
        case "shift", "\u{21E7}": flags.insert(.maskShift)
        case "fn":                flags.insert(.maskSecondaryFn)
        default: break
        }
        lua_pop(L, 1)
    }
    return flags
}

private func parseModsFromIterator(_ L: UnsafeMutablePointer<lua_State>!, tableIndex: Int32) -> CGEventFlags {
    var flags = CGEventFlags(rawValue: 0)
    lua_pushnil(L)
    while lua_next(L, tableIndex) != 0 {
        guard let modifier = lua_tostring(L, -1).map({ String(cString: $0) }) else {
            let skin = LuaSkin.skin(with: L)
            skin.logBreadcrumb("unexpected entry in modifiers table: \(lua_type(L, -1))")
            lua_pop(L, 1); continue
        }
        switch modifier {
        case "cmd", "\u{2318}":   flags.insert(.maskCommand)
        case "ctrl", "\u{2303}":  flags.insert(.maskControl)
        case "alt", "\u{2325}":   flags.insert(.maskAlternate)
        case "shift", "\u{21E7}": flags.insert(.maskShift)
        case "fn":                flags.insert(.maskSecondaryFn)
        default: break
        }
        lua_pop(L, 1)
    }
    return flags
}

private func hsToPoint(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> CGPoint {
    luaL_checktype(L, idx, LUA_TTABLE)
    lua_getfield(L, idx, "x"); let x = CGFloat(luaL_checknumber(L, -1))
    lua_getfield(L, idx, "y"); let y = CGFloat(luaL_checknumber(L, -1))
    lua_pop(L, 2)
    return CGPoint(x: x, y: y)
}

// MARK: - GC

private func eventtap_event_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ud = luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ud.pointee {
        Unmanaged<CGEvent>.fromOpaque(rawPtr).release()
        ud.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Constructors

private func eventtap_event_copy(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    guard let copy = event.copy() else { lua_pushnil(L); return 1 }
    newEventtapEvent(L, copy)
    return 1
}

private func eventtap_event_newEvent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let event = CGEvent(source: eventSource) else { lua_pushnil(L); return 1 }
    newEventtapEvent(L, event)
    return 1
}

private func eventtap_event_newEventFromData(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    guard let data = skin.toNSObject(atIndex: 1, withOptions: .nsLuaStringAsDataOnly) as? Data else {
        lua_pushnil(L); return 1
    }
    if let event = CGEvent(withDataAllocator: nil, data: data as CFData) {
        newEventtapEvent(L, event)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_newGesture(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    guard let gesture = lua_tostring(L, 1).map({ String(cString: $0) }) else {
        lua_pushnil(L); return 1
    }

    var dict = [CFString: Any]()

    switch gesture {
    case "beginSwipeLeft", "beginSwipeRight", "beginSwipeUp", "beginSwipeDown":
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeSwipe
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseBegan

    case "endSwipeLeft":
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeSwipe
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseEnded
        dict[kTLInfoKeySwipeDirection] = kTLInfoSwipeLeft
    case "endSwipeRight":
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeSwipe
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseEnded
        dict[kTLInfoKeySwipeDirection] = kTLInfoSwipeRight
    case "endSwipeUp":
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeSwipe
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseEnded
        dict[kTLInfoKeySwipeDirection] = kTLInfoSwipeUp
    case "endSwipeDown":
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeSwipe
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseEnded
        dict[kTLInfoKeySwipeDirection] = kTLInfoSwipeDown

    case "beginMagnify":
        let mag = lua_isnoneornil(L, 2) ? 0.0 : lua_tonumber(L, 2)
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeMagnify
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseBegan
        dict[kTLInfoKeyMagnification] = mag
    case "endMagnify":
        let mag = lua_isnoneornil(L, 2) ? 0.1 : lua_tonumber(L, 2)
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeMagnify
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseEnded
        dict[kTLInfoKeyMagnification] = mag

    case "smartMagnify":
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeSmartMagnify

    case "beginRotate":
        let rot = lua_isnoneornil(L, 2) ? 0.0 : lua_tonumber(L, 2)
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeRotate
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseBegan
        dict[kTLInfoKeyRotation] = rot
    case "endRotate":
        let rot = lua_isnoneornil(L, 2) ? 45.0 : lua_tonumber(L, 2)
        dict[kTLInfoKeyGestureSubtype] = kTLInfoSubtypeRotate
        dict[kTLInfoKeyGesturePhase] = kIOHIDEventPhaseEnded
        dict[kTLInfoKeyRotation] = rot

    default:
        LuaSkin.skin(with: L).logError("hs.eventtap.event.newGesture() - Invalid gesture identifier supplied.")
        lua_pushnil(L); return 1
    }

    guard let createFromGesture = tl_CGEventCreateFromGesture else {
        lua_pushnil(L); return 1
    }
    let cfDict = dict as CFDictionary
    let cfArr = [] as CFArray
    if let unmanaged = createFromGesture(cfDict, cfArr) {
        let event = unmanaged.takeRetainedValue()
        newEventtapEvent(L, event)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Methods

private func eventtap_event_asData(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    if let data = event.data {
        let skin = LuaSkin.skin(with: L)
        skin.pushNSObject(data as NSData)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_location(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L, 1)
    if lua_gettop(L) == 1 {
        let loc = event.location
        skin.pushNSPoint(NSPoint(x: loc.x, y: loc.y))
    } else {
        let point = skin.tableToPoint(at: 2)
        event.location = CGPoint(x: point.x, y: point.y)
        lua_pushvalue(L, 1)
    }
    return 1
}

private func eventtap_event_timestamp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L, 1)
    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(event.timestamp))
    } else {
        event.timestamp = CGEventTimestamp(lua_tointeger(L, 2))
        lua_pushvalue(L, 1)
    }
    return 1
}

private func eventtap_event_setType(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let event = getEvent(L, 1)
    event.type = CGEventType(rawValue: UInt32(lua_tointeger(L, 2)))!
    lua_pushvalue(L, 1)
    return 1
}

private func eventtap_event_rawFlags(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L, 1)
    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(event.flags.rawValue))
    } else {
        event.flags = CGEventFlags(rawValue: UInt64(lua_tointeger(L, 2)))
        lua_pushvalue(L, 1)
    }
    return 1
}

private func eventtap_event_getFlags(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    lua_newtable(L)
    let flags = event.flags
    if flags.contains(.maskAlternate)  { lua_pushboolean(L, 1); lua_setfield(L, -2, "alt") }
    if flags.contains(.maskShift)      { lua_pushboolean(L, 1); lua_setfield(L, -2, "shift") }
    if flags.contains(.maskControl)    { lua_pushboolean(L, 1); lua_setfield(L, -2, "ctrl") }
    if flags.contains(.maskCommand)    { lua_pushboolean(L, 1); lua_setfield(L, -2, "cmd") }
    if flags.contains(.maskSecondaryFn) { lua_pushboolean(L, 1); lua_setfield(L, -2, "fn") }
    luaL_getmetatable(L, FLAGS_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func eventtap_event_setFlags(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    luaL_checktype(L, 2, LUA_TTABLE)
    var flags = CGEventFlags(rawValue: 0)
    lua_getfield(L, 2, "cmd");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskCommand) }
    lua_getfield(L, 2, "alt");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskAlternate) }
    lua_getfield(L, 2, "ctrl");  if lua_toboolean(L, -1) != 0 { flags.insert(.maskControl) }
    lua_getfield(L, 2, "shift"); if lua_toboolean(L, -1) != 0 { flags.insert(.maskShift) }
    lua_getfield(L, 2, "fn");    if lua_toboolean(L, -1) != 0 { flags.insert(.maskSecondaryFn) }
    event.flags = flags
    lua_settop(L, 1)
    return 1
}

private func eventtap_event_getRawEventData(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let cgType = event.type

    lua_newtable(L)

    // CGEventData
    lua_newtable(L)
    lua_pushinteger(L, event.getIntegerValueField(.keyboardEventKeycode)); lua_setfield(L, -2, "keycode")
    lua_pushinteger(L, lua_Integer(event.flags.rawValue));                lua_setfield(L, -2, "flags")
    lua_pushinteger(L, lua_Integer(cgType.rawValue));                     lua_setfield(L, -2, "type")
    lua_setfield(L, -2, "CGEventData")

    // NSEventData
    lua_newtable(L)
    if cgType != .tapDisabledByTimeout && cgType != .tapDisabledByUserInput {
        if let sysEvent = NSEvent(cgEvent: event) {
            let nsType = sysEvent.type
            lua_pushinteger(L, lua_Integer(sysEvent.modifierFlags.rawValue)); lua_setfield(L, -2, "modifierFlags")
            lua_pushinteger(L, lua_Integer(nsType.rawValue));                lua_setfield(L, -2, "type")
            lua_pushinteger(L, lua_Integer(sysEvent.windowNumber));          lua_setfield(L, -2, "windowNumber")

            if nsType == .keyDown || nsType == .keyUp {
                lua_pushstring(L, sysEvent.characters ?? "");                    lua_setfield(L, -2, "characters")
                lua_pushstring(L, sysEvent.charactersIgnoringModifiers ?? "");   lua_setfield(L, -2, "charactersIgnoringModifiers")
                lua_pushinteger(L, lua_Integer(sysEvent.keyCode));               lua_setfield(L, -2, "keyCode")
            }

            if nsType == .leftMouseDown || nsType == .leftMouseUp ||
               nsType == .rightMouseDown || nsType == .rightMouseUp ||
               nsType == .otherMouseDown || nsType == .otherMouseUp {
                lua_pushinteger(L, lua_Integer(sysEvent.buttonNumber)); lua_setfield(L, -2, "buttonNumber")
                lua_pushinteger(L, lua_Integer(sysEvent.clickCount));   lua_setfield(L, -2, "clickCount")
                lua_pushnumber(L, lua_Number(sysEvent.pressure));       lua_setfield(L, -2, "pressure")
            }

            if nsType == .appKitDefined || nsType == .systemDefined ||
               nsType == .applicationDefined || nsType == .periodic {
                lua_pushinteger(L, lua_Integer(sysEvent.data1));            lua_setfield(L, -2, "data1")
                lua_pushinteger(L, lua_Integer(sysEvent.data2));            lua_setfield(L, -2, "data2")
                lua_pushinteger(L, lua_Integer(sysEvent.subtype.rawValue)); lua_setfield(L, -2, "subtype")
            }
        }
    }
    lua_setfield(L, -2, "NSEventData")
    return 1
}

private func eventtap_event_getCharacters(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let clean = lua_isnone(L, 2) ? false : lua_toboolean(L, -1) != 0
    let cgType = event.type

    if cgType == .keyDown || cgType == .keyUp {
        if let nsEvent = NSEvent(cgEvent: event) {
            let str = clean ? nsEvent.charactersIgnoringModifiers : nsEvent.characters
            lua_pushstring(L, str ?? "")
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_getKeyCode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    lua_pushinteger(L, event.getIntegerValueField(.keyboardEventKeycode))
    return 1
}

private func eventtap_event_setKeyCode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let keycode = luaL_checkinteger(L, 2)
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keycode))
    lua_settop(L, 1)
    return 1
}

private func eventtap_event_getUnicodeString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TBREAK)
    let event = getEvent(L, 1)

    var actual: Int = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &actual, unicodeString: nil)
    var buffer = [UniChar](repeating: 0, count: actual)
    event.keyboardGetUnicodeString(maxStringLength: actual, actualStringLength: &actual, unicodeString: &buffer)
    let str = NSString(characters: buffer, length: actual)
    skin.pushNSObject(str)
    return 1
}

private func eventtap_event_setUnicodeString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let event = getEvent(L, 1)
    guard let theString = skin.toNSObject(atIndex: 2) as? NSString else {
        lua_settop(L, 1); return 1
    }

    var buffer = [UniChar](repeating: 0, count: theString.length)
    theString.getCharacters(&buffer, range: NSRange(location: 0, length: theString.length))

    event.flags = CGEventFlags(rawValue: 0)
    event.keyboardSetUnicodeString(stringLength: theString.length, unicodeString: &buffer)

    lua_settop(L, 1)
    return 1
}

private func eventtap_event_post(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L, 1)

    if luaL_testudata(L, 2, APPLICATION_USERDATA_TAG) != nil {
        if let app = skin.toNSObject(at: 2) as? HSapplicationProtocol {
            event.postToPid(app.pid)
        }
    } else {
        event.post(tap: .cgSessionEventTap)
    }
    usleep(1000)
    lua_settop(L, 1)
    return 1
}

private func eventtap_event_getType(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L, 1)
    let nsEvent = (lua_gettop(L) > 1) ? (lua_toboolean(L, 2) != 0) : false

    if nsEvent {
        if let cocoaEvent = NSEvent(cgEvent: event) {
            lua_pushinteger(L, lua_Integer(cocoaEvent.type.rawValue))
        } else {
            lua_pushinteger(L, lua_Integer(event.type.rawValue))
        }
    } else {
        lua_pushinteger(L, lua_Integer(event.type.rawValue))
    }
    return 1
}

private func eventtap_event_getProperty(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let field = CGEventField(rawValue: UInt32(luaL_checkinteger(L, 2)))!

    let doubleFields: Set<UInt32> = [
        CGEventField.mouseEventPressure.rawValue,
        CGEventField.scrollWheelEventFixedPtDeltaAxis1.rawValue,
        CGEventField.scrollWheelEventFixedPtDeltaAxis2.rawValue,
        CGEventField.scrollWheelEventFixedPtDeltaAxis3.rawValue,
        CGEventField.tabletEventPointPressure.rawValue,
        CGEventField.tabletEventTiltX.rawValue,
        CGEventField.tabletEventTiltY.rawValue,
        CGEventField.tabletEventRotation.rawValue,
        CGEventField.tabletEventTangentialPressure.rawValue,
    ]

    if doubleFields.contains(field.rawValue) {
        lua_pushnumber(L, event.getDoubleValueField(field))
    } else {
        lua_pushinteger(L, event.getIntegerValueField(field))
    }
    return 1
}

private func eventtap_event_getButtonState(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let whichButton = CGMouseButton(rawValue: UInt32(luaL_checkinteger(L, 2)))!
    let stateID = CGEventSourceStateID(rawValue: Int32(event.getIntegerValueField(.eventSourceStateID)))!
    lua_pushboolean(L, CGEventSource.buttonState(stateID, button: whichButton) ? 1 : 0)
    return 1
}

private func eventtap_event_setProperty(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let field = CGEventField(rawValue: UInt32(luaL_checkinteger(L, 2)))!

    let doubleFields: Set<UInt32> = [
        CGEventField.mouseEventPressure.rawValue,
        CGEventField.scrollWheelEventFixedPtDeltaAxis1.rawValue,
        CGEventField.scrollWheelEventFixedPtDeltaAxis2.rawValue,
        CGEventField.scrollWheelEventFixedPtDeltaAxis3.rawValue,
        CGEventField.tabletEventPointPressure.rawValue,
        CGEventField.tabletEventTiltX.rawValue,
        CGEventField.tabletEventTiltY.rawValue,
        CGEventField.tabletEventRotation.rawValue,
        CGEventField.tabletEventTangentialPressure.rawValue,
    ]

    if doubleFields.contains(field.rawValue) {
        event.setDoubleValueField(field, value: luaL_checknumber(L, 3))
    } else {
        event.setIntegerValueField(field, value: Int64(luaL_checkinteger(L, 2 + 1)))
    }
    lua_settop(L, 1)
    return 1
}

// MARK: - Key Event Constructors

private func eventtap_event_newKeyEvent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    var hasModTable = false
    var keyCodePos: Int32 = 2
    var flags = CGEventFlags(rawValue: 0)

    if lua_type(L, 1) == LUA_TTABLE {
        skin.checkArgs(LS_TTABLE, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
        flags = parseModsFromIterator(L, tableIndex: 1)
        hasModTable = true
    } else if lua_type(L, 1) == LUA_TNIL {
        skin.checkArgs(LS_TNIL, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    } else {
        skin.checkArgs(LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
        keyCodePos = 1
    }

    let isDown = lua_toboolean(L, keyCodePos + 1) != 0
    let keyCode = CGKeyCode(lua_tointeger(L, keyCodePos))

    guard let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown) else {
        lua_pushnil(L); return 1
    }
    if hasModTable { keyEvent.flags = flags }
    newEventtapEvent(L, keyEvent)
    return 1
}

private func eventtap_event_newSystemKeyEvent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBOOLEAN, LS_TBREAK)

    guard let keyName = lua_tostring(L, 1).map({ String(cString: $0) }) else {
        lua_pushnil(L); return 1
    }
    let isDown = lua_toboolean(L, 2) != 0

    let keyMap: [String: Int32] = [
        "SOUND_UP":            Int32(NX_KEYTYPE_SOUND_UP),
        "SOUND_DOWN":          Int32(NX_KEYTYPE_SOUND_DOWN),
        "POWER":               Int32(NX_POWER_KEY),
        "MUTE":                Int32(NX_KEYTYPE_MUTE),
        "BRIGHTNESS_UP":       Int32(NX_KEYTYPE_BRIGHTNESS_UP),
        "BRIGHTNESS_DOWN":     Int32(NX_KEYTYPE_BRIGHTNESS_DOWN),
        "CONTRAST_UP":         Int32(NX_KEYTYPE_CONTRAST_UP),
        "CONTRAST_DOWN":       Int32(NX_KEYTYPE_CONTRAST_DOWN),
        "LAUNCH_PANEL":        Int32(NX_KEYTYPE_LAUNCH_PANEL),
        "EJECT":               Int32(NX_KEYTYPE_EJECT),
        "VIDMIRROR":           Int32(NX_KEYTYPE_VIDMIRROR),
        "PLAY":                Int32(NX_KEYTYPE_PLAY),
        "NEXT":                Int32(NX_KEYTYPE_NEXT),
        "PREVIOUS":            Int32(NX_KEYTYPE_PREVIOUS),
        "FAST":                Int32(NX_KEYTYPE_FAST),
        "REWIND":              Int32(NX_KEYTYPE_REWIND),
        "ILLUMINATION_UP":     Int32(NX_KEYTYPE_ILLUMINATION_UP),
        "ILLUMINATION_DOWN":   Int32(NX_KEYTYPE_ILLUMINATION_DOWN),
        "ILLUMINATION_TOGGLE": Int32(NX_KEYTYPE_ILLUMINATION_TOGGLE),
        "CAPS_LOCK":           Int32(NX_KEYTYPE_CAPS_LOCK),
        "HELP":                Int32(NX_KEYTYPE_HELP),
        "NUM_LOCK":            Int32(NX_KEYTYPE_NUM_LOCK),
    ]

    guard let keyVal = keyMap[keyName] else {
        skin.logError("Unknown system key for hs.eventtap.event.newSystemKeyEvent(): \(keyName)")
        lua_pushnil(L); return 1
    }

    let flagVal: NSEvent.ModifierFlags = isDown ? .init(rawValue: UInt(NX_KEYDOWN)) : .init(rawValue: UInt(NX_KEYUP))
    let data1val = (Int(keyVal) << 16) | ((isDown ? Int(NX_KEYDOWN) : Int(NX_KEYUP)) << 8)

    guard let keyEvent = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flagVal,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        data1: data1val,
        data2: -1
    ), let cgEvent = keyEvent.cgEvent else {
        lua_pushnil(L); return 1
    }
    newEventtapEvent(L, cgEvent)
    return 1
}

private func eventtap_event_newScrollWheelEvent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TTABLE)
    lua_pushnumber(L, 1); lua_gettable(L, 1); let offsetY = Int32(lua_tointeger(L, -1)); lua_pop(L, 1)
    lua_pushnumber(L, 2); lua_gettable(L, 1); let offsetX = Int32(lua_tointeger(L, -1)); lua_pop(L, 1)

    luaL_checktype(L, 2, LUA_TTABLE)
    let flags = parseModsFromIterator(L, tableIndex: 2)

    let unitStr = lua_tostring(L, 3).map({ String(cString: $0) })
    let unit: CGScrollEventUnit = (unitStr == "pixel") ? .pixel : .line

    guard let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: unit, wheelCount: 2, wheel1: offsetX, wheel2: offsetY, wheel3: 0) else {
        lua_pushnil(L); return 1
    }
    scrollEvent.flags = flags
    newEventtapEvent(L, scrollEvent)
    return 1
}

private func eventtap_event_newMouseEvent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let type = CGEventType(rawValue: UInt32(luaL_checkinteger(L, 1)))!
    let point = hsToPoint(L, 2)
    guard let buttonString = lua_tostring(L, 3).map({ String(cString: $0) }) else {
        lua_pushnil(L); return 1
    }

    var button: CGMouseButton = .left
    switch buttonString {
    case "right": button = .right
    case "other": button = .center
    case "none":  button = CGMouseButton(rawValue: 0)!
    default: break
    }

    var flags = CGEventFlags(rawValue: 0)
    if !lua_isnoneornil(L, 4) && lua_type(L, 4) == LUA_TTABLE {
        flags = parseModsFromIterator(L, tableIndex: 4)
    }

    guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        lua_pushnil(L); return 1
    }
    event.flags = flags
    newEventtapEvent(L, event)
    return 1
}

// MARK: - System Key / Touches

private func eventtap_event_systemKey(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    guard let sysEvent = NSEvent(cgEvent: event) else {
        lua_newtable(L); return 1
    }
    let nsType = sysEvent.type

    lua_newtable(L)
    if nsType == .appKitDefined || nsType == .systemDefined ||
       nsType == .applicationDefined || nsType == .periodic {
        let data1 = sysEvent.data1
        if sysEvent.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) {
            let keyCode = (Int(data1) & 0xFFFF0000) >> 16
            let keyFlags = Int(data1) & 0xFFFF

            let keyName: String
            switch Int32(keyCode) {
            case Int32(NX_KEYTYPE_SOUND_UP):            keyName = "SOUND_UP"
            case Int32(NX_KEYTYPE_SOUND_DOWN):          keyName = "SOUND_DOWN"
            case Int32(NX_POWER_KEY):                   keyName = "POWER"
            case Int32(NX_KEYTYPE_MUTE):                keyName = "MUTE"
            case Int32(NX_KEYTYPE_BRIGHTNESS_UP):       keyName = "BRIGHTNESS_UP"
            case Int32(NX_KEYTYPE_BRIGHTNESS_DOWN):     keyName = "BRIGHTNESS_DOWN"
            case Int32(NX_KEYTYPE_CONTRAST_UP):         keyName = "CONTRAST_UP"
            case Int32(NX_KEYTYPE_CONTRAST_DOWN):       keyName = "CONTRAST_DOWN"
            case Int32(NX_KEYTYPE_LAUNCH_PANEL):        keyName = "LAUNCH_PANEL"
            case Int32(NX_KEYTYPE_EJECT):               keyName = "EJECT"
            case Int32(NX_KEYTYPE_VIDMIRROR):           keyName = "VIDMIRROR"
            case Int32(NX_KEYTYPE_PLAY):                keyName = "PLAY"
            case Int32(NX_KEYTYPE_NEXT):                keyName = "NEXT"
            case Int32(NX_KEYTYPE_PREVIOUS):            keyName = "PREVIOUS"
            case Int32(NX_KEYTYPE_FAST):                keyName = "FAST"
            case Int32(NX_KEYTYPE_REWIND):              keyName = "REWIND"
            case Int32(NX_KEYTYPE_ILLUMINATION_UP):     keyName = "ILLUMINATION_UP"
            case Int32(NX_KEYTYPE_ILLUMINATION_DOWN):   keyName = "ILLUMINATION_DOWN"
            case Int32(NX_KEYTYPE_ILLUMINATION_TOGGLE): keyName = "ILLUMINATION_TOGGLE"
            case Int32(NX_KEYTYPE_CAPS_LOCK):           keyName = "CAPS_LOCK"
            case Int32(NX_KEYTYPE_HELP):                keyName = "HELP"
            case Int32(NX_KEYTYPE_NUM_LOCK):            keyName = "NUM_LOCK"
            default:                                    keyName = "undefined"
            }

            lua_pushstring(L, keyName);                                          lua_setfield(L, -2, "key")
            lua_pushinteger(L, lua_Integer(keyCode));                            lua_setfield(L, -2, "keyCode")
            lua_pushboolean(L, ((keyFlags & 0xFF00) >> 8) == 0x0a ? 1 : 0);     lua_setfield(L, -2, "down")
            lua_pushboolean(L, (keyFlags & 0x1) > 0 ? 1 : 0);                  lua_setfield(L, -2, "repeat")
        }
    }
    return 1
}

private func eventtap_event_getTouches(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TBREAK)
    let event = getEvent(L, 1)

    if CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) == event.type {
        if let nsEvent = NSEvent(cgEvent: event) {
            let touches = nsEvent.allTouches()
            skin.pushNSObject(touches as NSSet)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_getTouchDetails(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, EVENTTAP_EVENT_USERDATA_TAG, LS_TBREAK)
    let event = getEvent(L, 1)

    let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))
    if event.type == gestureType {
        guard let nsEvent = NSEvent(cgEvent: event) else { lua_pushnil(L); return 1 }
        let nsType = nsEvent.type

        lua_newtable(L)

        if nsType == .pressure {
            lua_pushnumber(L, lua_Number(nsEvent.pressure));         lua_setfield(L, -2, "pressure")
            lua_pushinteger(L, lua_Integer(nsEvent.stage));          lua_setfield(L, -2, "stage")
            lua_pushnumber(L, lua_Number(nsEvent.stageTransition));  lua_setfield(L, -2, "stageTransition")
            let behavior = nsEvent.pressureBehavior
            let behaviorStr: String
            switch behavior {
            case .unknown:            behaviorStr = "unknown"
            case .primaryDefault:     behaviorStr = "default"
            case .primaryClick:       behaviorStr = "click"
            case .primaryGeneric:     behaviorStr = "generic"
            case .primaryAccelerator: behaviorStr = "accelerator"
            case .primaryDeepClick:   behaviorStr = "deepClick"
            case .primaryDeepDrag:    behaviorStr = "deepDrag"
            default:                  behaviorStr = "** unrecognized pressureBehavior: \(behavior.rawValue)"
            }
            lua_pushstring(L, behaviorStr); lua_setfield(L, -2, "pressureBehavior")
        }

        if nsType == .magnify {
            lua_pushnumber(L, nsEvent.magnification); lua_setfield(L, -2, "magnification")
        }

        if nsType == .rotate {
            lua_pushnumber(L, lua_Number(nsEvent.rotation)); lua_setfield(L, -2, "rotation")
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Lookup Tables

private func pushTypesTable(_ L: UnsafeMutablePointer<lua_State>!) {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(CGEventType.null.rawValue));              lua_setfield(L, -2, "nullEvent")
    lua_pushinteger(L, lua_Integer(CGEventType.leftMouseDown.rawValue));     lua_setfield(L, -2, "leftMouseDown")
    lua_pushinteger(L, lua_Integer(CGEventType.leftMouseUp.rawValue));       lua_setfield(L, -2, "leftMouseUp")
    lua_pushinteger(L, lua_Integer(CGEventType.leftMouseDragged.rawValue));  lua_setfield(L, -2, "leftMouseDragged")
    lua_pushinteger(L, lua_Integer(CGEventType.rightMouseDown.rawValue));    lua_setfield(L, -2, "rightMouseDown")
    lua_pushinteger(L, lua_Integer(CGEventType.rightMouseUp.rawValue));      lua_setfield(L, -2, "rightMouseUp")
    lua_pushinteger(L, lua_Integer(CGEventType.rightMouseDragged.rawValue)); lua_setfield(L, -2, "rightMouseDragged")
    lua_pushinteger(L, lua_Integer(CGEventType.otherMouseDown.rawValue));    lua_setfield(L, -2, "otherMouseDown")
    lua_pushinteger(L, lua_Integer(CGEventType.otherMouseUp.rawValue));      lua_setfield(L, -2, "otherMouseUp")
    lua_pushinteger(L, lua_Integer(CGEventType.otherMouseDragged.rawValue)); lua_setfield(L, -2, "otherMouseDragged")
    lua_pushinteger(L, lua_Integer(CGEventType.mouseMoved.rawValue));        lua_setfield(L, -2, "mouseMoved")
    lua_pushinteger(L, lua_Integer(CGEventType.keyDown.rawValue));           lua_setfield(L, -2, "keyDown")
    lua_pushinteger(L, lua_Integer(CGEventType.keyUp.rawValue));             lua_setfield(L, -2, "keyUp")
    lua_pushinteger(L, lua_Integer(CGEventType.flagsChanged.rawValue));      lua_setfield(L, -2, "flagsChanged")
    lua_pushinteger(L, lua_Integer(CGEventType.scrollWheel.rawValue));       lua_setfield(L, -2, "scrollWheel")
    lua_pushinteger(L, lua_Integer(CGEventType.tabletPointer.rawValue));     lua_setfield(L, -2, "tabletPointer")
    lua_pushinteger(L, lua_Integer(CGEventType.tabletProximity.rawValue));   lua_setfield(L, -2, "tabletProximity")

    lua_pushinteger(L, lua_Integer(NSEvent.EventType.mouseEntered.rawValue));       lua_setfield(L, -2, "mouseEntered")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.mouseExited.rawValue));        lua_setfield(L, -2, "mouseExited")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.cursorUpdate.rawValue));       lua_setfield(L, -2, "cursorUpdate")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.periodic.rawValue));           lua_setfield(L, -2, "periodic")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.appKitDefined.rawValue));      lua_setfield(L, -2, "appKitDefined")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.systemDefined.rawValue));      lua_setfield(L, -2, "systemDefined")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.applicationDefined.rawValue)); lua_setfield(L, -2, "applicationDefined")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.quickLook.rawValue));          lua_setfield(L, -2, "quickLook")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.gesture.rawValue));            lua_setfield(L, -2, "gesture")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.magnify.rawValue));            lua_setfield(L, -2, "magnify")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.swipe.rawValue));              lua_setfield(L, -2, "swipe")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.rotate.rawValue));             lua_setfield(L, -2, "rotate")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.smartMagnify.rawValue));       lua_setfield(L, -2, "smartMagnify")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.pressure.rawValue));           lua_setfield(L, -2, "pressure")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.directTouch.rawValue));        lua_setfield(L, -2, "directTouch")
    lua_pushinteger(L, lua_Integer(NSEvent.EventType.changeMode.rawValue));         lua_setfield(L, -2, "changeMode")
}

private func pushPropertiesTable(_ L: UnsafeMutablePointer<lua_State>!) {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventNumber.rawValue));                                         lua_setfield(L, -2, "mouseEventNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventClickState.rawValue));                                     lua_setfield(L, -2, "mouseEventClickState")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventPressure.rawValue));                                       lua_setfield(L, -2, "mouseEventPressure")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventButtonNumber.rawValue));                                   lua_setfield(L, -2, "mouseEventButtonNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventDeltaX.rawValue));                                         lua_setfield(L, -2, "mouseEventDeltaX")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventDeltaY.rawValue));                                         lua_setfield(L, -2, "mouseEventDeltaY")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventInstantMouser.rawValue));                                  lua_setfield(L, -2, "mouseEventInstantMouser")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventSubtype.rawValue));                                        lua_setfield(L, -2, "mouseEventSubtype")
    lua_pushinteger(L, lua_Integer(CGEventField.keyboardEventAutorepeat.rawValue));                                  lua_setfield(L, -2, "keyboardEventAutorepeat")
    lua_pushinteger(L, lua_Integer(CGEventField.keyboardEventKeycode.rawValue));                                     lua_setfield(L, -2, "keyboardEventKeycode")
    lua_pushinteger(L, lua_Integer(CGEventField.keyboardEventKeyboardType.rawValue));                                lua_setfield(L, -2, "keyboardEventKeyboardType")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventDeltaAxis1.rawValue));                               lua_setfield(L, -2, "scrollWheelEventDeltaAxis1")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventDeltaAxis2.rawValue));                               lua_setfield(L, -2, "scrollWheelEventDeltaAxis2")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventDeltaAxis3.rawValue));                               lua_setfield(L, -2, "scrollWheelEventDeltaAxis3")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis1.rawValue));                        lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis1")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis2.rawValue));                        lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis2")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis3.rawValue));                        lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis3")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis1.rawValue));                          lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis1")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis2.rawValue));                          lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis2")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis3.rawValue));                          lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis3")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventInstantMouser.rawValue));                            lua_setfield(L, -2, "scrollWheelEventInstantMouser")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointX.rawValue));                                        lua_setfield(L, -2, "tabletEventPointX")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointY.rawValue));                                        lua_setfield(L, -2, "tabletEventPointY")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointZ.rawValue));                                        lua_setfield(L, -2, "tabletEventPointZ")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointButtons.rawValue));                                  lua_setfield(L, -2, "tabletEventPointButtons")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointPressure.rawValue));                                 lua_setfield(L, -2, "tabletEventPointPressure")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventTiltX.rawValue));                                         lua_setfield(L, -2, "tabletEventTiltX")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventTiltY.rawValue));                                         lua_setfield(L, -2, "tabletEventTiltY")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventRotation.rawValue));                                      lua_setfield(L, -2, "tabletEventRotation")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventTangentialPressure.rawValue));                            lua_setfield(L, -2, "tabletEventTangentialPressure")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventDeviceID.rawValue));                                      lua_setfield(L, -2, "tabletEventDeviceID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventVendor1.rawValue));                                       lua_setfield(L, -2, "tabletEventVendor1")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventVendor2.rawValue));                                       lua_setfield(L, -2, "tabletEventVendor2")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventVendor3.rawValue));                                       lua_setfield(L, -2, "tabletEventVendor3")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorID.rawValue));                             lua_setfield(L, -2, "tabletProximityEventVendorID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventTabletID.rawValue));                             lua_setfield(L, -2, "tabletProximityEventTabletID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventPointerID.rawValue));                            lua_setfield(L, -2, "tabletProximityEventPointerID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventDeviceID.rawValue));                             lua_setfield(L, -2, "tabletProximityEventDeviceID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventSystemTabletID.rawValue));                       lua_setfield(L, -2, "tabletProximityEventSystemTabletID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorPointerType.rawValue));                    lua_setfield(L, -2, "tabletProximityEventVendorPointerType")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorPointerSerialNumber.rawValue));            lua_setfield(L, -2, "tabletProximityEventVendorPointerSerialNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorUniqueID.rawValue));                       lua_setfield(L, -2, "tabletProximityEventVendorUniqueID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventCapabilityMask.rawValue));                       lua_setfield(L, -2, "tabletProximityEventCapabilityMask")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventPointerType.rawValue));                          lua_setfield(L, -2, "tabletProximityEventPointerType")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventEnterProximity.rawValue));                       lua_setfield(L, -2, "tabletProximityEventEnterProximity")
    lua_pushinteger(L, lua_Integer(CGEventField.eventTargetProcessSerialNumber.rawValue));                           lua_setfield(L, -2, "eventTargetProcessSerialNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.eventTargetUnixProcessID.rawValue));                                 lua_setfield(L, -2, "eventTargetUnixProcessID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceUnixProcessID.rawValue));                                 lua_setfield(L, -2, "eventSourceUnixProcessID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceUserData.rawValue));                                      lua_setfield(L, -2, "eventSourceUserData")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceUserID.rawValue));                                        lua_setfield(L, -2, "eventSourceUserID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceGroupID.rawValue));                                       lua_setfield(L, -2, "eventSourceGroupID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceStateID.rawValue));                                       lua_setfield(L, -2, "eventSourceStateID")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventIsContinuous.rawValue));                             lua_setfield(L, -2, "scrollWheelEventIsContinuous")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventScrollPhase.rawValue));                              lua_setfield(L, -2, "scrollWheelEventScrollPhase")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventScrollCount.rawValue));                              lua_setfield(L, -2, "scrollWheelEventScrollCount")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventMomentumPhase.rawValue));                            lua_setfield(L, -2, "scrollWheelEventMomentumPhase")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventWindowUnderMousePointer.rawValue));                        lua_setfield(L, -2, "mouseEventWindowUnderMousePointer")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventWindowUnderMousePointerThatCanHandleThisEvent.rawValue));  lua_setfield(L, -2, "mouseEventWindowUnderMousePointerThatCanHandleThisEvent")
    lua_pushinteger(L, lua_Integer(CGEventField.eventUnacceleratedPointerMovementX.rawValue));                       lua_setfield(L, -2, "eventUnacceleratedPointerMovementX")
    lua_pushinteger(L, lua_Integer(CGEventField.eventUnacceleratedPointerMovementY.rawValue));                       lua_setfield(L, -2, "eventUnacceleratedPointerMovementY")
}

private func pushFlagMasks(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NX_ALPHASHIFTMASK));                   lua_setfield(L, -2, "alphaShift")
    lua_pushinteger(L, lua_Integer(NX_SHIFTMASK));                        lua_setfield(L, -2, "shift")
    lua_pushinteger(L, lua_Integer(NX_CONTROLMASK));                      lua_setfield(L, -2, "control")
    lua_pushinteger(L, lua_Integer(NX_ALTERNATEMASK));                    lua_setfield(L, -2, "alternate")
    lua_pushinteger(L, lua_Integer(NX_COMMANDMASK));                      lua_setfield(L, -2, "command")
    lua_pushinteger(L, lua_Integer(NX_NUMERICPADMASK));                   lua_setfield(L, -2, "numericPad")
    lua_pushinteger(L, lua_Integer(NX_HELPMASK));                         lua_setfield(L, -2, "help")
    lua_pushinteger(L, lua_Integer(NX_SECONDARYFNMASK));                  lua_setfield(L, -2, "secondaryFn")
    lua_pushinteger(L, lua_Integer(NX_DEVICELCTLKEYMASK));                lua_setfield(L, -2, "deviceLeftControl")
    lua_pushinteger(L, lua_Integer(NX_DEVICERCTLKEYMASK));                lua_setfield(L, -2, "deviceRightControl")
    lua_pushinteger(L, lua_Integer(NX_DEVICELSHIFTKEYMASK));              lua_setfield(L, -2, "deviceLeftShift")
    lua_pushinteger(L, lua_Integer(NX_DEVICERSHIFTKEYMASK));              lua_setfield(L, -2, "deviceRightShift")
    lua_pushinteger(L, lua_Integer(NX_DEVICELCMDKEYMASK));                lua_setfield(L, -2, "deviceLeftCommand")
    lua_pushinteger(L, lua_Integer(NX_DEVICERCMDKEYMASK));                lua_setfield(L, -2, "deviceRightCommand")
    lua_pushinteger(L, lua_Integer(NX_DEVICELALTKEYMASK));                lua_setfield(L, -2, "deviceLeftAlternate")
    lua_pushinteger(L, lua_Integer(NX_DEVICERALTKEYMASK));                lua_setfield(L, -2, "deviceRightAlternate")
    lua_pushinteger(L, lua_Integer(NX_ALPHASHIFT_STATELESS_MASK));        lua_setfield(L, -2, "alphaShiftStateless")
    lua_pushinteger(L, lua_Integer(NX_DEVICE_ALPHASHIFT_STATELESS_MASK)); lua_setfield(L, -2, "deviceAlphaShiftStateless")
    lua_pushinteger(L, lua_Integer(NX_NONCOALSESCEDMASK));                lua_setfield(L, -2, "nonCoalesced")
    return 1
}

// MARK: - Flags metatable helpers

private func flags_contain(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let eventFlags = parseFlagsFromTable(L, 1)
    let flags = parseFlagsFromArray(L, 2)
    lua_pushboolean(L, eventFlags.contains(flags) ? 1 : 0)
    return 1
}

private func flags_containExactly(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let eventFlags = parseFlagsFromTable(L, 1)
    let flags = parseFlagsFromArray(L, 2)
    lua_pushboolean(L, eventFlags == flags ? 1 : 0)
    return 1
}

// MARK: - __tostring / meta_gc

private func event_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let event = getEvent(L, 1)
    let eventType = event.type.rawValue
    let ptr = lua_topointer(L, 1)!
    lua_pushstring(L, "\(EVENTTAP_EVENT_USERDATA_TAG): Event type: \(eventType) (\(ptr))")
    return 1
}

private func event_meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let src = eventSource {
        eventSource = nil
        _ = src // ARC releases
    }
    return 0
}

// MARK: - NSTouch -> Lua helper

private func pushNSTouch(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)

    switch touch.type {
    case .direct:   lua_pushstring(L, "direct")
    case .indirect: lua_pushstring(L, "indirect")
    @unknown default: lua_pushstring(L, "** unrecognized type: \(touch.type.rawValue)")
    }
    lua_setfield(L, -2, "type")

    lua_pushstring(L, "\(Unmanaged.passUnretained(touch.identity as AnyObject).toOpaque())")
    lua_setfield(L, -2, "identity")

    switch touch.phase {
    case .began:      lua_pushstring(L, "began")
    case .moved:      lua_pushstring(L, "moved")
    case .stationary: lua_pushstring(L, "stationary")
    case .ended:      lua_pushstring(L, "ended")
    case .cancelled:  lua_pushstring(L, "cancelled")
    default:          lua_pushnil(L)
    }
    lua_setfield(L, -2, "phase")

    lua_pushboolean(L, touch.phase.contains(.touching) ? 1 : 0)
    lua_setfield(L, -2, "touching")

    if touch.type == .indirect {
        skin.pushNSPoint(touch.normalizedPosition)
        lua_setfield(L, -2, "normalizedPosition")
        // Private API: previousNormalizedPosition
        if touch.responds(to: Selector(("previousNormalizedPosition"))) {
            let prevPos = touch.perform(Selector(("previousNormalizedPosition")))!.takeUnretainedValue()
            // NSPoint is a struct, so use value(of:) for the point
            if let point = prevPos as? NSValue {
                skin.pushNSPoint(point.pointValue)
            } else {
                skin.pushNSPoint(.zero)
            }
            lua_setfield(L, -2, "previousNormalizedPosition")
        }
    } else {
        skin.pushNSPoint(touch.location(in: nil))
        lua_setfield(L, -2, "location")
        skin.pushNSPoint(touch.previousLocation(in: nil))
        lua_setfield(L, -2, "previousLocation")
    }

    // Private API: timestamp
    if touch.responds(to: Selector(("timestamp"))) {
        let ts = touch.perform(Selector(("timestamp")))
        lua_pushnumber(L, lua_Number(bitPattern: UInt64(Int(bitPattern: ts?.toOpaque()))))
    } else {
        lua_pushnumber(L, 0)
    }
    lua_setfield(L, -2, "timestamp")

    // Private API: _force
    if touch.responds(to: Selector(("_force"))) {
        let f = touch.perform(Selector(("_force")))
        lua_pushnumber(L, lua_Number(bitPattern: UInt64(Int(bitPattern: f?.toOpaque()))))
    } else {
        lua_pushnumber(L, 0)
    }
    lua_setfield(L, -2, "force")

    lua_pushboolean(L, touch.isResting ? 1 : 0)
    lua_setfield(L, -2, "resting")

    lua_pushstring(L, "\(Unmanaged.passUnretained(touch.device as AnyObject).toOpaque())")
    lua_setfield(L, -2, "device")

    skin.pushNSSize(touch.deviceSize)
    lua_setfield(L, -2, "deviceSize")
}

// MARK: - Registration Tables

private let eventtapevent_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("asData"),          func: eventtap_event_asData),
    luaL_Reg(name: strdup("location"),        func: eventtap_event_location),
    luaL_Reg(name: strdup("rawFlags"),        func: eventtap_event_rawFlags),
    luaL_Reg(name: strdup("timestamp"),       func: eventtap_event_timestamp),
    luaL_Reg(name: strdup("setType"),         func: eventtap_event_setType),
    luaL_Reg(name: strdup("copy"),            func: eventtap_event_copy),
    luaL_Reg(name: strdup("getFlags"),        func: eventtap_event_getFlags),
    luaL_Reg(name: strdup("setFlags"),        func: eventtap_event_setFlags),
    luaL_Reg(name: strdup("getKeyCode"),      func: eventtap_event_getKeyCode),
    luaL_Reg(name: strdup("setKeyCode"),      func: eventtap_event_setKeyCode),
    luaL_Reg(name: strdup("getUnicodeString"), func: eventtap_event_getUnicodeString),
    luaL_Reg(name: strdup("setUnicodeString"), func: eventtap_event_setUnicodeString),
    luaL_Reg(name: strdup("getType"),         func: eventtap_event_getType),
    luaL_Reg(name: strdup("getTouches"),      func: eventtap_event_getTouches),
    luaL_Reg(name: strdup("getTouchDetails"), func: eventtap_event_getTouchDetails),
    luaL_Reg(name: strdup("post"),            func: eventtap_event_post),
    luaL_Reg(name: strdup("getProperty"),     func: eventtap_event_getProperty),
    luaL_Reg(name: strdup("setProperty"),     func: eventtap_event_setProperty),
    luaL_Reg(name: strdup("getButtonState"),  func: eventtap_event_getButtonState),
    luaL_Reg(name: strdup("getRawEventData"), func: eventtap_event_getRawEventData),
    luaL_Reg(name: strdup("getCharacters"),   func: eventtap_event_getCharacters),
    luaL_Reg(name: strdup("systemKey"),       func: eventtap_event_systemKey),
    luaL_Reg(name: strdup("__tostring"),      func: event_userdata_tostring),
    luaL_Reg(name: strdup("__gc"),            func: eventtap_event_gc),
    luaL_Reg(name: nil, func: nil),
]

private let eventtapeventlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("newGesture"),        func: eventtap_event_newGesture),
    luaL_Reg(name: strdup("newEvent"),          func: eventtap_event_newEvent),
    luaL_Reg(name: strdup("newEventFromData"),  func: eventtap_event_newEventFromData),
    luaL_Reg(name: strdup("newKeyEvent"),       func: eventtap_event_newKeyEvent),
    luaL_Reg(name: strdup("newSystemKeyEvent"), func: eventtap_event_newSystemKeyEvent),
    luaL_Reg(name: strdup("_newMouseEvent"),    func: eventtap_event_newMouseEvent),
    luaL_Reg(name: strdup("newScrollEvent"),    func: eventtap_event_newScrollWheelEvent),
    luaL_Reg(name: nil, func: nil),
]

private let meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: event_meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Entry Point

@_cdecl("luaopen_hs_libeventtapevent")
public func luaopen_hs_libeventtapevent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary(withObject: EVENTTAP_EVENT_USERDATA_TAG,
                         functions: eventtapeventlib,
                         metaFunctions: meta_gcLib,
                         objectFunctions: eventtapevent_metalib)

    pushTypesTable(L)
    lua_setfield(L, -2, "types")

    pushPropertiesTable(L)
    lua_setfield(L, -2, "properties")

    _ = pushFlagMasks(L)
    lua_setfield(L, -2, "rawFlagMasks")

    eventSource = CGEventSource(stateID: .privateState)

    luaL_newmetatable(L, FLAGS_TAG)
    lua_newtable(L)
    lua_pushcfunction(L, flags_contain)
    lua_setfield(L, -2, "contain")
    lua_pushcfunction(L, flags_containExactly)
    lua_setfield(L, -2, "containExactly")
    lua_setfield(L, -2, "__index")
    lua_pop(L, 1)

    // Register NSTouch -> Lua converter
    skin.registerPushNSHelper({ L, obj in
        guard let touch = obj as? NSTouch else { return 0 }
        pushNSTouch(L, touch)
        return 1
    }, forClass: "NSTouch")

    return 1
}
