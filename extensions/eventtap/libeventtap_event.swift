import Foundation
import Cocoa
import Carbon
import LuaSkin
import IOKit.hidsystem

// MARK: - Constants

private let FLAGS_TAG = "hs.eventtap.event.flags"

private var eventSource: CGEventSource? = nil

// MARK: - Helper functions (translated from eventtap_event.h)

func hs_topoint(_ L: OpaquePointer!, idx: Int32) -> NSPoint {
    luaL_checktype(L, idx, LUA_TTABLE)
    lua_getfield(L, idx, "x")
    let x = CGFloat(luaL_checknumber(L, -1))
    lua_getfield(L, idx, "y")
    let y = CGFloat(luaL_checknumber(L, -1))
    lua_pop(L, 2)
    return NSMakePoint(x, y)
}

func hs_to_eventtap_event(_ L: OpaquePointer!, idx: Int32) -> CGEvent {
    let ptr = luaL_checkudata(L, idx, EVENT_USERDATA_TAG)!
        .assumingMemoryBound(to: Unmanaged<CGEvent>.self)
    return ptr.pointee.takeUnretainedValue()
}

func new_eventtap_event(_ L: OpaquePointer!, event: CGEvent) {
    CFRetain(event)
    let ptr = lua_newuserdata(L, MemoryLayout<Unmanaged<CGEvent>>.size)!
        .assumingMemoryBound(to: Unmanaged<CGEvent>.self)
    ptr.pointee = Unmanaged.passUnretained(event)

    luaL_getmetatable(L, EVENT_USERDATA_TAG)
    lua_setmetatable(L, -2)
}

// MARK: - Private helpers for reading CGEvent from userdata

private func getEvent(_ L: OpaquePointer!, at idx: Int32 = 1) -> CGEvent {
    let ptr = luaL_checkudata(L, idx, EVENT_USERDATA_TAG)!
        .assumingMemoryBound(to: Unmanaged<CGEvent>.self)
    return ptr.pointee.takeUnretainedValue()
}

// MARK: - GC

private func eventtap_event_gc(_ L: OpaquePointer!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, EVENT_USERDATA_TAG)!
        .assumingMemoryBound(to: Unmanaged<CGEvent>.self)
    let event = ptr.pointee.takeUnretainedValue()
    CFRelease(event)
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Constructors

/// hs.eventtap.event:copy() -> event
/// Constructor
/// Duplicates an `hs.eventtap.event` event for further modification or injection
///
/// Parameters:
///  * None
///
/// Returns:
///  * A new `hs.eventtap.event` object
private func eventtap_event_copy(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    guard let copy = event.copy() else {
        lua_pushnil(L)
        return 1
    }
    new_eventtap_event(L, event: copy)
    CFRelease(copy)
    return 1
}

/// hs.eventtap.event.newEvent() -> event
/// Constructor
/// Creates a blank event.  You will need to set its type with [hs.eventtap.event:setType](#setType)
///
/// Parameters:
///  * None
///
/// Returns:
///  * a new `hs.eventtap.event` object
///
/// Notes:
///  * this is an empty event that you should set a type for and whatever other properties may be appropriate before posting.
private func eventtap_event_newEvent(_ L: OpaquePointer!) -> Int32 {
    guard let event = CGEvent(source: eventSource) else {
        lua_pushnil(L)
        return 1
    }
    new_eventtap_event(L, event: event)
    CFRelease(event)
    return 1
}

/// hs.eventtap.event.newEventFromData(data) -> event
/// Constructor
/// Creates an event from the data encoded in the string provided.
///
/// Parameters:
///  * data - a string containing binary data provided by [hs.eventtap.event:asData](#asData) representing an event.
///
/// Returns:
///  * a new `hs.eventtap.event` object or nil if the string did not represent a valid event
private func eventtap_event_newEventFromData(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let data = skin.toNSObject(atIndex: 1, withOptions: LS_NSLuaStringAsDataOnly) as! NSData

    if let event = CGEvent(withDataAllocator: nil, data: data as CFData) {
        new_eventtap_event(L, event: event)
        CFRelease(event)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.eventtap.event.newGesture(gestureType[, gestureValue]) -> event
/// Constructor
/// Creates an gesture event.
///
/// Parameters:
///  * gestureType - the type of gesture you want to create as a string (see notes below).
///  * [gestureValue] - an optional value for the specific gesture (i.e. magnification amount or rotation in degrees).
///
/// Returns:
///  * a new `hs.eventtap.event` object or `nil` if the `gestureType` is not valid.
///
/// Notes:
///  * Valid gestureType values are:
///   * `beginMagnify` - Starts a magnification event with an optional magnification value as a number (defaults to 0). The exact unit of measurement is unknown.
///   * `endMagnify` - Starts a magnification event with an optional magnification value as a number (defaults to 0.1). The exact unit of measurement is unknown.
///   * `beginRotate` - Starts a rotation event with an rotation value in degrees (i.e. a value of 45 turns it 45 degrees left - defaults to 0).
///   * `endRotate` - Starts a rotation event with an rotation value in degrees (i.e. a value of 45 turns it 45 degrees left - defaults to 45).
///   * `beginSwipeLeft` - Begin a swipe left.
///   * `endSwipeLeft` - End a swipe left.
///   * `beginSwipeRight` - Begin a swipe right.
///   * `endSwipeRight` - End a swipe right.
///   * `beginSwipeUp` - Begin a swipe up.
///   * `endSwipeUp` - End a swipe up.
///   * `beginSwipeDown` - Begin a swipe down.
///   * `endSwipeDown` - End a swipe down.
///   * `smartMagnify` - Performs smart mangify.
private func eventtap_event_newGesture(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    let gesture = skin.toNSObject(atIndex: 1) as! NSString
    var gestureDict: NSDictionary? = nil

    switch gesture as String {
    case "beginSwipeLeft":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseBegan),
        ]
    case "endSwipeLeft":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeySwipeDirection: NSNumber(value: kTLInfoSwipeLeft),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseEnded),
        ]
    case "beginSwipeRight":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseBegan),
        ]
    case "endSwipeRight":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeySwipeDirection: NSNumber(value: kTLInfoSwipeRight),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseEnded),
        ]
    case "beginSwipeUp":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseBegan),
        ]
    case "endSwipeUp":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeySwipeDirection: NSNumber(value: kTLInfoSwipeUp),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseEnded),
        ]
    case "beginSwipeDown":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseBegan),
        ]
    case "endSwipeDown":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSwipe),
            kTLInfoKeySwipeDirection: NSNumber(value: kTLInfoSwipeDown),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseEnded),
        ]
    case "beginMagnify":
        let magnificationValue = skin.toNSObject(atIndex: 2) as? NSNumber
        let magnification = magnificationValue?.doubleValue ?? 0.0
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeMagnify),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseBegan),
            kTLInfoKeyMagnification: NSNumber(value: magnification),
        ]
    case "endMagnify":
        let magnificationValue = skin.toNSObject(atIndex: 2) as? NSNumber
        let magnification = magnificationValue?.doubleValue ?? 0.1
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeMagnify),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseEnded),
            kTLInfoKeyMagnification: NSNumber(value: magnification),
        ]
    case "smartMagnify":
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeSmartMagnify),
        ]
    case "beginRotate":
        let rotationValue = skin.toNSObject(atIndex: 2) as? NSNumber
        let rotation = rotationValue?.doubleValue ?? 0.0
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeRotate),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseBegan),
            kTLInfoKeyRotation: NSNumber(value: rotation),
        ]
    case "endRotate":
        let rotationValue = skin.toNSObject(atIndex: 2) as? NSNumber
        let rotation = rotationValue?.doubleValue ?? 45.0
        gestureDict = [
            kTLInfoKeyGestureSubtype: NSNumber(value: kTLInfoSubtypeRotate),
            kTLInfoKeyGesturePhase: NSNumber(value: kIOHIDEventPhaseEnded),
            kTLInfoKeyRotation: NSNumber(value: rotation),
        ]
    default:
        LuaSkin.logError("hs.eventtap.event.newGesture() - Invalid gesture identifier supplied.")
        lua_pushnil(L)
        return 1
    }

    let event = tl_CGEventCreateFromGesture(gestureDict! as CFDictionary, [] as CFArray)
    if let event = event {
        new_eventtap_event(L, event: event.takeUnretainedValue())
        CFRelease(event.takeUnretainedValue())
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Instance methods

/// hs.eventtap.event:asData() -> string
/// Method
/// Returns a string containing binary data representing the event.  This can be used to record events for later use.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string representing the event or nil if the event cannot be represented as a string
///
/// Notes:
///  * You can recreate the event for later posting with [hs.eventtap.event.newEventFromData](#newEventFromData)
private func eventtap_event_asData(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    if let data = event.data {
        let skin = LuaSkin.shared(withState: L)
        skin.pushNSObject(data as NSData)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.eventtap.event:location([pointTable]) -> event | table
/// Method
/// Get or set the current mouse pointer location as defined for the event.
///
/// Parameters:
///  * pointTable - an optional point table specifying the x and y coordinates of the mouse pointer location for the event
///
/// Returns:
///  * if pointTable is provided, returns the `hs.eventtap.event` object; otherwise returns a point table containing x and y key-value pairs specifying the mouse pointer location as specified for this event.
///
/// Notes:
///  * the use or effect of this method is undefined if the event is not a mouse type event.
private func eventtap_event_location(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L)
    if lua_gettop(L) == 1 {
        skin.pushNSPoint(NSPointFromCGPoint(event.location))
    } else {
        let theLocation = skin.tableToPoint(atIndex: 2)
        event.location = NSPointToCGPoint(theLocation)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.eventtap.event:timestamp([absolutetime]) -> event | integer
/// Method
/// Get or set the timestamp of the event.
///
/// Parameters:
///  * absolutetime - an optional integer specifying the timestamp for the event.
///
/// Returns:
///  * if absolutetime is provided, returns the `hs.eventtap.event` object; otherwise returns the current timestamp for the event.
///
/// Notes:
///  * Synthesized events have a timestamp of 0 by default.
///  * The timestamp, if specified, is expressed as an integer representing the number of nanoseconds since the system was last booted.  See `hs.timer.absoluteTime`.
///  * This field appears to be informational only and is not required when crafting your own events with this module.
private func eventtap_event_timestamp(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L)
    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(event.timestamp))
    } else {
        event.timestamp = CGEventTimestamp(lua_tointeger(L, 2))
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.eventtap.event:setType(type) -> event
/// Method
/// Set the type for this event.
///
/// Parameters:
///  * type - an integer matching one of the event types described in [hs.eventtap.event.types](#types)
///
/// Returns:
///  * the `hs.eventtap.event` object
private func eventtap_event_setType(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let event = getEvent(L)
    event.type = CGEventType(rawValue: UInt32(lua_tointeger(L, 2)))!
    lua_pushvalue(L, 1)
    return 1
}

/// hs.eventtap.event:rawFlags([flags]) -> event | integer
/// Method
/// Experimental method to get or set the modifier flags for an event directly.
///
/// Parameters:
///  * flags - an optional integer, made by logically combining values from [hs.eventtap.event.rawFlagMasks](#rawFlagMasks) specifying the modifier keys which should be set for this event
///
/// Returns:
///  * if flags is provided, returns the `hs.eventtap.event` object; otherwise returns the current flags set as an integer
///
/// Notes:
///  * This method is experimental and may undergo changes or even removal in the future
///  * See [hs.eventtap.event.rawFlagMasks](#rawFlagMasks) for more information
private func eventtap_event_rawFlags(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L)
    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(event.flags.rawValue))
    } else {
        event.flags = CGEventFlags(rawValue: UInt64(lua_tointeger(L, 2)))
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.eventtap.event:getFlags() -> table
/// Method
/// Gets the keyboard modifiers of an event
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the keyboard modifiers that present in the event - i.e. zero or more of the following keys, each with a value of `true`:
///   * cmd
///   * alt
///   * shift
///   * ctrl
///   * fn
///  * The table responds to the following methods:
///   * contain(mods) -> boolean
///    * Returns true if the modifiers contain all of given modifiers
///   * containExactly(mods) -> boolean
///    * Returns true if the modifiers contain all of given modifiers exactly and nothing else
///  * Parameter mods is a table containing zero or more of the following:
///   * cmd or ⌘
///   * alt or ⌥
///   * shift or ⇧
///   * ctrl or ⌃
///   * fn
private func eventtap_event_getFlags(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)

    lua_newtable(L)
    let curAltkey = event.flags
    if curAltkey.contains(.maskAlternate) { lua_pushboolean(L, 1); lua_setfield(L, -2, "alt") }
    if curAltkey.contains(.maskShift)     { lua_pushboolean(L, 1); lua_setfield(L, -2, "shift") }
    if curAltkey.contains(.maskControl)   { lua_pushboolean(L, 1); lua_setfield(L, -2, "ctrl") }
    if curAltkey.contains(.maskCommand)   { lua_pushboolean(L, 1); lua_setfield(L, -2, "cmd") }
    if curAltkey.contains(.maskSecondaryFn) { lua_pushboolean(L, 1); lua_setfield(L, -2, "fn") }

    luaL_getmetatable(L, FLAGS_TAG)
    lua_setmetatable(L, -2)
    return 1
}

/// hs.eventtap.event:setFlags(table) -> event
/// Method
/// Sets the keyboard modifiers of an event
///
/// Parameters:
///  * A table containing the keyboard modifiers to be sent with the event - i.e. zero or more of the following keys, each with a value of `true`:
///   * cmd
///   * alt
///   * shift
///   * ctrl
///   * fn
///
/// Returns:
///  * The `hs.eventap.event` object.
private func eventtap_event_setFlags(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    luaL_checktype(L, 2, LUA_TTABLE)

    var flags = CGEventFlags(rawValue: 0)

    lua_getfield(L, 2, "cmd");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskCommand) }
    lua_getfield(L, 2, "alt");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskAlternate) }
    lua_getfield(L, 2, "ctrl");  if lua_toboolean(L, -1) != 0 { flags.insert(.maskControl) }
    lua_getfield(L, 2, "shift"); if lua_toboolean(L, -1) != 0 { flags.insert(.maskShift) }
    lua_getfield(L, 2, "fn");   if lua_toboolean(L, -1) != 0 { flags.insert(.maskSecondaryFn) }

    event.flags = flags

    lua_settop(L, 1)
    return 1
}

/// hs.eventtap.event:getRawEventData() -> table
/// Method
/// Returns raw data about the event
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table with two keys:
///    * CGEventData -- a table with keys containing CGEvent data about the event.
///    * NSEventData -- a table with keys containing NSEvent data about the event.
///
/// Notes:
///  * Most of the data in `CGEventData` is already available through other methods, but is presented here without any cleanup or parsing.
///  * This method is expected to be used mostly for testing and expanding the range of possibilities available with the hs.eventtap module.  If you find that you are regularly using specific data from this method for common or re-usable purposes, consider submitting a request for adding a more targeted method to hs.eventtap or hs.eventtap.event -- it will likely be more efficient and faster for common tasks, something eventtaps need to be to minimize affecting system responsiveness.
private func eventtap_event_getRawEventData(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let cgType = event.type

    lua_newtable(L)
        lua_newtable(L)
            lua_pushinteger(L, lua_Integer(event.getIntegerValueField(.keyboardEventKeycode)))
            lua_setfield(L, -2, "keycode")
            lua_pushinteger(L, lua_Integer(event.flags.rawValue))
            lua_setfield(L, -2, "flags")
            lua_pushinteger(L, lua_Integer(cgType.rawValue))
            lua_setfield(L, -2, "type")
        lua_setfield(L, -2, "CGEventData")

        lua_newtable(L)
        if cgType != .tapDisabledByTimeout && cgType != .tapDisabledByUserInput {
            if let sysEvent = NSEvent(cgEvent: event) {
                let type = sysEvent.type
                lua_pushinteger(L, lua_Integer(sysEvent.modifierFlags.rawValue))
                lua_setfield(L, -2, "modifierFlags")
                lua_pushinteger(L, lua_Integer(type.rawValue))
                lua_setfield(L, -2, "type")
                lua_pushinteger(L, lua_Integer(sysEvent.windowNumber))
                lua_setfield(L, -2, "windowNumber")
                if type == .keyDown || type == .keyUp {
                    lua_pushstring(L, sysEvent.characters ?? "")
                    lua_setfield(L, -2, "characters")
                    lua_pushstring(L, sysEvent.charactersIgnoringModifiers ?? "")
                    lua_setfield(L, -2, "charactersIgnoringModifiers")
                    lua_pushinteger(L, lua_Integer(sysEvent.keyCode))
                    lua_setfield(L, -2, "keyCode")
                }
                if type == .leftMouseDown || type == .leftMouseUp ||
                   type == .rightMouseDown || type == .rightMouseUp ||
                   type == .otherMouseDown || type == .otherMouseUp {
                    lua_pushinteger(L, lua_Integer(sysEvent.buttonNumber))
                    lua_setfield(L, -2, "buttonNumber")
                    lua_pushinteger(L, lua_Integer(sysEvent.clickCount))
                    lua_setfield(L, -2, "clickCount")
                    lua_pushnumber(L, lua_Number(sysEvent.pressure))
                    lua_setfield(L, -2, "pressure")
                }
                if type == .appKitDefined || type == .systemDefined ||
                   type == .applicationDefined || type == .periodic {
                    lua_pushinteger(L, lua_Integer(sysEvent.data1))
                    lua_setfield(L, -2, "data1")
                    lua_pushinteger(L, lua_Integer(sysEvent.data2))
                    lua_setfield(L, -2, "data2")
                    lua_pushinteger(L, lua_Integer(sysEvent.subtype.rawValue))
                    lua_setfield(L, -2, "subtype")
                }
            }
        }
        lua_setfield(L, -2, "NSEventData")
    return 1
}

/// hs.eventtap.event:getCharacters([clean]) -> string or nil
/// Method
/// Returns the Unicode character, if any, represented by a keyDown or keyUp event.
///
/// Parameters:
///  * clean -- an optional parameter, default `false`, which indicates if key modifiers, other than Shift, should be stripped from the keypress before converting to Unicode.
///
/// Returns:
///  * A string containing the Unicode character represented by the keyDown or keyUp event, or nil if the event is not a keyUp or keyDown.
///
/// Notes:
///  * This method should only be used on keyboard events
///  * If `clean` is true, all modifiers except for Shift are stripped from the character before converting to the Unicode character represented by the keypress.
///  * If the keypress does not correspond to a valid Unicode character, an empty string is returned (e.g. if `clean` is false, then Opt-E will return an empty string, while Opt-Shift-E will return an accent mark).
private func eventtap_event_getCharacters(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let clean = lua_isnone(L, 2) != 0 ? false : (lua_toboolean(L, 2) != 0)
    let cgType = event.type

    if cgType == .keyDown || cgType == .keyUp {
        if let sysEvent = NSEvent(cgEvent: event) {
            if clean {
                lua_pushstring(L, sysEvent.charactersIgnoringModifiers ?? "")
            } else {
                lua_pushstring(L, sysEvent.characters ?? "")
            }
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.eventtap.event:getKeyCode() -> keycode
/// Method
/// Gets the raw keycode for the event
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the raw keycode, taken from `hs.keycodes.map`
///
/// Notes:
///  * This method should only be used on keyboard events
private func eventtap_event_getKeyCode(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    lua_pushinteger(L, lua_Integer(event.getIntegerValueField(.keyboardEventKeycode)))
    return 1
}

/// hs.eventtap.event:setKeyCode(keycode)
/// Method
/// Sets the raw keycode for the event
///
/// Parameters:
///  * keycode - A number containing a raw keycode, taken from `hs.keycodes.map`
///
/// Returns:
///  * The `hs.eventtap.event` object
///
/// Notes:
///  * This method should only be used on keyboard events
private func eventtap_event_setKeyCode(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let keycode = CGKeyCode(luaL_checkinteger(L, 2))
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keycode))
    lua_settop(L, 1)
    return 1
}

/// hs.eventtap.event:getUnicodeString()
/// Method
/// Gets the single unicode character of an event
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the unicode character
private func eventtap_event_getUnicodeString(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TBREAK)

    let event = getEvent(L)
    var actual: Int = 0
    // Get the length of the string
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &actual, unicodeString: nil)
    var buffer = [UniChar](repeating: 0, count: actual)
    event.keyboardGetUnicodeString(maxStringLength: actual, actualStringLength: &actual, unicodeString: &buffer)

    let theString = NSString(characters: buffer, length: actual)
    skin.pushNSObject(theString)

    return 1
}

/// hs.eventtap.event:setUnicodeString(string)
/// Method
/// Sets a unicode string as the output of the event
///
/// Parameters:
///  * string - A string containing unicode characters, which will be applied to the event
///
/// Returns:
///  * The `hs.eventtap.event` object
///
/// Notes:
///  * Calling this method will reset any flags previously set on the event (because they don't make any sense, and you should not try to set flags again)
///  * This is likely to only work with short unicode strings that resolve to a single character
private func eventtap_event_setUnicodeString(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TSTRING, LS_TBREAK)

    let event = getEvent(L)
    let theString = skin.toNSObject(atIndex: 2) as! NSString
    let stringLen = theString.lengthOfBytes(using: String.Encoding.unicode.rawValue)
    var usedLen: Int = 0

    var buffer = [UniChar](repeating: 0, count: stringLen / MemoryLayout<UniChar>.size)
    let result = theString.getBytes(
        &buffer,
        maxLength: stringLen,
        usedLength: &usedLen,
        encoding: String.Encoding.unicode.rawValue,
        options: .allowLossy,
        range: NSRange(location: 0, length: theString.length),
        remaining: nil
    )
    if !result {
        skin.logWarn("hs.eventtap.event:setUnicodeString() failed to convert: \(theString)")
    }

    event.flags = CGEventFlags(rawValue: 0)
    event.keyboardSetUnicodeString(stringLength: theString.length, unicodeString: buffer)

    lua_settop(L, 1)
    return 1
}

/// hs.eventtap.event:post([app])
/// Method
/// Posts the event to the OS - i.e. emits the keyboard/mouse input defined by the event
///
/// Parameters:
///  * app - An optional `hs.application` object. If specified, the event will only be sent to that application
///
/// Returns:
///  * The `hs.eventtap.event` object
private func eventtap_event_post(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TANY | LS_TOPTIONAL, LS_TBREAK)

    let event = getEvent(L)

    if luaL_testudata(L, 2, APPLICATION_USERDATA_TAG) != nil {
        let appObj = skin.toNSObject(atIndex: 2) as! HSapplication
        let pid = appObj.pid
        event.postToPid(pid)
    } else {
        event.post(tap: .cgSessionEventTap)
    }

    usleep(1000)

    lua_settop(L, 1)
    return 1
}

/// hs.eventtap.event:getType([nsSpecificType]) -> number
/// Method
/// Gets the type of the event
///
/// Parameters:
///  * `nsSpecificType` - an optional boolean, default false, specifying whether or not a more specific Cocoa NSEvent type should be returned, if available.
///
/// Returns:
///  * A number containing the type of the event, taken from `hs.eventtap.event.types`
private func eventtap_event_getType(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let event = getEvent(L)
    let nsEvent = lua_gettop(L) > 1 ? (lua_toboolean(L, 2) != 0) : false

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

/// hs.eventtap.event:getProperty(prop) -> number
/// Method
/// Gets a property of the event
///
/// Parameters:
///  * prop - A value taken from `hs.eventtap.event.properties`
///
/// Returns:
///  * A number containing the value of the requested property
///
/// Notes:
///  * The properties are `CGEventField` values, as documented at https://developer.apple.com/library/mac/documentation/Carbon/Reference/QuartzEventServicesRef/index.html#//apple_ref/c/tdef/CGEventField
private func eventtap_event_getProperty(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let field = CGEventField(rawValue: UInt32(luaL_checkinteger(L, 2)))!

    if isDoubleField(field) {
        lua_pushnumber(L, event.getDoubleValueField(field))
    } else {
        lua_pushinteger(L, lua_Integer(event.getIntegerValueField(field)))
    }
    return 1
}

/// hs.eventtap.event:getButtonState(button) -> bool
/// Method
/// Gets the state of a mouse button in the event
///
/// Parameters:
///  * button - A number between 0 and 31. The left mouse button is 0, the right mouse button is 1 and the middle mouse button is 2. The meaning of the remaining buttons varies by hardware, and their functionality varies by application (typically they are not present on a mouse and have no effect in an application)
///
/// Returns:
///  * A boolean, true if the specified mouse button is to be clicked by the event
///
/// Notes:
///  * This method should only be called on mouse events
private func eventtap_event_getButtonState(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let whichButton = CGMouseButton(rawValue: UInt32(luaL_checkinteger(L, 2)))!

    let sourceStateID = CGEventSourceStateID(rawValue: Int32(event.getIntegerValueField(.eventSourceStateID)))!
    let pressed = CGEventSource.buttonState(sourceStateID, button: whichButton)
    lua_pushboolean(L, pressed ? 1 : 0)
    return 1
}

/// hs.eventtap.event:setProperty(prop, value)
/// Method
/// Sets a property of the event
///
/// Parameters:
///  * prop - A value from `hs.eventtap.event.properties`
///  * value - A number containing the value of the specified property
///
/// Returns:
///  * The `hs.eventtap.event` object.
///
/// Notes:
///  * The properties are `CGEventField` values, as documented at https://developer.apple.com/library/mac/documentation/Carbon/Reference/QuartzEventServicesRef/index.html#//apple_ref/c/tdef/CGEventField
private func eventtap_event_setProperty(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let field = CGEventField(rawValue: UInt32(luaL_checkinteger(L, 2)))!

    if isDoubleField(field) {
        let value = luaL_checknumber(L, 3)
        event.setDoubleValueField(field, value: value)
    } else {
        let value = Int64(luaL_checkinteger(L, 3))
        event.setIntegerValueField(field, value: value)
    }

    lua_settop(L, 1)
    return 1
}

/// Helper to check if a CGEventField uses double (floating point) values
private func isDoubleField(_ field: CGEventField) -> Bool {
    return field == .mouseEventPressure ||
           field == .scrollWheelEventFixedPtDeltaAxis1 ||
           field == .scrollWheelEventFixedPtDeltaAxis2 ||
           field == .scrollWheelEventFixedPtDeltaAxis3 ||
           field == .tabletEventPointPressure ||
           field == .tabletEventTiltX ||
           field == .tabletEventTiltY ||
           field == .tabletEventRotation ||
           field == .tabletEventTangentialPressure
}

// MARK: - Key event constructors

/// hs.eventtap.event.newKeyEvent([mods], key, isdown) -> event
/// Constructor
/// Creates a keyboard event
///
/// Parameters:
///  * mods - An optional table containing zero or more of the following:
///   * cmd
///   * alt
///   * shift
///   * ctrl
///   * fn
///  * key - A string containing the name of a key (see `hs.hotkey` for more information) or an integer specifying the virtual keycode for the key.
///  * isdown - A boolean, true if the event should be a key-down, false if it should be a key-up
///
/// Returns:
///  * An `hs.eventtap.event` object
///
/// Notes:
///  * The original version of this constructor utilized a shortcut which merged `flagsChanged` and `keyUp`/`keyDown` events into one.  This approach is still supported for backwards compatibility and because it *does* work in most cases.
///  * According to Apple Documentation, the proper way to perform a keypress with modifiers is through multiple key events.
///  * The shortcut approach is still limited to generating only the left version of modifiers.
private func eventtap_event_newKeyEvent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    var hasModTable = false
    var keyCodePos: Int32 = 2
    var flags = CGEventFlags(rawValue: 0)

    if lua_type(L, 1) == LUA_TTABLE {
        skin.checkArgs(LS_TTABLE, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

        lua_pushnil(L)
        while lua_next(L, 1) != 0 {
            guard let modifier = lua_tostring(L, -1) else {
                skin.logBreadcrumb("hs.eventtap.event.newKeyEvent() unexpected entry in modifiers table: \(lua_type(L, -1))")
                lua_pop(L, 1)
                continue
            }
            let mod = String(cString: modifier)

            if mod == "cmd" || mod == "⌘"       { flags.insert(.maskCommand) }
            else if mod == "ctrl" || mod == "⌃"  { flags.insert(.maskControl) }
            else if mod == "alt" || mod == "⌥"   { flags.insert(.maskAlternate) }
            else if mod == "shift" || mod == "⇧" { flags.insert(.maskShift) }
            else if mod == "fn"                   { flags.insert(.maskSecondaryFn) }
            lua_pop(L, 1)
        }
        hasModTable = true
    } else if lua_type(L, 1) == LUA_TNIL {
        skin.checkArgs(LS_TNIL, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    } else {
        skin.checkArgs(LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
        keyCodePos = 1
    }

    let isDown = lua_toboolean(L, keyCodePos + 1) != 0
    let keyCode = CGKeyCode(lua_tointeger(L, keyCodePos))

    guard let keyevent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown) else {
        lua_pushnil(L)
        return 1
    }
    if hasModTable { keyevent.flags = flags }
    new_eventtap_event(L, event: keyevent)
    CFRelease(keyevent)

    return 1
}

/// hs.eventtap.event.newSystemKeyEvent(key, isdown) -> event
/// Constructor
/// Creates a keyboard event for special keys (e.g. media playback)
///
/// Parameters:
///  * key - A string containing the name of a special key. The possible names are:
///   * SOUND_UP, SOUND_DOWN, MUTE, BRIGHTNESS_UP, BRIGHTNESS_DOWN, CONTRAST_UP, CONTRAST_DOWN,
///   * POWER, LAUNCH_PANEL, VIDMIRROR, PLAY, EJECT, NEXT, PREVIOUS, FAST, REWIND,
///   * ILLUMINATION_UP, ILLUMINATION_DOWN, ILLUMINATION_TOGGLE, CAPS_LOCK, HELP, NUM_LOCK
///  * isdown - A boolean, true if the event should be a key-down, false if it should be a key-up
///
/// Returns:
///  * An `hs.eventtap.event` object
///
/// Notes:
///  * To set modifiers on a system key event (e.g. cmd/ctrl/etc), see the `hs.eventtap.event:setFlags()` method
///  * The event names are case sensitive
private func eventtap_event_newSystemKeyEvent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBOOLEAN, LS_TBREAK)

    let keyName = skin.toNSObject(atIndex: 1) as! NSString
    let isDown = lua_toboolean(L, 2) != 0
    var keyVal: Int32 = -1

    switch keyName as String {
    case "SOUND_UP":            keyVal = Int32(NX_KEYTYPE_SOUND_UP)
    case "SOUND_DOWN":          keyVal = Int32(NX_KEYTYPE_SOUND_DOWN)
    case "POWER":               keyVal = Int32(NX_POWER_KEY)
    case "MUTE":                keyVal = Int32(NX_KEYTYPE_MUTE)
    case "BRIGHTNESS_UP":       keyVal = Int32(NX_KEYTYPE_BRIGHTNESS_UP)
    case "BRIGHTNESS_DOWN":     keyVal = Int32(NX_KEYTYPE_BRIGHTNESS_DOWN)
    case "CONTRAST_UP":         keyVal = Int32(NX_KEYTYPE_CONTRAST_UP)
    case "CONTRAST_DOWN":       keyVal = Int32(NX_KEYTYPE_CONTRAST_DOWN)
    case "LAUNCH_PANEL":        keyVal = Int32(NX_KEYTYPE_LAUNCH_PANEL)
    case "EJECT":               keyVal = Int32(NX_KEYTYPE_EJECT)
    case "VIDMIRROR":           keyVal = Int32(NX_KEYTYPE_VIDMIRROR)
    case "PLAY":                keyVal = Int32(NX_KEYTYPE_PLAY)
    case "NEXT":                keyVal = Int32(NX_KEYTYPE_NEXT)
    case "PREVIOUS":            keyVal = Int32(NX_KEYTYPE_PREVIOUS)
    case "FAST":                keyVal = Int32(NX_KEYTYPE_FAST)
    case "REWIND":              keyVal = Int32(NX_KEYTYPE_REWIND)
    case "ILLUMINATION_UP":     keyVal = Int32(NX_KEYTYPE_ILLUMINATION_UP)
    case "ILLUMINATION_DOWN":   keyVal = Int32(NX_KEYTYPE_ILLUMINATION_DOWN)
    case "ILLUMINATION_TOGGLE": keyVal = Int32(NX_KEYTYPE_ILLUMINATION_TOGGLE)
    case "CAPS_LOCK":           keyVal = Int32(NX_KEYTYPE_CAPS_LOCK)
    case "HELP":                keyVal = Int32(NX_KEYTYPE_HELP)
    case "NUM_LOCK":            keyVal = Int32(NX_KEYTYPE_NUM_LOCK)
    default:
        skin.logError("Unknown system key for hs.eventtap.event.newSystemKeyEvent(): \(keyName)")
        lua_pushnil(L)
        return 1
    }

    let keyFlags: NSEvent.ModifierFlags = isDown ? NSEvent.ModifierFlags(rawValue: UInt(NX_KEYDOWN)) : NSEvent.ModifierFlags(rawValue: UInt(NX_KEYUP))
    let data1 = Int(keyVal) << 16 | (isDown ? Int(NX_KEYDOWN) : Int(NX_KEYUP)) << 8

    guard let keyEvent = NSEvent.otherEvent(
        with: .systemDefined,
        location: NSMakePoint(0, 0),
        modifierFlags: keyFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        data1: data1,
        data2: -1
    ) else {
        lua_pushnil(L)
        return 1
    }
    new_eventtap_event(L, event: keyEvent.cgEvent!)

    return 1
}

// MARK: - Scroll wheel event constructor

/// hs.eventtap.event.newScrollEvent(offsets, mods, unit) -> event
/// Constructor
/// Creates a scroll wheel event
///
/// Parameters:
///  * offsets - A table containing the {horizontal, vertical} amount to scroll. Positive values scroll up or left, negative values scroll down or right.
///  * mods - A table containing zero or more of the following:
///   * cmd
///   * alt
///   * shift
///   * ctrl
///   * fn
///  * unit - An optional string containing the name of the unit for scrolling. Either "line" (the default) or "pixel"
///
/// Returns:
///  * An `hs.eventtap.event` object
private func eventtap_event_newScrollWheelEvent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    luaL_checktype(L, 1, LUA_TTABLE)

    lua_pushnumber(L, 1); lua_gettable(L, 1)
    let offset_y = Int32(lua_tointeger(L, -1)); lua_pop(L, 1)
    lua_pushnumber(L, 2); lua_gettable(L, 1)
    let offset_x = Int32(lua_tointeger(L, -1)); lua_pop(L, 1)

    var flags = CGEventFlags(rawValue: 0)

    luaL_checktype(L, 2, LUA_TTABLE)
    lua_pushnil(L)
    while lua_next(L, 2) != 0 {
        guard let modifier = lua_tostring(L, -1) else {
            skin.logBreadcrumb("hs.eventtap.event.newScrollEvent() unexpected entry in modifiers table: \(lua_type(L, -1))")
            lua_pop(L, 1)
            continue
        }
        let mod = String(cString: modifier)
        if mod == "cmd" || mod == "⌘"       { flags.insert(.maskCommand) }
        else if mod == "ctrl" || mod == "⌃"  { flags.insert(.maskControl) }
        else if mod == "alt" || mod == "⌥"   { flags.insert(.maskAlternate) }
        else if mod == "shift" || mod == "⇧" { flags.insert(.maskShift) }
        else if mod == "fn"                   { flags.insert(.maskSecondaryFn) }
        lua_pop(L, 1)
    }

    let type: CGScrollEventUnit
    if let unitStr = lua_tostring(L, 3), String(cString: unitStr) == "pixel" {
        type = .pixel
    } else {
        type = .line
    }

    guard let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: type, wheelCount: 2, wheel1: offset_x, wheel2: offset_y) else {
        lua_pushnil(L)
        return 1
    }
    scrollEvent.flags = flags
    new_eventtap_event(L, event: scrollEvent)
    CFRelease(scrollEvent)

    return 1
}

// MARK: - Mouse event constructor

private func eventtap_event_newMouseEvent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let type = CGEventType(rawValue: UInt32(luaL_checkinteger(L, 1)))!
    let point = hs_topoint(L, idx: 2)

    let buttonString = String(cString: luaL_checkstring(L, 3))

    var flags = CGEventFlags(rawValue: 0)
    var button = CGMouseButton.left

    if buttonString == "right" {
        button = .right
    } else if buttonString == "other" {
        button = .center
    } else if buttonString == "none" {
        button = CGMouseButton(rawValue: 0)!
    }

    if !lua_isnoneornil(L, 4) && lua_type(L, 4) == LUA_TTABLE {
        lua_pushnil(L)
        while lua_next(L, 4) != 0 {
            guard let modifier = lua_tostring(L, -1) else {
                skin.logBreadcrumb("hs.eventtap.event.newMouseEvent() unexpected entry in modifiers table: \(lua_type(L, -1))")
                lua_pop(L, 1)
                continue
            }
            let mod = String(cString: modifier)
            if mod == "cmd" || mod == "⌘"       { flags.insert(.maskCommand) }
            else if mod == "ctrl" || mod == "⌃"  { flags.insert(.maskControl) }
            else if mod == "alt" || mod == "⌥"   { flags.insert(.maskAlternate) }
            else if mod == "shift" || mod == "⇧" { flags.insert(.maskShift) }
            else if mod == "fn"                   { flags.insert(.maskSecondaryFn) }
            lua_pop(L, 1)
        }
    }

    guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: NSPointToCGPoint(point), mouseButton: button) else {
        lua_pushnil(L)
        return 1
    }
    event.flags = flags
    new_eventtap_event(L, event: event)
    CFRelease(event)

    return 1
}

// MARK: - systemKey method

/// hs.eventtap.event:systemKey() -> table
/// Method
/// Returns the special key and its state if the event is a NSSystemDefined event of subtype AUX_CONTROL_BUTTONS (special-key pressed)
///
/// Parameters:
///  * None
///
/// Returns:
///  * If the event is a NSSystemDefined event of subtype AUX_CONTROL_BUTTONS, a table with the following keys defined:
///    * key    -- a string containing one of the labels indicating the key involved
///    * keyCode -- the numeric keyCode corresponding to the key specified in `key`.
///    * down   -- a boolean value indicating if the key is pressed down (true) or just released (false)
///    * repeat -- a boolean indicating if this event is because the keydown is repeating.
///  * If the event does not correspond to a NSSystemDefined event of subtype AUX_CONTROL_BUTTONS, then an empty table is returned.
private func eventtap_event_systemKey(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    guard let sysEvent = NSEvent(cgEvent: event) else {
        lua_newtable(L)
        return 1
    }
    let type = sysEvent.type

    lua_newtable(L)
    if type == .appKitDefined || type == .systemDefined ||
       type == .applicationDefined || type == .periodic {
        let data1 = sysEvent.data1
        if sysEvent.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) {
            let keyCode = (Int(data1) & 0xFFFF0000) >> 16
            let keyFlags = Int(data1) & 0xFFFF

            let keyName: String
            switch Int32(keyCode) {
            case NX_KEYTYPE_SOUND_UP:            keyName = "SOUND_UP"
            case NX_KEYTYPE_SOUND_DOWN:          keyName = "SOUND_DOWN"
            case NX_POWER_KEY:                   keyName = "POWER"
            case NX_KEYTYPE_MUTE:                keyName = "MUTE"
            case NX_KEYTYPE_BRIGHTNESS_UP:       keyName = "BRIGHTNESS_UP"
            case NX_KEYTYPE_BRIGHTNESS_DOWN:     keyName = "BRIGHTNESS_DOWN"
            case NX_KEYTYPE_CONTRAST_UP:         keyName = "CONTRAST_UP"
            case NX_KEYTYPE_CONTRAST_DOWN:       keyName = "CONTRAST_DOWN"
            case NX_KEYTYPE_LAUNCH_PANEL:        keyName = "LAUNCH_PANEL"
            case NX_KEYTYPE_EJECT:               keyName = "EJECT"
            case NX_KEYTYPE_VIDMIRROR:           keyName = "VIDMIRROR"
            case NX_KEYTYPE_PLAY:                keyName = "PLAY"
            case NX_KEYTYPE_NEXT:                keyName = "NEXT"
            case NX_KEYTYPE_PREVIOUS:            keyName = "PREVIOUS"
            case NX_KEYTYPE_FAST:                keyName = "FAST"
            case NX_KEYTYPE_REWIND:              keyName = "REWIND"
            case NX_KEYTYPE_ILLUMINATION_UP:     keyName = "ILLUMINATION_UP"
            case NX_KEYTYPE_ILLUMINATION_DOWN:   keyName = "ILLUMINATION_DOWN"
            case NX_KEYTYPE_ILLUMINATION_TOGGLE: keyName = "ILLUMINATION_TOGGLE"
            case NX_KEYTYPE_CAPS_LOCK:           keyName = "CAPS_LOCK"
            case NX_KEYTYPE_HELP:                keyName = "HELP"
            case NX_KEYTYPE_NUM_LOCK:            keyName = "NUM_LOCK"
            default:                             keyName = "undefined"
            }

            lua_pushstring(L, keyName)
            lua_setfield(L, -2, "key")
            lua_pushinteger(L, lua_Integer(keyCode))
            lua_setfield(L, -2, "keyCode")
            lua_pushboolean(L, ((keyFlags & 0xFF00) >> 8) == 0x0a ? 1 : 0)
            lua_setfield(L, -2, "down")
            lua_pushboolean(L, (keyFlags & 0x1) > 0 ? 1 : 0)
            lua_setfield(L, -2, "repeat")
        }
    }
    return 1
}

// MARK: - Touch methods

/// hs.eventtap.event:getTouches() -> table | nil
/// Method
/// Returns a table of details containing information about touches on the trackpad associated with this event if the event is of the type `hs.eventtap.event.types.gesture`.
///
/// Parameters:
///  * None
///
/// Returns:
///  * if the event is of the type gesture, returns a table; otherwise returns nil.
private func eventtap_event_getTouches(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TBREAK)
    let event = getEvent(L)

    if CGEventType(rawValue: UInt32(NSEventType.gesture.rawValue)) == event.type {
        if let asNSEvent = NSEvent(cgEvent: event) {
            let touches = asNSEvent.allTouches()
            skin.pushNSObject(touches)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.eventtap.event:getTouchDetails() -> table | nil
/// Method
/// Returns a table containing more information about some touch related events.
///
/// Parameters:
///  * None
///
/// Returns:
///  * if the event is a touch event (i.e. is an event of type `hs.eventtap.event.types.gesture`), then this method returns a table with zero or more of the following key-value pairs:
///    * if the gesture is for a pressure event:
///      * `pressure`, `stage`, `stageTransition`, `pressureBehavior`
///    * if the gesture is for a magnification event:
///      * `magnification`
///    * if the gesture is for a rotation event:
///      * `rotation`
private func eventtap_event_getTouchDetails(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, EVENT_USERDATA_TAG, LS_TBREAK)
    let event = getEvent(L)

    if CGEventType(rawValue: UInt32(NSEventType.gesture.rawValue)) == event.type {
        guard let asNSEvent = NSEvent(cgEvent: event) else {
            lua_pushnil(L)
            return 1
        }
        let type = asNSEvent.type

        lua_newtable(L)

        if type == .pressure {
            lua_pushnumber(L, lua_Number(asNSEvent.pressure))
            lua_setfield(L, -2, "pressure")
            lua_pushinteger(L, lua_Integer(asNSEvent.stage))
            lua_setfield(L, -2, "stage")
            lua_pushnumber(L, lua_Number(asNSEvent.stageTransition))
            lua_setfield(L, -2, "stageTransition")

            let pressureBehavior = asNSEvent.pressureBehavior
            let behaviorStr: String
            switch pressureBehavior {
            case .unknown:            behaviorStr = "unknown"
            case .primaryDefault:     behaviorStr = "default"
            case .primaryClick:       behaviorStr = "click"
            case .primaryGeneric:     behaviorStr = "generic"
            case .primaryAccelerator: behaviorStr = "accelerator"
            case .primaryDeepClick:   behaviorStr = "deepClick"
            case .primaryDeepDrag:    behaviorStr = "deepDrag"
            @unknown default:
                behaviorStr = "** unrecognized pressureBehavior: \(pressureBehavior.rawValue)"
            }
            lua_pushstring(L, behaviorStr)
            lua_setfield(L, -2, "pressureBehavior")
        }

        if type == .magnify {
            lua_pushnumber(L, lua_Number(asNSEvent.magnification))
            lua_setfield(L, -2, "magnification")
        }

        if type == .rotate {
            lua_pushnumber(L, lua_Number(asNSEvent.rotation))
            lua_setfield(L, -2, "rotation")
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Types and properties tables

/// hs.eventtap.event.types -> table
/// Constant
/// A table containing event types to be used with `hs.eventtap.new(...)` and returned by `hs.eventtap.event:type()`.
private func pushtypestable(_ L: OpaquePointer!) {
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

/// hs.eventtap.event.properties -> table
/// Constant
/// A table containing property types for use with `hs.eventtap.event:getProperty()` and `hs.eventtap.event:setProperty()`.
private func pushpropertiestable(_ L: OpaquePointer!) {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventNumber.rawValue));                lua_setfield(L, -2, "mouseEventNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventClickState.rawValue));             lua_setfield(L, -2, "mouseEventClickState")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventPressure.rawValue));               lua_setfield(L, -2, "mouseEventPressure")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventButtonNumber.rawValue));            lua_setfield(L, -2, "mouseEventButtonNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventDeltaX.rawValue));                 lua_setfield(L, -2, "mouseEventDeltaX")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventDeltaY.rawValue));                 lua_setfield(L, -2, "mouseEventDeltaY")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventInstantMouser.rawValue));           lua_setfield(L, -2, "mouseEventInstantMouser")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventSubtype.rawValue));                lua_setfield(L, -2, "mouseEventSubtype")
    lua_pushinteger(L, lua_Integer(CGEventField.keyboardEventAutorepeat.rawValue));           lua_setfield(L, -2, "keyboardEventAutorepeat")
    lua_pushinteger(L, lua_Integer(CGEventField.keyboardEventKeycode.rawValue));              lua_setfield(L, -2, "keyboardEventKeycode")
    lua_pushinteger(L, lua_Integer(CGEventField.keyboardEventKeyboardType.rawValue));         lua_setfield(L, -2, "keyboardEventKeyboardType")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventDeltaAxis1.rawValue));        lua_setfield(L, -2, "scrollWheelEventDeltaAxis1")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventDeltaAxis2.rawValue));        lua_setfield(L, -2, "scrollWheelEventDeltaAxis2")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventDeltaAxis3.rawValue));        lua_setfield(L, -2, "scrollWheelEventDeltaAxis3")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis1.rawValue)); lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis1")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis2.rawValue)); lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis2")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventFixedPtDeltaAxis3.rawValue)); lua_setfield(L, -2, "scrollWheelEventFixedPtDeltaAxis3")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis1.rawValue));   lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis1")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis2.rawValue));   lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis2")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventPointDeltaAxis3.rawValue));   lua_setfield(L, -2, "scrollWheelEventPointDeltaAxis3")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventInstantMouser.rawValue));     lua_setfield(L, -2, "scrollWheelEventInstantMouser")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointX.rawValue));                lua_setfield(L, -2, "tabletEventPointX")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointY.rawValue));                lua_setfield(L, -2, "tabletEventPointY")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointZ.rawValue));                lua_setfield(L, -2, "tabletEventPointZ")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointButtons.rawValue));           lua_setfield(L, -2, "tabletEventPointButtons")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventPointPressure.rawValue));          lua_setfield(L, -2, "tabletEventPointPressure")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventTiltX.rawValue));                 lua_setfield(L, -2, "tabletEventTiltX")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventTiltY.rawValue));                 lua_setfield(L, -2, "tabletEventTiltY")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventRotation.rawValue));              lua_setfield(L, -2, "tabletEventRotation")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventTangentialPressure.rawValue));     lua_setfield(L, -2, "tabletEventTangentialPressure")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventDeviceID.rawValue));              lua_setfield(L, -2, "tabletEventDeviceID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventVendor1.rawValue));               lua_setfield(L, -2, "tabletEventVendor1")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventVendor2.rawValue));               lua_setfield(L, -2, "tabletEventVendor2")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletEventVendor3.rawValue));               lua_setfield(L, -2, "tabletEventVendor3")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorID.rawValue));      lua_setfield(L, -2, "tabletProximityEventVendorID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventTabletID.rawValue));      lua_setfield(L, -2, "tabletProximityEventTabletID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventPointerID.rawValue));     lua_setfield(L, -2, "tabletProximityEventPointerID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventDeviceID.rawValue));      lua_setfield(L, -2, "tabletProximityEventDeviceID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventSystemTabletID.rawValue)); lua_setfield(L, -2, "tabletProximityEventSystemTabletID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorPointerType.rawValue)); lua_setfield(L, -2, "tabletProximityEventVendorPointerType")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorPointerSerialNumber.rawValue)); lua_setfield(L, -2, "tabletProximityEventVendorPointerSerialNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventVendorUniqueID.rawValue)); lua_setfield(L, -2, "tabletProximityEventVendorUniqueID")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventCapabilityMask.rawValue)); lua_setfield(L, -2, "tabletProximityEventCapabilityMask")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventPointerType.rawValue));   lua_setfield(L, -2, "tabletProximityEventPointerType")
    lua_pushinteger(L, lua_Integer(CGEventField.tabletProximityEventEnterProximity.rawValue)); lua_setfield(L, -2, "tabletProximityEventEnterProximity")
    lua_pushinteger(L, lua_Integer(CGEventField.eventTargetProcessSerialNumber.rawValue));    lua_setfield(L, -2, "eventTargetProcessSerialNumber")
    lua_pushinteger(L, lua_Integer(CGEventField.eventTargetUnixProcessID.rawValue));          lua_setfield(L, -2, "eventTargetUnixProcessID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceUnixProcessID.rawValue));          lua_setfield(L, -2, "eventSourceUnixProcessID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceUserData.rawValue));               lua_setfield(L, -2, "eventSourceUserData")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceUserID.rawValue));                 lua_setfield(L, -2, "eventSourceUserID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceGroupID.rawValue));                lua_setfield(L, -2, "eventSourceGroupID")
    lua_pushinteger(L, lua_Integer(CGEventField.eventSourceStateID.rawValue));                lua_setfield(L, -2, "eventSourceStateID")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventIsContinuous.rawValue));      lua_setfield(L, -2, "scrollWheelEventIsContinuous")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventScrollPhase.rawValue));       lua_setfield(L, -2, "scrollWheelEventScrollPhase")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventScrollCount.rawValue));       lua_setfield(L, -2, "scrollWheelEventScrollCount")
    lua_pushinteger(L, lua_Integer(CGEventField.scrollWheelEventMomentumPhase.rawValue));     lua_setfield(L, -2, "scrollWheelEventMomentumPhase")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventWindowUnderMousePointer.rawValue)); lua_setfield(L, -2, "mouseEventWindowUnderMousePointer")
    lua_pushinteger(L, lua_Integer(CGEventField.mouseEventWindowUnderMousePointerThatCanHandleThisEvent.rawValue)); lua_setfield(L, -2, "mouseEventWindowUnderMousePointerThatCanHandleThisEvent")
    lua_pushinteger(L, lua_Integer(CGEventField.eventUnacceleratedPointerMovementX.rawValue)); lua_setfield(L, -2, "eventUnacceleratedPointerMovementX")
    lua_pushinteger(L, lua_Integer(CGEventField.eventUnacceleratedPointerMovementY.rawValue)); lua_setfield(L, -2, "eventUnacceleratedPointerMovementY")
}

/// hs.eventtap.event.rawFlagMasks[]
/// Constant
/// A table containing key-value pairs describing the raw modifier flags which can be manipulated with [hs.eventtap.event:rawFlags](#rawFlags).
private func push_flagMasks(_ L: OpaquePointer!) -> Int32 {
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

// MARK: - __tostring and meta GC

private func event_userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let event = getEvent(L)
    let eventType = event.type

    let str = String(format: "%@: Event type: %d (%p)", EVENT_USERDATA_TAG, eventType.rawValue, lua_topointer(L, 1)!)
    lua_pushstring(L, str)
    return 1
}

private func event_meta_gc(_ L: OpaquePointer!) -> Int32 {
    if let source = eventSource {
        CFRelease(source)
        eventSource = nil
    }
    return 0
}

// MARK: - Flags metatable helpers

private func flagsFromTable(_ L: OpaquePointer!, arg: Int32) -> CGEventFlags {
    luaL_checktype(L, arg, LUA_TTABLE)

    var flags = CGEventFlags(rawValue: 0)

    lua_getfield(L, arg, "cmd")
    if lua_toboolean(L, -1) != 0 { flags.insert(.maskCommand) }

    lua_getfield(L, arg, "alt")
    if lua_toboolean(L, -1) != 0 { flags.insert(.maskAlternate) }

    lua_getfield(L, arg, "ctrl")
    if lua_toboolean(L, -1) != 0 { flags.insert(.maskControl) }

    lua_getfield(L, arg, "shift")
    if lua_toboolean(L, -1) != 0 { flags.insert(.maskShift) }

    lua_getfield(L, arg, "fn")
    if lua_toboolean(L, -1) != 0 { flags.insert(.maskSecondaryFn) }

    return flags
}

private func flagsFromArray(_ L: OpaquePointer!, arg: Int32) -> CGEventFlags {
    luaL_checktype(L, arg, LUA_TTABLE)

    var flags = CGEventFlags(rawValue: 0)
    lua_pushnil(L)
    while lua_next(L, arg) != 0 {
        guard let modifier = lua_tostring(L, -1) else {
            let skin = LuaSkin.shared(withState: L)
            skin.logBreadcrumb("hs.eventtap.event.flags: unexpected entry in modifiers table: \(lua_type(L, -1))")
            lua_pop(L, 1)
            continue
        }
        let mod = String(cString: modifier)
        if mod == "cmd" || mod == "⌘"       { flags.insert(.maskCommand) }
        else if mod == "ctrl" || mod == "⌃"  { flags.insert(.maskControl) }
        else if mod == "alt" || mod == "⌥"   { flags.insert(.maskAlternate) }
        else if mod == "shift" || mod == "⇧" { flags.insert(.maskShift) }
        else if mod == "fn"                   { flags.insert(.maskSecondaryFn) }
        lua_pop(L, 1)
    }

    return flags
}

private func flags_contain(_ L: OpaquePointer!) -> Int32 {
    let eventFlags = flagsFromTable(L, arg: 1)
    let flags = flagsFromArray(L, arg: 2)

    lua_pushboolean(L, (eventFlags.rawValue & flags.rawValue) == flags.rawValue ? 1 : 0)
    return 1
}

private func flags_containExactly(_ L: OpaquePointer!) -> Int32 {
    let eventFlags = flagsFromTable(L, arg: 1)
    let flags = flagsFromArray(L, arg: 2)

    lua_pushboolean(L, eventFlags == flags ? 1 : 0)
    return 1
}

// MARK: - NSTouch push helper

private func NSTouch_toLua(_ L: OpaquePointer!, obj: AnyObject) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let touch = obj as! NSTouch

    lua_newtable(L)

    let type = touch.type
    switch type {
    case .direct:   lua_pushstring(L, "direct")
    case .indirect: lua_pushstring(L, "indirect")
    @unknown default:
        lua_pushfstring(L, "** unrecognized type: %d", Int32(type.rawValue))
    }
    lua_setfield(L, -2, "type")

    lua_pushfstring(L, "%p", Unmanaged.passUnretained(touch.identity as AnyObject).toOpaque())
    lua_setfield(L, -2, "identity")

    let phase = touch.phase
    switch phase {
    case .began:       lua_pushstring(L, "began")
    case .moved:       lua_pushstring(L, "moved")
    case .stationary:  lua_pushstring(L, "stationary")
    case .ended:       lua_pushstring(L, "ended")
    case .cancelled:   lua_pushstring(L, "cancelled")
    case .touching, .any:
        lua_pushnil(L)
    default:
        lua_pushfstring(L, "** unrecognized phase: %d", Int32(phase.rawValue))
    }
    lua_setfield(L, -2, "phase")

    lua_pushboolean(L, phase.contains(.touching) ? 1 : 0)
    lua_setfield(L, -2, "touching")

    if touch.type == .indirect {
        skin.pushNSPoint(touch.normalizedPosition)
        lua_setfield(L, -2, "normalizedPosition")
        skin.pushNSPoint(touch.previousNormalizedPosition)
        lua_setfield(L, -2, "previousNormalizedPosition")
    } else {
        skin.pushNSPoint(touch.location(in: nil))
        lua_setfield(L, -2, "location")
        skin.pushNSPoint(touch.previousLocation(in: nil))
        lua_setfield(L, -2, "previousLocation")
    }

    lua_pushnumber(L, touch.timestamp)
    lua_setfield(L, -2, "timestamp")

    let force = touch._force()
    lua_pushnumber(L, force)
    lua_setfield(L, -2, "force")

    lua_pushboolean(L, touch.isResting ? 1 : 0)
    lua_setfield(L, -2, "resting")

    lua_pushfstring(L, "%p", Unmanaged.passUnretained(touch.device as AnyObject).toOpaque())
    lua_setfield(L, -2, "device")

    skin.pushNSSize(touch.deviceSize)
    lua_setfield(L, -2, "deviceSize")

    return 1
}

// MARK: - luaL_Reg tables

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
    luaL_Reg(name: nil,                       func: nil),
]

private var eventtapeventlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("newGesture"),        func: eventtap_event_newGesture),
    luaL_Reg(name: strdup("newEvent"),          func: eventtap_event_newEvent),
    luaL_Reg(name: strdup("newEventFromData"),  func: eventtap_event_newEventFromData),
    luaL_Reg(name: strdup("newKeyEvent"),       func: eventtap_event_newKeyEvent),
    luaL_Reg(name: strdup("newSystemKeyEvent"), func: eventtap_event_newSystemKeyEvent),
    luaL_Reg(name: strdup("_newMouseEvent"),    func: eventtap_event_newMouseEvent),
    luaL_Reg(name: strdup("newScrollEvent"),    func: eventtap_event_newScrollWheelEvent),
    luaL_Reg(name: nil,                         func: nil),
]

private let event_meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: event_meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libeventtapevent")
public func luaopen_hs_libeventtapevent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.registerLibrary(
        withObject: EVENT_USERDATA_TAG,
        functions: eventtapeventlib,
        metaFunctions: event_meta_gcLib,
        objectFunctions: eventtapevent_metalib
    )

    pushtypestable(L)
    lua_setfield(L, -2, "types")

    pushpropertiestable(L)
    lua_setfield(L, -2, "properties")

    push_flagMasks(L)
    lua_setfield(L, -2, "rawFlagMasks")

    eventSource = nil

    luaL_newmetatable(L, FLAGS_TAG)

    lua_newtable(L)
    lua_pushcfunction(L, flags_contain)
    lua_setfield(L, -2, "contain")
    lua_pushcfunction(L, flags_containExactly)
    lua_setfield(L, -2, "containExactly")

    lua_setfield(L, -2, "__index")
    lua_pop(L, 1)

    eventSource = CGEventSource(stateID: .privateState)

    skin.registerPushNSHelper(NSTouch_toLua, forClass: "NSTouch")

    return 1
}
