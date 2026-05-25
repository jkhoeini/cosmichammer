import Cocoa
import LuaSkin

// MARK: axtextmarker.m — AXTextMarker / AXTextMarkerRange
// MARK: ============================================================

var textmarkerRefTable: LSRefTable = LUA_NOREF

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
private func axtextmarker_newMarker(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let bytesAsData = skin.toNSObject(atIndex: 1, withOptions: .nsLuaStringAsDataOnly) as! NSData
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
private func axtextmarker_newRange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_AXTEXTMARKER_TAG, LS_TUSERDATA, axuielement_AXTEXTMARKER_TAG, LS_TBREAK)
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

private func axtextmarker_AXTextMarkerGetTypeID_fn(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    lua_pushinteger(L, lua_Integer(AXTextMarkerGetTypeID()))
    return 1
}

private func axtextmarker_AXTextMarkerRangeGetTypeID_fn(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    lua_pushinteger(L, lua_Integer(AXTextMarkerRangeGetTypeID()))
    return 1
}

/// hs.axuielement.axtextmarker._functionCheck() -> table
private func axtextmarker_availabilityCheck(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

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
private func axtextmarker_markerBytes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_AXTEXTMARKER_TAG, LS_TBREAK)
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
private func axtextmarker_markerLength(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_AXTEXTMARKER_TAG, LS_TBREAK)
    let marker = get_axtextmarkerref(L, 1, axuielement_AXTEXTMARKER_TAG)

    lua_pushinteger(L, lua_Integer(AXTextMarkerGetLength(marker)))
    return 1
}

/// hs.axuielement.axtextmarker:startMarker() -> axTextMarkerObject | nil, errorString
private func axtextmarker_rangeStartMarker(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_AXTEXTMRKRNG_TAG, LS_TBREAK)
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
private func axtextmarker_rangeEndMarker(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_AXTEXTMRKRNG_TAG, LS_TBREAK)
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

private func textmarker_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let tag = luaL_testudata(L, 1, axuielement_AXTEXTMARKER_TAG) != nil ? axuielement_AXTEXTMARKER_TAG : axuielement_AXTEXTMRKRNG_TAG
    let tagStr = String(cString: tag)
    let ptr = Int(bitPattern: lua_topointer(L, 1))
    skin.pushNSObject(NSString(format: "%@: (0x%lx)", tagStr as NSString, ptr))
    return 1
}

private func textmarker_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

private func textmarker_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = UnsafeMutableRawPointer(lua_touserdata(L, 1))!.assumingMemoryBound(to: Unmanaged<CFTypeRef>.self)
    ptr.pointee.release()
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for marker userdata
private var marker_userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("bytes"),      func: axtextmarker_markerBytes),
    luaL_Reg(name: strdup("length"),     func: axtextmarker_markerLength),
    luaL_Reg(name: strdup("__tostring"), func: textmarker_userdata_tostring),
    luaL_Reg(name: strdup("__eq"),       func: textmarker_userdata_eq),
    luaL_Reg(name: strdup("__gc"),       func: textmarker_userdata_gc),
    luaL_Reg(name: nil,                  func: nil),
]

// Metatable for range userdata
private var range_userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("startMarker"), func: axtextmarker_rangeStartMarker),
    luaL_Reg(name: strdup("endMarker"),   func: axtextmarker_rangeEndMarker),
    luaL_Reg(name: strdup("__tostring"),  func: textmarker_userdata_tostring),
    luaL_Reg(name: strdup("__eq"),        func: textmarker_userdata_eq),
    luaL_Reg(name: strdup("__gc"),        func: textmarker_userdata_gc),
    luaL_Reg(name: nil,                   func: nil),
]

// Module functions
private var textmarker_moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("newMarker"),      func: axtextmarker_newMarker),
    luaL_Reg(name: strdup("newRange"),       func: axtextmarker_newRange),
    luaL_Reg(name: strdup("_markerID"),      func: axtextmarker_AXTextMarkerGetTypeID_fn),
    luaL_Reg(name: strdup("_rangeID"),       func: axtextmarker_AXTextMarkerRangeGetTypeID_fn),
    luaL_Reg(name: strdup("_functionCheck"), func: axtextmarker_availabilityCheck),
    luaL_Reg(name: nil,                      func: nil),
]

@_cdecl("luaopen_hs_axuielement_axtextmarker")
@discardableResult
public func luaopen_hs_axuielement_axtextmarker(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    textmarkerRefTable = skin.registerLibrary(withObject: axuielement_AXTEXTMARKER_TAG,
                                              functions: &textmarker_moduleLib,
                                              metaFunctions: nil,
                                              objectFunctions: &marker_userdata_metaLib)
    skin.registerObject(axuielement_AXTEXTMRKRNG_TAG, objectFunctions: &range_userdata_metaLib)
    return 1
}

// MARK: ============================================================
