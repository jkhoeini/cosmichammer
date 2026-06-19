import Cocoa
import CLua
import Lua
import Carbon
import HSDSTCore
import os.log
import IOKit
import IOKit.hidsystem

// MARK: - Private Constants

private let FLAGS_TAG = "hs.eventtap.event.flags"
private let APPLICATION_USERDATA_TAG = "hs.application"

// Event source (module-level, like the ObjC static)
private var eventSource: CGEventSource? = nil

// MARK: - Helpers

private func getEvent(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> CGEvent {
    precondition(L != nil, "lua_State must not be nil")
    let ptr = luaL_checkudata(L, idx, EVENTTAP_EVENT_USERDATA_TAG)!
    return Unmanaged<CGEvent>.fromOpaque(
        ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()
}

private func parseFlagsFromTable(_ L: UnsafeMutablePointer<lua_State>!, _ arg: Int32) -> CGEventFlags {
    precondition(L != nil, "lua_State must not be nil")
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
            os_log(.debug, "%{public}s", "unexpected entry in modifiers table: \(lua_type(L, -1))")
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
    precondition(L != nil, "lua_State must not be nil")
    luaL_checktype(L, idx, LUA_TTABLE)
    lua_getfield(L, idx, "x"); let x = CGFloat(luaL_checknumber(L, -1))
    lua_getfield(L, idx, "y"); let y = CGFloat(luaL_checknumber(L, -1))
    lua_pop(L, 2)
    return CGPoint(x: x, y: y)
}

// MARK: - GC

private func eventtap_event_gc(_ L: LuaState) throws -> CInt {
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

private func eventtap_event_copy(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    guard let copy = event.copy() else { lua_pushnil(L); return 1 }
    newEventtapEvent(L, copy)
    return 1
}

private func eventtap_event_newEvent(_ L: LuaState) throws -> CInt {
    guard let event = CGEvent(source: eventSource) else { lua_pushnil(L); return 1 }
    newEventtapEvent(L, event)
    return 1
}

private func eventtap_event_newEventFromData(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let data = lua_checkdata(L, at: 1)
    if let event = CGEvent(withDataAllocator: nil, data: data as CFData) {
        newEventtapEvent(L, event)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_newGesture(_ L: LuaState) throws -> CInt {
    throw LuaCallError("hs.eventtap.event: gesture synthesis is not implemented in this version")
}

// MARK: - Methods

private func eventtap_event_asData(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    if let data = event.data {
        lua_pushany(L, data as NSData)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_location(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    if lua_gettop(L) == 1 {
        let loc = event.location
        lua_pushNSPoint(L, NSPoint(x: loc.x, y: loc.y))
    } else {
        let point = lua_tableToPoint(L, at: 2)
        event.location = CGPoint(x: point.x, y: point.y)
        lua_pushvalue(L, 1)
    }
    return 1
}

private func eventtap_event_timestamp(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    if lua_gettop(L) == 1 {
        L.push(lua_Integer(event.timestamp))
    } else {
        event.timestamp = CGEventTimestamp(lua_tointeger(L, 2))
        lua_pushvalue(L, 1)
    }
    return 1
}

private func eventtap_event_setType(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    event.type = CGEventType(rawValue: UInt32(lua_tointeger(L, 2)))!
    lua_pushvalue(L, 1)
    return 1
}

private func eventtap_event_rawFlags(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    if lua_gettop(L) == 1 {
        L.push(lua_Integer(event.flags.rawValue))
    } else {
        event.flags = CGEventFlags(rawValue: UInt64(lua_tointeger(L, 2)))
        lua_pushvalue(L, 1)
    }
    return 1
}

private func eventtap_event_getFlags(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    lua_newtable(L)
    let flags = event.flags
    if flags.contains(.maskAlternate)  { L.push(true); lua_setfield(L, -2, "alt") }
    if flags.contains(.maskShift)      { L.push(true); lua_setfield(L, -2, "shift") }
    if flags.contains(.maskControl)    { L.push(true); lua_setfield(L, -2, "ctrl") }
    if flags.contains(.maskCommand)    { L.push(true); lua_setfield(L, -2, "cmd") }
    if flags.contains(.maskSecondaryFn) { L.push(true); lua_setfield(L, -2, "fn") }
    luaL_getmetatable(L, FLAGS_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func eventtap_event_setFlags(_ L: LuaState) throws -> CInt {
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

private func eventtap_event_getRawEventData(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    let cgType = event.type

    lua_newtable(L)

    // CGEventData
    lua_newtable(L)
    L.push(event.getIntegerValueField(.keyboardEventKeycode)); lua_setfield(L, -2, "keycode")
    L.push(lua_Integer(event.flags.rawValue));                lua_setfield(L, -2, "flags")
    L.push(lua_Integer(cgType.rawValue));                     lua_setfield(L, -2, "type")
    lua_setfield(L, -2, "CGEventData")

    // NSEventData
    lua_newtable(L)
    if cgType != .tapDisabledByTimeout && cgType != .tapDisabledByUserInput {
        if let sysEvent = NSEvent(cgEvent: event) {
            let nsType = sysEvent.type
            L.push(lua_Integer(sysEvent.modifierFlags.rawValue)); lua_setfield(L, -2, "modifierFlags")
            L.push(lua_Integer(nsType.rawValue));                lua_setfield(L, -2, "type")
            L.push(lua_Integer(sysEvent.windowNumber));          lua_setfield(L, -2, "windowNumber")

            if nsType == .keyDown || nsType == .keyUp {
                L.push(sysEvent.characters ?? "");                    lua_setfield(L, -2, "characters")
                L.push(sysEvent.charactersIgnoringModifiers ?? "");   lua_setfield(L, -2, "charactersIgnoringModifiers")
                L.push(lua_Integer(sysEvent.keyCode));               lua_setfield(L, -2, "keyCode")
            }

            if nsType == .leftMouseDown || nsType == .leftMouseUp ||
               nsType == .rightMouseDown || nsType == .rightMouseUp ||
               nsType == .otherMouseDown || nsType == .otherMouseUp {
                L.push(lua_Integer(sysEvent.buttonNumber)); lua_setfield(L, -2, "buttonNumber")
                L.push(lua_Integer(sysEvent.clickCount));   lua_setfield(L, -2, "clickCount")
                L.push(lua_Number(sysEvent.pressure));       lua_setfield(L, -2, "pressure")
            }

            if nsType == .appKitDefined || nsType == .systemDefined ||
               nsType == .applicationDefined || nsType == .periodic {
                L.push(lua_Integer(sysEvent.data1));            lua_setfield(L, -2, "data1")
                L.push(lua_Integer(sysEvent.data2));            lua_setfield(L, -2, "data2")
                L.push(lua_Integer(sysEvent.subtype.rawValue)); lua_setfield(L, -2, "subtype")
            }
        }
    }
    lua_setfield(L, -2, "NSEventData")
    return 1
}

private func eventtap_event_getCharacters(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    let clean = lua_isnone(L, 2) ? false : lua_toboolean(L, -1) != 0
    let cgType = event.type

    if cgType == .keyDown || cgType == .keyUp {
        if let nsEvent = NSEvent(cgEvent: event) {
            let str = clean ? nsEvent.charactersIgnoringModifiers : nsEvent.characters
            L.push(str ?? "")
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_getKeyCode(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    L.push(event.getIntegerValueField(.keyboardEventKeycode))
    return 1
}

private func eventtap_event_setKeyCode(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    let keycode = luaL_checkinteger(L, 2)
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keycode))
    lua_settop(L, 1)
    return 1
}

private func eventtap_event_getUnicodeString(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)
    let event = getEvent(L, 1)

    var actual: Int = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &actual, unicodeString: nil)
    var buffer = [UniChar](repeating: 0, count: actual)
    event.keyboardGetUnicodeString(maxStringLength: actual, actualStringLength: &actual, unicodeString: &buffer)
    let str = NSString(characters: buffer, length: actual)
    lua_pushany(L, str)
    return 1
}

private func eventtap_event_setUnicodeString(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let event = getEvent(L, 1)
    guard let theString = lua_tovalue(L, at: 2) as? NSString else {
        lua_settop(L, 1); return 1
    }

    var buffer = [UniChar](repeating: 0, count: theString.length)
    theString.getCharacters(&buffer, range: NSRange(location: 0, length: theString.length))

    event.flags = CGEventFlags(rawValue: 0)
    event.keyboardSetUnicodeString(stringLength: theString.length, unicodeString: &buffer)

    lua_settop(L, 1)
    return 1
}

private func eventtap_event_post(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)
    let event = getEvent(L, 1)

    let input = environmentGet(L).input
    if input.isSimulated {
        // In DST mode, convert the CGEvent to an InputEvent and route
        // through the simulated input layer so hotkeys and event taps fire.
        let inputEvent = InputEvent(
            eventType: event.type.rawValue,
            keyCode: Int64(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags.rawValue,
            mousePosition: (x: Double(event.location.x), y: Double(event.location.y)),
            timestamp: Double(event.timestamp) / 1_000_000_000
        )
        _ = input.postEvent(inputEvent, tapLocation: 0)
    } else if luaL_testudata(L, 2, APPLICATION_USERDATA_TAG) != nil {
        if let app = lua_toAnyObject(L, at: 2) as? HSapplicationProtocol {
            event.postToPid(app.pid)
        }
    } else {
        event.post(tap: .cgSessionEventTap)
    }
    usleep(1000)
    lua_settop(L, 1)
    return 1
}

private func eventtap_event_getType(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)
    let event = getEvent(L, 1)
    let nsEvent = (lua_gettop(L) > 1) ? (lua_toboolean(L, 2) != 0) : false

    if nsEvent {
        if let cocoaEvent = NSEvent(cgEvent: event) {
            L.push(lua_Integer(cocoaEvent.type.rawValue))
        } else {
            L.push(lua_Integer(event.type.rawValue))
        }
    } else {
        L.push(lua_Integer(event.type.rawValue))
    }
    return 1
}

private func eventtap_event_getProperty(_ L: LuaState) throws -> CInt {
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
        L.push(event.getDoubleValueField(field))
    } else {
        L.push(event.getIntegerValueField(field))
    }
    return 1
}

private func eventtap_event_getButtonState(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    let whichButton = CGMouseButton(rawValue: UInt32(luaL_checkinteger(L, 2)))!
    let stateID = CGEventSourceStateID(rawValue: Int32(event.getIntegerValueField(.eventSourceStateID)))!
    L.push(CGEventSource.buttonState(stateID, button: whichButton))
    return 1
}

private func eventtap_event_setProperty(_ L: LuaState) throws -> CInt {
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

private func eventtap_event_newKeyEvent(_ L: LuaState) throws -> CInt {
    var hasModTable = false
    var keyCodePos: Int32 = 2
    var flags = CGEventFlags(rawValue: 0)

    if lua_type(L, 1) == LUA_TTABLE {
        flags = parseModsFromIterator(L, tableIndex: 1)
        hasModTable = true
    } else if lua_type(L, 1) == LUA_TNIL {
    } else {
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

private func eventtap_event_newSystemKeyEvent(_ L: LuaState) throws -> CInt {

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
        os_log(.error, "%{public}s", "Unknown system key for hs.eventtap.event.newSystemKeyEvent(): \(keyName)")
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

private func eventtap_event_newScrollWheelEvent(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TTABLE)
    L.push(lua_Number(1)); lua_gettable(L, 1); let offsetY = Int32(lua_tointeger(L, -1)); lua_pop(L, 1)
    L.push(lua_Number(2)); lua_gettable(L, 1); let offsetX = Int32(lua_tointeger(L, -1)); lua_pop(L, 1)

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

private func eventtap_event_newMouseEvent(_ L: LuaState) throws -> CInt {
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

private func eventtap_event_systemKey(_ L: LuaState) throws -> CInt {
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

            L.push(keyName);                                                     lua_setfield(L, -2, "key")
            L.push(lua_Integer(keyCode));                                        lua_setfield(L, -2, "keyCode")
            L.push(((keyFlags & 0xFF00) >> 8) == 0x0a);                          lua_setfield(L, -2, "down")
            L.push((keyFlags & 0x1) > 0);                                        lua_setfield(L, -2, "repeat")
        }
    }
    return 1
}

private func eventtap_event_getTouches(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)
    let event = getEvent(L, 1)

    if CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) == event.type {
        if let nsEvent = NSEvent(cgEvent: event) {
            let touches = nsEvent.allTouches()
            lua_pushany(L, touches as NSSet)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func eventtap_event_getTouchDetails(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, EVENTTAP_EVENT_USERDATA_TAG)
    let event = getEvent(L, 1)

    let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))
    if event.type == gestureType {
        guard let nsEvent = NSEvent(cgEvent: event) else { lua_pushnil(L); return 1 }
        let nsType = nsEvent.type

        lua_newtable(L)

        if nsType == .pressure {
            L.push(lua_Number(nsEvent.pressure));         lua_setfield(L, -2, "pressure")
            L.push(lua_Integer(nsEvent.stage));          lua_setfield(L, -2, "stage")
            L.push(lua_Number(nsEvent.stageTransition));  lua_setfield(L, -2, "stageTransition")
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
            L.push(behaviorStr); lua_setfield(L, -2, "pressureBehavior")
        }

        if nsType == .magnify {
            L.push(lua_Number(nsEvent.magnification)); lua_setfield(L, -2, "magnification")
        }

        if nsType == .rotate {
            L.push(lua_Number(nsEvent.rotation)); lua_setfield(L, -2, "rotation")
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Lookup Tables

private func pushTypesTable(_ L: UnsafeMutablePointer<lua_State>!) {
    lua_newtable(L)
    L.push(lua_Integer(CGEventType.null.rawValue));              lua_setfield(L, -2, "nullEvent")
    L.push(lua_Integer(CGEventType.leftMouseDown.rawValue));     lua_setfield(L, -2, "leftMouseDown")
    L.push(lua_Integer(CGEventType.leftMouseUp.rawValue));       lua_setfield(L, -2, "leftMouseUp")
    L.push(lua_Integer(CGEventType.leftMouseDragged.rawValue));  lua_setfield(L, -2, "leftMouseDragged")
    L.push(lua_Integer(CGEventType.rightMouseDown.rawValue));    lua_setfield(L, -2, "rightMouseDown")
    L.push(lua_Integer(CGEventType.rightMouseUp.rawValue));      lua_setfield(L, -2, "rightMouseUp")
    L.push(lua_Integer(CGEventType.rightMouseDragged.rawValue)); lua_setfield(L, -2, "rightMouseDragged")
    L.push(lua_Integer(CGEventType.otherMouseDown.rawValue));    lua_setfield(L, -2, "otherMouseDown")
    L.push(lua_Integer(CGEventType.otherMouseUp.rawValue));      lua_setfield(L, -2, "otherMouseUp")
    L.push(lua_Integer(CGEventType.otherMouseDragged.rawValue)); lua_setfield(L, -2, "otherMouseDragged")
    L.push(lua_Integer(CGEventType.mouseMoved.rawValue));        lua_setfield(L, -2, "mouseMoved")
    L.push(lua_Integer(CGEventType.keyDown.rawValue));           lua_setfield(L, -2, "keyDown")
    L.push(lua_Integer(CGEventType.keyUp.rawValue));             lua_setfield(L, -2, "keyUp")
    L.push(lua_Integer(CGEventType.flagsChanged.rawValue));      lua_setfield(L, -2, "flagsChanged")
    L.push(lua_Integer(CGEventType.scrollWheel.rawValue));       lua_setfield(L, -2, "scrollWheel")
    L.push(lua_Integer(CGEventType.tabletPointer.rawValue));     lua_setfield(L, -2, "tabletPointer")
    L.push(lua_Integer(CGEventType.tabletProximity.rawValue));   lua_setfield(L, -2, "tabletProximity")

    L.push(lua_Integer(NSEvent.EventType.mouseEntered.rawValue));       lua_setfield(L, -2, "mouseEntered")
    L.push(lua_Integer(NSEvent.EventType.mouseExited.rawValue));        lua_setfield(L, -2, "mouseExited")
    L.push(lua_Integer(NSEvent.EventType.cursorUpdate.rawValue));       lua_setfield(L, -2, "cursorUpdate")
    L.push(lua_Integer(NSEvent.EventType.periodic.rawValue));           lua_setfield(L, -2, "periodic")
    L.push(lua_Integer(NSEvent.EventType.appKitDefined.rawValue));      lua_setfield(L, -2, "appKitDefined")
    L.push(lua_Integer(NSEvent.EventType.systemDefined.rawValue));      lua_setfield(L, -2, "systemDefined")
    L.push(lua_Integer(NSEvent.EventType.applicationDefined.rawValue)); lua_setfield(L, -2, "applicationDefined")
    L.push(lua_Integer(NSEvent.EventType.quickLook.rawValue));          lua_setfield(L, -2, "quickLook")
    L.push(lua_Integer(NSEvent.EventType.gesture.rawValue));            lua_setfield(L, -2, "gesture")
    L.push(lua_Integer(NSEvent.EventType.magnify.rawValue));            lua_setfield(L, -2, "magnify")
    L.push(lua_Integer(NSEvent.EventType.swipe.rawValue));              lua_setfield(L, -2, "swipe")
    L.push(lua_Integer(NSEvent.EventType.rotate.rawValue));             lua_setfield(L, -2, "rotate")
    L.push(lua_Integer(NSEvent.EventType.smartMagnify.rawValue));       lua_setfield(L, -2, "smartMagnify")
    L.push(lua_Integer(NSEvent.EventType.pressure.rawValue));           lua_setfield(L, -2, "pressure")
    L.push(lua_Integer(NSEvent.EventType.directTouch.rawValue));        lua_setfield(L, -2, "directTouch")
    L.push(lua_Integer(NSEvent.EventType.changeMode.rawValue));         lua_setfield(L, -2, "changeMode")
}

private func pushPropertiesTable(_ L: UnsafeMutablePointer<lua_State>!) {
    lua_newtable(L)
    L.push(lua_Integer(CGEventField.mouseEventNumber.rawValue));                                         lua_setfield(L, -2, "mouseEventNumber")
    L.push(lua_Integer(CGEventField.mouseEventClickState.rawValue));                                     lua_setfield(L, -2, "mouseEventClickState")
    L.push(lua_Integer(CGEventField.mouseEventPressure.rawValue));                                       lua_setfield(L, -2, "mouseEventPressure")
    L.push(lua_Integer(CGEventField.mouseEventButtonNumber.rawValue));                                   lua_setfield(L, -2, "mouseEventButtonNumber")
    L.push(lua_Integer(CGEventField.mouseEventDeltaX.rawValue));                                         lua_setfield(L, -2, "mouseEventDeltaX")
    L.push(lua_Integer(CGEventField.mouseEventDeltaY.rawValue));                                         lua_setfield(L, -2, "mouseEventDeltaY")
    L.push(lua_Integer(CGEventField.mouseEventInstantMouser.rawValue));                                  lua_setfield(L, -2, "mouseEventInstantMouser")
    L.push(lua_Integer(CGEventField.mouseEventSubtype.rawValue));                                        lua_setfield(L, -2, "mouseEventSubtype")
    L.push(lua_Integer(CGEventField.keyboardEventAutorepeat.rawValue));                                  lua_setfield(L, -2, "keyboardEventAutorepeat")
    L.push(lua_Integer(CGEventField.keyboardEventKeycode.rawValue));                                     lua_setfield(L, -2, "keyboardEventKeycode")
    L.push(lua_Integer(CGEventField.keyboardEventKeyboardType.rawValue));                                lua_setfield(L, -2, "keyboardEventKeyboardType")
    L.push(lua_Integer(CGEventField.scrollWheelEventDeltaAxis1.rawValue));                               lua_setfield(L, -2, "scrollWheelEventDeltaAxis1")
    L.push(lua_Integer(CGEventField.scrollWheelEventDeltaAxis2.rawValue));                               lua_setfield(L, -2, "scrollWheelEventDeltaAxis2")
    L.push(lua_Integer(CGEventField.scrollWheelEventDeltaAxis3.rawValue));                               lua_setfield(L, -2, "scrollWheelEventDeltaAxis3")
    L.push(lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis1.rawValue));                        lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis1")
    L.push(lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis2.rawValue));                        lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis2")
    L.push(lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis3.rawValue));                        lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis3")
    L.push(lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis1.rawValue));                          lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis1")
    L.push(lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis2.rawValue));                          lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis2")
    L.push(lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis3.rawValue));                          lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis3")
    L.push(lua_Integer(CGEventField.scrollWheelEventInstantMouser.rawValue));                            lua_setfield(L, -2, "scrollWheelEventInstantMouser")
    L.push(lua_Integer(CGEventField.tabletEventPointX.rawValue));                                        lua_setfield(L, -2, "tabletEventPointX")
    L.push(lua_Integer(CGEventField.tabletEventPointY.rawValue));                                        lua_setfield(L, -2, "tabletEventPointY")
    L.push(lua_Integer(CGEventField.tabletEventPointZ.rawValue));                                        lua_setfield(L, -2, "tabletEventPointZ")
    L.push(lua_Integer(CGEventField.tabletEventPointButtons.rawValue));                                  lua_setfield(L, -2, "tabletEventPointButtons")
    L.push(lua_Integer(CGEventField.tabletEventPointPressure.rawValue));                                 lua_setfield(L, -2, "tabletEventPointPressure")
    L.push(lua_Integer(CGEventField.tabletEventTiltX.rawValue));                                         lua_setfield(L, -2, "tabletEventTiltX")
    L.push(lua_Integer(CGEventField.tabletEventTiltY.rawValue));                                         lua_setfield(L, -2, "tabletEventTiltY")
    L.push(lua_Integer(CGEventField.tabletEventRotation.rawValue));                                      lua_setfield(L, -2, "tabletEventRotation")
    L.push(lua_Integer(CGEventField.tabletEventTangentialPressure.rawValue));                            lua_setfield(L, -2, "tabletEventTangentialPressure")
    L.push(lua_Integer(CGEventField.tabletEventDeviceID.rawValue));                                      lua_setfield(L, -2, "tabletEventDeviceID")
    L.push(lua_Integer(CGEventField.tabletEventVendor1.rawValue));                                       lua_setfield(L, -2, "tabletEventVendor1")
    L.push(lua_Integer(CGEventField.tabletEventVendor2.rawValue));                                       lua_setfield(L, -2, "tabletEventVendor2")
    L.push(lua_Integer(CGEventField.tabletEventVendor3.rawValue));                                       lua_setfield(L, -2, "tabletEventVendor3")
    L.push(lua_Integer(CGEventField.tabletProximityEventVendorID.rawValue));                             lua_setfield(L, -2, "tabletProximityEventVendorID")
    L.push(lua_Integer(CGEventField.tabletProximityEventTabletID.rawValue));                             lua_setfield(L, -2, "tabletProximityEventTabletID")
    L.push(lua_Integer(CGEventField.tabletProximityEventPointerID.rawValue));                            lua_setfield(L, -2, "tabletProximityEventPointerID")
    L.push(lua_Integer(CGEventField.tabletProximityEventDeviceID.rawValue));                             lua_setfield(L, -2, "tabletProximityEventDeviceID")
    L.push(lua_Integer(CGEventField.tabletProximityEventSystemTabletID.rawValue));                       lua_setfield(L, -2, "tabletProximityEventSystemTabletID")
    L.push(lua_Integer(CGEventField.tabletProximityEventVendorPointerType.rawValue));                    lua_setfield(L, -2, "tabletProximityEventVendorPointerType")
    L.push(lua_Integer(CGEventField.tabletProximityEventVendorPointerSerialNumber.rawValue));            lua_setfield(L, -2, "tabletProximityEventVendorPointerSerialNumber")
    L.push(lua_Integer(CGEventField.tabletProximityEventVendorUniqueID.rawValue));                       lua_setfield(L, -2, "tabletProximityEventVendorUniqueID")
    L.push(lua_Integer(CGEventField.tabletProximityEventCapabilityMask.rawValue));                       lua_setfield(L, -2, "tabletProximityEventCapabilityMask")
    L.push(lua_Integer(CGEventField.tabletProximityEventPointerType.rawValue));                          lua_setfield(L, -2, "tabletProximityEventPointerType")
    L.push(lua_Integer(CGEventField.tabletProximityEventEnterProximity.rawValue));                       lua_setfield(L, -2, "tabletProximityEventEnterProximity")
    L.push(lua_Integer(CGEventField.eventTargetProcessSerialNumber.rawValue));                           lua_setfield(L, -2, "eventTargetProcessSerialNumber")
    L.push(lua_Integer(CGEventField.eventTargetUnixProcessID.rawValue));                                 lua_setfield(L, -2, "eventTargetUnixProcessID")
    L.push(lua_Integer(CGEventField.eventSourceUnixProcessID.rawValue));                                 lua_setfield(L, -2, "eventSourceUnixProcessID")
    L.push(lua_Integer(CGEventField.eventSourceUserData.rawValue));                                      lua_setfield(L, -2, "eventSourceUserData")
    L.push(lua_Integer(CGEventField.eventSourceUserID.rawValue));                                        lua_setfield(L, -2, "eventSourceUserID")
    L.push(lua_Integer(CGEventField.eventSourceGroupID.rawValue));                                       lua_setfield(L, -2, "eventSourceGroupID")
    L.push(lua_Integer(CGEventField.eventSourceStateID.rawValue));                                       lua_setfield(L, -2, "eventSourceStateID")
    L.push(lua_Integer(CGEventField.scrollWheelEventIsContinuous.rawValue));                             lua_setfield(L, -2, "scrollWheelEventIsContinuous")
    L.push(lua_Integer(CGEventField.scrollWheelEventScrollPhase.rawValue));                              lua_setfield(L, -2, "scrollWheelEventScrollPhase")
    L.push(lua_Integer(CGEventField.scrollWheelEventScrollCount.rawValue));                              lua_setfield(L, -2, "scrollWheelEventScrollCount")
    L.push(lua_Integer(CGEventField.scrollWheelEventMomentumPhase.rawValue));                            lua_setfield(L, -2, "scrollWheelEventMomentumPhase")
    L.push(lua_Integer(CGEventField.mouseEventWindowUnderMousePointer.rawValue));                        lua_setfield(L, -2, "mouseEventWindowUnderMousePointer")
    L.push(lua_Integer(CGEventField.mouseEventWindowUnderMousePointerThatCanHandleThisEvent.rawValue));  lua_setfield(L, -2, "mouseEventWindowUnderMousePointerThatCanHandleThisEvent")
    L.push(lua_Integer(CGEventField.eventUnacceleratedPointerMovementX.rawValue));                       lua_setfield(L, -2, "eventUnacceleratedPointerMovementX")
    L.push(lua_Integer(CGEventField.eventUnacceleratedPointerMovementY.rawValue));                       lua_setfield(L, -2, "eventUnacceleratedPointerMovementY")
}

private func pushFlagMasks(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    L.push(lua_Integer(NX_ALPHASHIFTMASK));                   lua_setfield(L, -2, "alphaShift")
    L.push(lua_Integer(NX_SHIFTMASK));                        lua_setfield(L, -2, "shift")
    L.push(lua_Integer(NX_CONTROLMASK));                      lua_setfield(L, -2, "control")
    L.push(lua_Integer(NX_ALTERNATEMASK));                    lua_setfield(L, -2, "alternate")
    L.push(lua_Integer(NX_COMMANDMASK));                      lua_setfield(L, -2, "command")
    L.push(lua_Integer(NX_NUMERICPADMASK));                   lua_setfield(L, -2, "numericPad")
    L.push(lua_Integer(NX_HELPMASK));                         lua_setfield(L, -2, "help")
    L.push(lua_Integer(NX_SECONDARYFNMASK));                  lua_setfield(L, -2, "secondaryFn")
    L.push(lua_Integer(NX_DEVICELCTLKEYMASK));                lua_setfield(L, -2, "deviceLeftControl")
    L.push(lua_Integer(NX_DEVICERCTLKEYMASK));                lua_setfield(L, -2, "deviceRightControl")
    L.push(lua_Integer(NX_DEVICELSHIFTKEYMASK));              lua_setfield(L, -2, "deviceLeftShift")
    L.push(lua_Integer(NX_DEVICERSHIFTKEYMASK));              lua_setfield(L, -2, "deviceRightShift")
    L.push(lua_Integer(NX_DEVICELCMDKEYMASK));                lua_setfield(L, -2, "deviceLeftCommand")
    L.push(lua_Integer(NX_DEVICERCMDKEYMASK));                lua_setfield(L, -2, "deviceRightCommand")
    L.push(lua_Integer(NX_DEVICELALTKEYMASK));                lua_setfield(L, -2, "deviceLeftAlternate")
    L.push(lua_Integer(NX_DEVICERALTKEYMASK));                lua_setfield(L, -2, "deviceRightAlternate")
    L.push(lua_Integer(NX_ALPHASHIFT_STATELESS_MASK));        lua_setfield(L, -2, "alphaShiftStateless")
    L.push(lua_Integer(NX_DEVICE_ALPHASHIFT_STATELESS_MASK)); lua_setfield(L, -2, "deviceAlphaShiftStateless")
    L.push(lua_Integer(NX_NONCOALSESCEDMASK));                lua_setfield(L, -2, "nonCoalesced")
    return 1
}

// MARK: - Flags metatable helpers

private func flags_contain(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let eventFlags = parseFlagsFromTable(L, 1)
    let flags = parseFlagsFromArray(L, 2)
    L.push(eventFlags.contains(flags))
    return 1
}

private func flags_containExactly(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let eventFlags = parseFlagsFromTable(L, 1)
    let flags = parseFlagsFromArray(L, 2)
    L.push(eventFlags == flags)
    return 1
}

// MARK: - __tostring / meta_gc

private func event_userdata_tostring(_ L: LuaState) throws -> CInt {
    let event = getEvent(L, 1)
    let eventType = event.type.rawValue
    let ptr = lua_topointer(L, 1)!
    L.push("\(EVENTTAP_EVENT_USERDATA_TAG): Event type: \(eventType) (\(ptr))")
    return 1
}

private func event_meta_gc(_ L: LuaState) throws -> CInt {
    if let src = eventSource {
        eventSource = nil
        _ = src // ARC releases
    }
    return 0
}

// MARK: - NSTouch -> Lua helper

private func pushNSTouch(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    precondition(L != nil, "lua_State must not be nil")
    let topBefore = lua_gettop(L)
    defer {
        assert(lua_gettop(L) == topBefore + 1, "pushNSTouch must push exactly one table onto the stack")
    }
    lua_newtable(L)

    pushTouchTypeField(L, touch)
    pushTouchIdentityField(L, touch)
    pushTouchPhaseFields(L, touch)
    pushTouchPositionFields(L, touch)
    pushTouchPrivateAPIFields(L, touch)

    L.push(touch.isResting)
    lua_setfield(L, -2, "resting")

    L.push("\(Unmanaged.passUnretained(touch.device as AnyObject).toOpaque())")
    lua_setfield(L, -2, "device")

    lua_pushNSSize(L, touch.deviceSize)
    lua_setfield(L, -2, "deviceSize")
}

private func pushTouchTypeField(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    switch touch.type {
    case .direct:   L.push("direct")
    case .indirect: L.push("indirect")
    @unknown default: L.push("** unrecognized type: \(touch.type.rawValue)")
    }
    lua_setfield(L, -2, "type")
}

private func pushTouchIdentityField(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    L.push("\(Unmanaged.passUnretained(touch.identity as AnyObject).toOpaque())")
    lua_setfield(L, -2, "identity")
}

private func pushTouchPhaseFields(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    switch touch.phase {
    case .began:      L.push("began")
    case .moved:      L.push("moved")
    case .stationary: L.push("stationary")
    case .ended:      L.push("ended")
    case .cancelled:  L.push("cancelled")
    default:          lua_pushnil(L)
    }
    lua_setfield(L, -2, "phase")

    L.push(touch.phase.contains(.touching))
    lua_setfield(L, -2, "touching")
}

private func pushTouchPositionFields(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    if touch.type == .indirect {
        lua_pushNSPoint(L, touch.normalizedPosition)
        lua_setfield(L, -2, "normalizedPosition")
        if touch.responds(to: Selector(("previousNormalizedPosition"))) {
            let prevPos = catchingObjCException {
                touch.perform(Selector(("previousNormalizedPosition")))?.takeUnretainedValue()
            }
            if let point = prevPos as? NSValue {
                lua_pushNSPoint(L, point.pointValue)
            } else {
                lua_pushNSPoint(L, .zero)
            }
            lua_setfield(L, -2, "previousNormalizedPosition")
        }
    } else {
        lua_pushNSPoint(L, touch.location(in: nil))
        lua_setfield(L, -2, "location")
        lua_pushNSPoint(L, touch.previousLocation(in: nil))
        lua_setfield(L, -2, "previousLocation")
    }
}

private func pushTouchPrivateAPIFields(_ L: UnsafeMutablePointer<lua_State>!, _ touch: NSTouch) {
    // Private API: timestamp
    if touch.responds(to: Selector(("timestamp"))) {
        let ts = catchingObjCException {
            touch.perform(Selector(("timestamp")))
        }
        L.push(lua_Number(bitPattern: UInt64(Int(bitPattern: ts?.toOpaque()))))
    } else {
        L.push(lua_Number(0))
    }
    lua_setfield(L, -2, "timestamp")

    // Private API: _force
    if touch.responds(to: Selector(("_force"))) {
        let f = catchingObjCException {
            touch.perform(Selector(("_force")))
        }
        L.push(lua_Number(bitPattern: UInt64(Int(bitPattern: f?.toOpaque()))))
    } else {
        L.push(lua_Number(0))
    }
    lua_setfield(L, -2, "force")
}

// MARK: - Entry Point

@_cdecl("luaopen_hs_libeventtapevent")
public func luaopen_hs_libeventtapevent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "lua_State must not be nil")
    return runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, EVENTTAP_EVENT_USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(eventtap_event_asData)
        lua_setfield(L, -2, "asData")
        L.push(eventtap_event_location)
        lua_setfield(L, -2, "location")
        L.push(eventtap_event_rawFlags)
        lua_setfield(L, -2, "rawFlags")
        L.push(eventtap_event_timestamp)
        lua_setfield(L, -2, "timestamp")
        L.push(eventtap_event_setType)
        lua_setfield(L, -2, "setType")
        L.push(eventtap_event_copy)
        lua_setfield(L, -2, "copy")
        L.push(eventtap_event_getFlags)
        lua_setfield(L, -2, "getFlags")
        L.push(eventtap_event_setFlags)
        lua_setfield(L, -2, "setFlags")
        L.push(eventtap_event_getKeyCode)
        lua_setfield(L, -2, "getKeyCode")
        L.push(eventtap_event_setKeyCode)
        lua_setfield(L, -2, "setKeyCode")
        L.push(eventtap_event_getUnicodeString)
        lua_setfield(L, -2, "getUnicodeString")
        L.push(eventtap_event_setUnicodeString)
        lua_setfield(L, -2, "setUnicodeString")
        L.push(eventtap_event_getType)
        lua_setfield(L, -2, "getType")
        L.push(eventtap_event_getTouches)
        lua_setfield(L, -2, "getTouches")
        L.push(eventtap_event_getTouchDetails)
        lua_setfield(L, -2, "getTouchDetails")
        L.push(eventtap_event_post)
        lua_setfield(L, -2, "post")
        L.push(eventtap_event_getProperty)
        lua_setfield(L, -2, "getProperty")
        L.push(eventtap_event_setProperty)
        lua_setfield(L, -2, "setProperty")
        L.push(eventtap_event_getButtonState)
        lua_setfield(L, -2, "getButtonState")
        L.push(eventtap_event_getRawEventData)
        lua_setfield(L, -2, "getRawEventData")
        L.push(eventtap_event_getCharacters)
        lua_setfield(L, -2, "getCharacters")
        L.push(eventtap_event_systemKey)
        lua_setfield(L, -2, "systemKey")
        L.push(event_userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(eventtap_event_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 7)
        L.push(eventtap_event_newGesture)
        lua_setfield(L, -2, "newGesture")
        L.push(eventtap_event_newEvent)
        lua_setfield(L, -2, "newEvent")
        L.push(eventtap_event_newEventFromData)
        lua_setfield(L, -2, "newEventFromData")
        L.push(eventtap_event_newKeyEvent)
        lua_setfield(L, -2, "newKeyEvent")
        L.push(eventtap_event_newSystemKeyEvent)
        lua_setfield(L, -2, "newSystemKeyEvent")
        L.push(eventtap_event_newMouseEvent)
        lua_setfield(L, -2, "_newMouseEvent")
        L.push(eventtap_event_newScrollWheelEvent)
        lua_setfield(L, -2, "newScrollEvent")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(event_meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        pushTypesTable(L)
        lua_setfield(L, -2, "types")

        pushPropertiesTable(L)
        lua_setfield(L, -2, "properties")

        _ = pushFlagMasks(L)
        lua_setfield(L, -2, "rawFlagMasks")

        // Skip real CGEventSource in DST simulator mode — nil is accepted by all CGEvent initializers
        if !(environmentGetGlobalOrNil()?.input.isSimulated == true) {
            eventSource = CGEventSource(stateID: .privateState)
        }

        luaL_newmetatable(L, FLAGS_TAG)
        lua_newtable(L)
        lua_pushcfunction(L, flags_contain)
        lua_setfield(L, -2, "contain")
        lua_pushcfunction(L, flags_containExactly)
        lua_setfield(L, -2, "containExactly")
        lua_setfield(L, -2, "__index")
        lua_pop(L, 1)
    }
}
