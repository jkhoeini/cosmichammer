/// === hs.axuielement.axtextmarker ===
///
/// This submodule allows hs.axuielement to support using AXTextMarker and AXTextMarkerRange objects as parameters for parameterized Accessibility attributes with applications that support them.
///
/// Most Accessibility object values correspond to the common data types found in most programming languages -- strings, numbers, tables (arrays and dictionaries), etc. AXTextMarker and AXTextMarkerRange types are application specific and do not have a direct mapping to a simple data type. The description I've found most apt comes from comments within the Chromium source for the Mac version of their browser:
///
/// > // A serialization of a position as POD. Not for sharing on disk or sharing
/// > // across thread or process boundaries, just for passing a position to an
/// > // API that works with positions as opaque objects.
///
/// This submodule allows Lua to represent these as userdata which can be passed in to parameterized attributes for the application from which they were retrieved. Examples are expected to be added to the Hammerspoon wiki soon.
///
/// As this submodule utilizes private and undocumented functions in the HIServices framework, if you receive an error using any of these functions or methods indicating an undefined CF function (the function or method will return nil and a string of the format "CF function AX... undefined"), please make sure to include the output of the following in any issue you submit to the Hammerspoon github page (enter these into the Hammerspoon console):
///
///     hs.inspect(hs.axuielement.axtextmarker._functionCheck())
///     hs.inspect(hs.processInfo)
///     hs.host.operatingSystemVersionString()

import Cocoa
import LuaSkin

private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions

@_cdecl("pushAXTextMarker")
@discardableResult
public func pushAXTextMarker(_ L: OpaquePointer!, _ theElement: AXTextMarkerRef) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<AXTextMarkerRef>.size)!
        .assumingMemoryBound(to: AXTextMarkerRef.self)
    thePtr.pointee = CFRetain(theElement) as! AXTextMarkerRef
    luaL_getmetatable(L, AXTEXTMARKER_TAG)
    lua_setmetatable(L, -2)
    return 1
}

@_cdecl("pushAXTextMarkerRange")
@discardableResult
public func pushAXTextMarkerRange(_ L: OpaquePointer!, _ theElement: AXTextMarkerRangeRef) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<AXTextMarkerRangeRef>.size)!
        .assumingMemoryBound(to: AXTextMarkerRangeRef.self)
    thePtr.pointee = CFRetain(theElement) as! AXTextMarkerRangeRef
    luaL_getmetatable(L, AXTEXTMRKRNG_TAG)
    lua_setmetatable(L, -2)
    return 1
}

// MARK: - Module Functions

/// hs.axuielement.axtextmarker.newMarker(string) -> axTextMarkerObject | nil, errorString
/// Constructor
/// Creates a new AXTextMarker object from the string of binary data provided
///
/// Parameters:
///  * `string` - a string containing 1 or more bytes of data for the AXTextMarker object
///
/// Returns:
///  * a new axTextMarkerObject or nil and a string description if there was an error
///
/// Notes:
///  * This function is included primarily for testing and debugging purposes -- in general you will probably never use this constructor; AXTextMarker objects appear to be mostly application dependant and have no meaning external to the application from which it was created.
private func axtextmarker_newMarker(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let bytesAsData = skin.toNSObject(atIndex: 1, withOptions: LS_NSLuaStringAsDataOnly) as! NSData
    if let marker = AXTextMarkerCreate(kCFAllocatorDefault, bytesAsData.bytes.assumingMemoryBound(to: UInt8.self), CFIndex(bytesAsData.length)) {
        pushAXTextMarker(L, marker)
        CFRelease(marker)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "unable to create marker with specified data string")
        return 2
    }

    return 1
}

/// hs.axuielement.axtextmarker.newRange(startMarker, endMarker) -> axTextMarkerRangeObject | nil, errorString
/// Constructor
/// Creates a new AXTextMarkerRange object from the start and end markers provided
///
/// Parameters:
///  * `startMarker` - an axTextMarkerObject representing the start of the range to be created
///  * `endMarker`   - an axTextMarkerObject representing the end of the range to be created
///
/// Returns:
///  * a new axTextMarkerRangeObject or nil and a string description if there was an error
///
/// Notes:
///  * this constructor can be used to create a range from axTextMarkerObjects obtained from an application to specify a new range for a parameterized attribute. As a simple example (it is hoped that more will be added to the Hammerspoon wiki shortly):
///     ```lua
///     s = hs.axuielement.applicationElement(hs.application("Safari"))
///     -- for a window displaying the DuckDuckGo main search page, this gets the
///     -- primary display area. Other pages may vary and you should build your
///     -- object as necessary for your target.
///     c = s("AXMainWindow")("AXSections")[1].SectionObject[1][1]
///     start = c("AXStartTextMarker") -- get the text marker for the start of this element
///     ending = c("AXNextLineEndTextMarkerForTextMarker", start) -- get the next end of line marker
///     print(c("AXStringForTextMarkerRange", hs.axuielement.axtextmarker.newRange(start, ending)))
///     -- outputs "Privacy, simplified." to the Hammerspoon console```
///  * The specific attributes and parameterized attributes supported by a given application differ and can be discovered with the `hs.axuielement:getAttributeNames` and `hs.axuielement:getParameterizedAttributeNames` methods.
private func axtextmarker_newRange(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TBREAK)
    let startMarker = get_axtextmarkerref(L, 1, AXTEXTMARKER_TAG)
    let endMarker = get_axtextmarkerref(L, 2, AXTEXTMARKER_TAG)

    if let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, startMarker, endMarker) {
        pushAXTextMarkerRange(L, range)
        CFRelease(range)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "invalid start or end marker for range")
        return 2
    }

    return 1
}

// hs.axuielement.axtextmarker._markerID() -> integer | nil, errorString
// Function
// Returns the CFTypeID for the AXTextMarkerRef type
//
// This is for debugging purposes and is not publicly documented
private func axtextmarker_AXTextMarkerGetTypeID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)

    lua_pushinteger(L, lua_Integer(AXTextMarkerGetTypeID()))
    return 1
}

// hs.axuielement.axtextmarker._rangeID() -> integer | nil, errorString
// Function
// Returns the CFTypeID for the AXTextMarkerRangeRef type
//
// This is for debugging purposes and is not publicly documented
private func axtextmarker_AXTextMarkerRangeGetTypeID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)

    lua_pushinteger(L, lua_Integer(AXTextMarkerRangeGetTypeID()))

    return 1
}

/// hs.axuielement.axtextmarker._functionCheck() -> table
/// Function
/// Returns a table of the AXTextMarker and AXTextMarkerRange functions that have been discovered and are used within this module.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table with key-value pairs where the keys correspond to the undocumented Core Foundation functions required by this module to support AXTextMarker and AXTextMarkerRange and the value will be a boolean indicating whether the function exists in the currently loaded frameworks.
///
/// Notes:
///  * the functions are defined within the HIServices framework which is part of the ApplicationServices framework, so it is expected that the necessary functions will always be available; however, if you ever receive an error message from a function or method within this submodule of the form "CF function AX... undefined", please see the submodule heading documentation for a description of the information, including that which this function provides, that should be included in any error report you submit.
///  * This is for debugging purposes and is not expected to be used often.
private func axtextmarker_availabilityCheck(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)

    lua_newtable(L)
    lua_pushboolean(L, 1);            lua_setfield(L, -2, "AXTextMarkerGetTypeID")
    lua_pushboolean(L, 1);               lua_setfield(L, -2, "AXTextMarkerCreate")
    lua_pushboolean(L, 1);            lua_setfield(L, -2, "AXTextMarkerGetLength")
    lua_pushboolean(L, 1);           lua_setfield(L, -2, "AXTextMarkerGetBytePtr")
    lua_pushboolean(L, 1);       lua_setfield(L, -2, "AXTextMarkerRangeGetTypeID")
    lua_pushboolean(L, 1);          lua_setfield(L, -2, "AXTextMarkerRangeCreate")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerRangeCopyStartMarker")
    lua_pushboolean(L, 1);   lua_setfield(L, -2, "AXTextMarkerRangeCopyEndMarker")
    return 1
}

// MARK: - Module Methods

/// hs.axuielement.axtextmarker:bytes() -> string | nil, errorString
/// Function
/// Returns a string containing the opaque binary data contained within the axTextMarkerObject
///
/// Parameters:
///  * None
///
/// Returns:
///  *  a string containing the opaque binary data contained within the axTextMarkerObject
///
/// Notes:
///  * the string will likely contain invalid UTF8 code sequences or unprintable ascii values; to see the data in decimal or hexadecimal form you can use:
///     string.byte(hs.axuielement.axtextmarker:bytes(), 1, hs.axuielement.axtextmarker:length())
///     -- or
///     hs.utf8.hexDump(hs.axuielement.axtextmarker:bytes())
///  * As the data is application specific, it is unlikely that you will use this method often; it is included primarily for testing and debugging purposes.
private func axtextmarker_markerBytes(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TBREAK)
    let marker = get_axtextmarkerref(L, 1, AXTEXTMARKER_TAG)

    let length = AXTextMarkerGetLength(marker)
    lua_pushlstring(L, AXTextMarkerGetBytePtr(marker), Int(length))
    return 1
}

/// hs.axuielement.axtextmarker:length() -> integer | nil, errorString
/// Function
/// Returns an integer specifying the number of bytes in the data portion of the axTextMarkerObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  *  an integer specifying the number of bytes in the data portion of the axTextMarkerObject
///
/// Notes:
///  * As the data is application specific, it is unlikely that you will use this method often; it is included primarily for testing and debugging purposes.
private func axtextmarker_markerLength(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TBREAK)
    let marker = get_axtextmarkerref(L, 1, AXTEXTMARKER_TAG)

    lua_pushinteger(L, lua_Integer(AXTextMarkerGetLength(marker)))
    return 1
}

/// hs.axuielement.axtextmarker:startMarker() -> axTextMarkerObject | nil, errorString
/// Function
/// Returns the starting marker for an axTextMarkerRangeObject
///
/// Parameters:
///  * None
///
/// Returns:
///  *  the starting marker for an axTextMarkerRangeObject
private func axtextmarker_rangeStartMarker(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, AXTEXTMRKRNG_TAG, LS_TBREAK)
    let range = get_axtextmarkerrangeref(L, 1, AXTEXTMRKRNG_TAG)

    if let marker = AXTextMarkerRangeCopyStartMarker(range) {
        pushAXTextMarker(L, marker)
        CFRelease(marker)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "startMarker NULL for range")
        return 2
    }

    return 1
}

/// hs.axuielement.axtextmarker:endMarker() -> axTextMarkerObject | nil, errorString
/// Function
/// Returns the ending marker for an axTextMarkerRangeObject
///
/// Parameters:
///  * None
///
/// Returns:
///  *  the ending marker for an axTextMarkerRangeObject
private func axtextmarker_rangeEndMarker(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, AXTEXTMRKRNG_TAG, LS_TBREAK)
    let range = get_axtextmarkerrangeref(L, 1, AXTEXTMRKRNG_TAG)

    if let marker = AXTextMarkerRangeCopyEndMarker(range) {
        pushAXTextMarker(L, marker)
        CFRelease(marker)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "endMarker NULL for range")
        return 2
    }

    return 1
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!

    let tag = luaL_testudata(L, 1, AXTEXTMARKER_TAG) != nil ? AXTEXTMARKER_TAG : AXTEXTMRKRNG_TAG
    skin.pushNSObject(NSString(format: "%s: (%p)", tag, lua_topointer(L, 1)))
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    if (luaL_testudata(L, 1, AXTEXTMARKER_TAG) != nil && luaL_testudata(L, 2, AXTEXTMARKER_TAG) != nil) ||
       (luaL_testudata(L, 1, AXTEXTMRKRNG_TAG) != nil && luaL_testudata(L, 2, AXTEXTMRKRNG_TAG) != nil) {
        let theRef1 = lua_touserdata(L, 1)!.assumingMemoryBound(to: CFTypeRef.self).pointee!
        let theRef2 = lua_touserdata(L, 2)!.assumingMemoryBound(to: CFTypeRef.self).pointee!
        lua_pushboolean(L, CFEqual(theRef1, theRef2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let theRef = lua_touserdata(L, 1)!.assumingMemoryBound(to: CFTypeRef.self).pointee!
    CFRelease(theRef)
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for marker userdata objects
private var marker_userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("bytes"),      func: axtextmarker_markerBytes),
    luaL_Reg(name: strdup("length"),     func: axtextmarker_markerLength),

    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),       func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),       func: userdata_gc),
    luaL_Reg(name: nil,                  func: nil),
]

// Metatable for range userdata objects
private var range_userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("startMarker"), func: axtextmarker_rangeStartMarker),
    luaL_Reg(name: strdup("endMarker"),   func: axtextmarker_rangeEndMarker),

    luaL_Reg(name: strdup("__tostring"),  func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),        func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),        func: userdata_gc),
    luaL_Reg(name: nil,                   func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("newMarker"),      func: axtextmarker_newMarker),
    luaL_Reg(name: strdup("newRange"),       func: axtextmarker_newRange),

    luaL_Reg(name: strdup("_markerID"),      func: axtextmarker_AXTextMarkerGetTypeID),
    luaL_Reg(name: strdup("_rangeID"),       func: axtextmarker_AXTextMarkerRangeGetTypeID),
    luaL_Reg(name: strdup("_functionCheck"), func: axtextmarker_availabilityCheck),

    luaL_Reg(name: nil,                      func: nil),
]

@_cdecl("luaopen_hs_axuielement_axtextmarker")
public func luaopen_hs_axuielement_axtextmarker(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary(withObject: AXTEXTMARKER_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &marker_userdata_metaLib)

    skin.registerObject(AXTEXTMRKRNG_TAG, objectFunctions: &range_userdata_metaLib)

    return 1
}
