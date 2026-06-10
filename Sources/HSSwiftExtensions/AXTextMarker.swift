import Cocoa
import CLua
import Lua

// MARK: axtextmarker.m — AXTextMarker / AXTextMarkerRange
// MARK: ============================================================

var textmarkerRefTable: Int32 = LUA_NOREF

// MARK: - Push Helpers

@_cdecl("pushAXTextMarker")
@discardableResult
public func pushAXTextMarker(_ L: UnsafeMutablePointer<lua_State>!, _ theElement: CFTypeRef) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<Unmanaged<CFTypeRef>>.size)!
        .assumingMemoryBound(to: Unmanaged<CFTypeRef>.self)
    thePtr.pointee = Unmanaged.passRetained(theElement as CFTypeRef)
    luaL_getmetatable(L, axuielement_AXTEXTMARKER_TAG)
    lua_setmetatable(L, -2)
    return 1
}

@_cdecl("pushAXTextMarkerRange")
@discardableResult
public func pushAXTextMarkerRange(_ L: UnsafeMutablePointer<lua_State>!, _ theElement: CFTypeRef) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<Unmanaged<CFTypeRef>>.size)!
        .assumingMemoryBound(to: Unmanaged<CFTypeRef>.self)
    thePtr.pointee = Unmanaged.passRetained(theElement as CFTypeRef)
    luaL_getmetatable(L, axuielement_AXTEXTMRKRNG_TAG)
    lua_setmetatable(L, -2)
    return 1
}

// MARK: - Module Functions

/// hs.axuielement.axtextmarker.newMarker(string) -> axTextMarkerObject | nil, errorString
private func axtextmarker_newMarker(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    var len: Int = 0
    let bytes = lua_tolstring(L, 1, &len)!
    let bytesAsData = NSData(bytes: bytes, length: len)
    if let marker = AXTextMarkerCreate(kCFAllocatorDefault, bytesAsData.bytes.assumingMemoryBound(to: UInt8.self), bytesAsData.length) {
        pushAXTextMarker(L, marker)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "unable to create marker with specified data string")
        return 2
    }
    return 1
}

/// hs.axuielement.axtextmarker.newRange(startMarker, endMarker) -> axTextMarkerRangeObject | nil, errorString
private func axtextmarker_newRange(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_AXTEXTMARKER_TAG)
    luaL_checkudata(L, 2, axuielement_AXTEXTMARKER_TAG)
    let startMarker = get_axtextmarkerref(L, 1, axuielement_AXTEXTMARKER_TAG)
    let endMarker   = get_axtextmarkerref(L, 2, axuielement_AXTEXTMARKER_TAG)

    if let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, startMarker, endMarker) {
        pushAXTextMarkerRange(L, range)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "invalid start or end marker for range")
        return 2
    }
    return 1
}

private func axtextmarker_AXTextMarkerGetTypeID_fn(_ L: LuaState) throws -> CInt {
    lua_pushinteger(L, lua_Integer(AXTextMarkerGetTypeID()))
    return 1
}

private func axtextmarker_AXTextMarkerRangeGetTypeID_fn(_ L: LuaState) throws -> CInt {
    lua_pushinteger(L, lua_Integer(AXTextMarkerRangeGetTypeID()))
    return 1
}

/// hs.axuielement.axtextmarker._functionCheck() -> table
private func axtextmarker_availabilityCheck(_ L: LuaState) throws -> CInt {
    lua_newtable(L)
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerGetTypeID")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerCreate")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerGetLength")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerGetBytePtr")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerRangeGetTypeID")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerRangeCreate")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerRangeCopyStartMarker")
    lua_pushboolean(L, 1); lua_setfield(L, -2, "AXTextMarkerRangeCopyEndMarker")
    return 1
}

// MARK: - Module Methods

/// hs.axuielement.axtextmarker:bytes() -> string
private func axtextmarker_markerBytes(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_AXTEXTMARKER_TAG)
    let marker = get_axtextmarkerref(L, 1, axuielement_AXTEXTMARKER_TAG)

    let length = AXTextMarkerGetLength(marker)
    if let bytePtr = AXTextMarkerGetBytePtr(marker) {
        lua_pushlstring(L, bytePtr.withMemoryRebound(to: CChar.self, capacity: Int(length)) { $0 }, Int(length))
    } else {
        lua_pushlstring(L, nil, 0)
    }
    return 1
}

/// hs.axuielement.axtextmarker:length() -> integer
private func axtextmarker_markerLength(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_AXTEXTMARKER_TAG)
    let marker = get_axtextmarkerref(L, 1, axuielement_AXTEXTMARKER_TAG)

    lua_pushinteger(L, lua_Integer(AXTextMarkerGetLength(marker)))
    return 1
}

/// hs.axuielement.axtextmarker:startMarker() -> axTextMarkerObject | nil, errorString
private func axtextmarker_rangeStartMarker(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_AXTEXTMRKRNG_TAG)
    let range = get_axtextmarkerrangeref(L, 1, axuielement_AXTEXTMRKRNG_TAG)

    if let marker = AXTextMarkerRangeCopyStartMarker(range) {
        pushAXTextMarker(L, marker)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "startMarker NULL for range")
        return 2
    }
    return 1
}

/// hs.axuielement.axtextmarker:endMarker() -> axTextMarkerObject | nil, errorString
private func axtextmarker_rangeEndMarker(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_AXTEXTMRKRNG_TAG)
    let range = get_axtextmarkerrangeref(L, 1, axuielement_AXTEXTMRKRNG_TAG)

    if let marker = AXTextMarkerRangeCopyEndMarker(range) {
        pushAXTextMarker(L, marker)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "endMarker NULL for range")
        return 2
    }
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure (textmarker)

private func textmarker_userdata_tostring(_ L: LuaState) throws -> CInt {
    let tag = luaL_testudata(L, 1, axuielement_AXTEXTMARKER_TAG) != nil ? axuielement_AXTEXTMARKER_TAG : axuielement_AXTEXTMRKRNG_TAG
    let tagStr = String(cString: tag)
    let desc = "\(tagStr): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, desc)
    return 1
}

private func textmarker_userdata_eq(_ L: LuaState) throws -> CInt {
    if (luaL_testudata(L, 1, axuielement_AXTEXTMARKER_TAG) != nil && luaL_testudata(L, 2, axuielement_AXTEXTMARKER_TAG) != nil) ||
       (luaL_testudata(L, 1, axuielement_AXTEXTMRKRNG_TAG) != nil && luaL_testudata(L, 2, axuielement_AXTEXTMRKRNG_TAG) != nil) {
        let ref1 = UnsafeRawPointer(lua_touserdata(L, 1))!.assumingMemoryBound(to: Unmanaged<CFTypeRef>.self).pointee.takeUnretainedValue()
        let ref2 = UnsafeRawPointer(lua_touserdata(L, 2))!.assumingMemoryBound(to: Unmanaged<CFTypeRef>.self).pointee.takeUnretainedValue()
        lua_pushboolean(L, CFEqual(ref1, ref2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func textmarker_userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = UnsafeMutableRawPointer(lua_touserdata(L, 1))!.assumingMemoryBound(to: Unmanaged<CFTypeRef>.self)
    ptr.pointee.release()
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

@_cdecl("luaopen_hs_axuielement_axtextmarker")
@discardableResult
public func luaopen_hs_axuielement_axtextmarker(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        textmarkerRefTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register marker userdata metatable
        luaL_newmetatable(L, axuielement_AXTEXTMARKER_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(axtextmarker_markerBytes)
        lua_setfield(L, -2, "bytes")
        L.push(axtextmarker_markerLength)
        lua_setfield(L, -2, "length")
        L.push(textmarker_userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(textmarker_userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(textmarker_userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Register range userdata metatable
        luaL_newmetatable(L, axuielement_AXTEXTMRKRNG_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(axtextmarker_rangeStartMarker)
        lua_setfield(L, -2, "startMarker")
        L.push(axtextmarker_rangeEndMarker)
        lua_setfield(L, -2, "endMarker")
        L.push(textmarker_userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(textmarker_userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(textmarker_userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 5)
        L.push(axtextmarker_newMarker)
        lua_setfield(L, -2, "newMarker")
        L.push(axtextmarker_newRange)
        lua_setfield(L, -2, "newRange")
        L.push(axtextmarker_AXTextMarkerGetTypeID_fn)
        lua_setfield(L, -2, "_markerID")
        L.push(axtextmarker_AXTextMarkerRangeGetTypeID_fn)
        lua_setfield(L, -2, "_rangeID")
        L.push(axtextmarker_availabilityCheck)
        lua_setfield(L, -2, "_functionCheck")
    }
}

// MARK: ============================================================
