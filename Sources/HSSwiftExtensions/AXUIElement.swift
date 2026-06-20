// libaxuielement_new.swift
//
// Swift port of common.m, observer.m, and axtextmarker.m for hs.axuielement.
// These were originally four ObjC files; this single Swift file consolidates
// the shared helpers (common), the AXObserver wrapper (observer), and the
// AXTextMarker/AXTextMarkerRange wrappers (axtextmarker).

import Cocoa
import CLua
import os.log

// MARK: - Tag Constants

// These were #define in common.h.  They must be visible to AXUIElement.swift
// (same SPM target), so they are internal (not private).
// Use specific prefix to avoid colliding with other files' private USERDATA_TAG.
// AXUIElement.swift references these by their prefixed names.
//
// StaticString.utf8Start gives a stable UnsafePointer<UInt8> whose lifetime
// is the entire program run, so rebinding to CChar is safe.
private func staticCString(_ s: StaticString) -> UnsafePointer<CChar> {
    UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self)
}

let axuielement_USERDATA_TAG     = staticCString("hs.axuielement")
let axuielement_OBSERVER_TAG     = staticCString("hs.axuielement.observer")
let axuielement_AXTEXTMARKER_TAG = staticCString("hs.axuielement.axtextmarker")
let axuielement_AXTEXTMRKRNG_TAG = staticCString("hs.axuielement.axtextmarkerrange")

// File-local aliases for readability within this file.
private let USERDATA_TAG     = axuielement_USERDATA_TAG
private let OBSERVER_TAG     = axuielement_OBSERVER_TAG
private let AXTEXTMARKER_TAG = axuielement_AXTEXTMARKER_TAG
private let AXTEXTMRKRNG_TAG = axuielement_AXTEXTMRKRNG_TAG

// MARK: - Userdata Extraction Helpers

/// Equivalent of #define get_axuielementref(L, idx, tag) in common.h
func get_axuielementref(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> AXUIElement {
    let ptr = luaL_checkudata(L, idx, tag)!
    return ptr.assumingMemoryBound(to: Unmanaged<AXUIElement>.self).pointee.takeUnretainedValue()
}

/// Equivalent of #define get_axobserverref(L, idx, tag) in common.h
func get_axobserverref(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> AXObserver {
    let ptr = luaL_checkudata(L, idx, tag)!
    return ptr.assumingMemoryBound(to: Unmanaged<AXObserver>.self).pointee.takeUnretainedValue()
}

/// Equivalent of #define get_axtextmarkerref(L, idx, tag) in common.h
func get_axtextmarkerref(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> CFTypeRef {
    let ptr = luaL_checkudata(L, idx, tag)!
    return ptr.assumingMemoryBound(to: Unmanaged<CFTypeRef>.self).pointee.takeUnretainedValue() as CFTypeRef
}

/// Equivalent of #define get_axtextmarkerrangeref(L, idx, tag) in common.h
func get_axtextmarkerrangeref(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> CFTypeRef {
    let ptr = luaL_checkudata(L, idx, tag)!
    return ptr.assumingMemoryBound(to: Unmanaged<CFTypeRef>.self).pointee.takeUnretainedValue() as CFTypeRef
}

// MARK: - AXTextMarker Private API Declarations

// These are private HIServices functions.  On modern macOS they are always
// available; the ExternalReferences.h guard for < macOS 12 is no longer
// needed since the deployment target is macOS 15+.

@_silgen_name("AXTextMarkerGetTypeID")
func AXTextMarkerGetTypeID() -> CFTypeID

@_silgen_name("AXTextMarkerCreate")
func AXTextMarkerCreate(_ allocator: CFAllocator?, _ bytes: UnsafePointer<UInt8>, _ length: CFIndex) -> CFTypeRef?

@_silgen_name("AXTextMarkerGetLength")
func AXTextMarkerGetLength(_ marker: CFTypeRef) -> CFIndex

@_silgen_name("AXTextMarkerGetBytePtr")
func AXTextMarkerGetBytePtr(_ marker: CFTypeRef) -> UnsafePointer<UInt8>?

@_silgen_name("AXTextMarkerRangeGetTypeID")
func AXTextMarkerRangeGetTypeID() -> CFTypeID

@_silgen_name("AXTextMarkerRangeCreate")
func AXTextMarkerRangeCreate(_ allocator: CFAllocator?, _ startMarker: CFTypeRef, _ endMarker: CFTypeRef) -> CFTypeRef?

@_silgen_name("AXTextMarkerRangeCopyStartMarker")
func AXTextMarkerRangeCopyStartMarker(_ range: CFTypeRef) -> CFTypeRef?

@_silgen_name("AXTextMarkerRangeCopyEndMarker")
func AXTextMarkerRangeCopyEndMarker(_ range: CFTypeRef) -> CFTypeRef?

// pushAXUIElement and AXErrorAsString are defined in AXUIElement.swift
// (same module), so no forward declarations needed.

// MARK: ============================================================
// MARK: common.m — Shared Helpers
// MARK: ============================================================

// MARK: - getElementRefPropertyFromClassObject

@objc protocol PlaceHoldersHSuicoreMethods {
    func initWithPid(_ pid: pid_t, withState L: UnsafeMutablePointer<lua_State>!) -> NSObject?
    func initWithAXUIElementRef(_ winRef: AXUIElement) -> NSObject?
}

@_cdecl("getElementRefPropertyFromClassObject")
public func getElementRefPropertyFromClassObject(_ object: NSObject) -> AXUIElement? {
    let selector = NSSelectorFromString("elementRef")
    guard object.responds(to: selector) else { return nil }

    let imp = object.method(for: selector)
    typealias ElementRefIMP = @convention(c) (AnyObject, Selector) -> Unmanaged<AXUIElement>?
    let typedIMP = unsafeBitCast(imp, to: ElementRefIMP.self)
    guard let ref = typedIMP(object, selector) else { return nil }
    let element = ref.takeUnretainedValue()
    return element
}

@_cdecl("new_application")
@discardableResult
public func new_application(_ L: UnsafeMutablePointer<lua_State>!, _ pid: pid_t) -> Bool {
    let obj = HSapplication(pid: pid, withState: L)

    if let obj = obj, pushHSapplication(L, obj) != 0 {
        return true
    }
    lua_pushnil(L)
    return false
}

@_cdecl("new_window")
@discardableResult
public func new_window(_ L: UnsafeMutablePointer<lua_State>!, _ win: AXUIElement) -> Bool {
    let handle = ProductionWindowElement(element: win)
    pushWindowElement(L, handle)
    return true
}

// MARK: - pushCFTypeToLua / lua_toCFType

private func pushCFTypeHamster(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ theItem: CFTypeRef?,
    _ alreadySeen: NSMutableDictionary,
    _ refTable: Int32
) -> Int32 {

    guard let theItem = theItem else {
        lua_pushnil(L)
        return 1
    }

    let theType = CFGetTypeID(theItem)

    if theType == CFArrayGetTypeID() {
        if pushSeenOrRegister(L, theItem, alreadySeen) { return 1 }
        for thing in (theItem as! NSArray) {
            _ = pushCFTypeHamster(L, thing as CFTypeRef, alreadySeen, refTable)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else if theType == CFDictionaryGetTypeID() {
        if pushSeenOrRegister(L, theItem, alreadySeen) { return 1 }
        let dict = theItem as! NSDictionary
        for i in 0..<dict.allKeys.count {
            _ = pushCFTypeHamster(L, dict.allKeys[i] as CFTypeRef, alreadySeen, refTable)
            _ = pushCFTypeHamster(L, dict.allValues[i] as CFTypeRef, alreadySeen, refTable)
            lua_settable(L, -3)
        }
    } else if theType == AXValueGetTypeID() {
        pushAXValueToLua(L, theItem as! AXValue)
    } else {
        pushSimpleCFType(L, theItem, theType)
    }
    return 1
}

/// Returns true if the item was already seen (pushed from registry); otherwise
/// registers it and pushes the new table. Caller fills in the table contents.
private func pushSeenOrRegister(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ theItem: CFTypeRef,
    _ alreadySeen: NSMutableDictionary
) -> Bool {
    let seenKey = theItem as AnyObject
    if let seenRef = alreadySeen[seenKey] as? NSNumber {
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(seenRef.int32Value))
        return true
    }
    lua_newtable(L)
    let ref = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    let seenRef = NSNumber(value: ref)
    alreadySeen[seenKey] = seenRef
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(seenRef.int32Value))
    return false
}

/// Pushes an AXValue (point, size, rect, range, error) onto the Lua stack.
private func pushAXValueToLua(_ L: UnsafeMutablePointer<lua_State>!, _ axValue: AXValue) {
    let valueType = AXValueGetType(axValue)
    if valueType == .cgPoint {
        var pt = CGPoint.zero
        AXValueGetValue(axValue, .cgPoint, &pt)
        lua_newtable(L)
        L.push(lua_Number(pt.x)); lua_setfield(L, -2, "x")
        L.push(lua_Number(pt.y)); lua_setfield(L, -2, "y")
    } else if valueType == .cgSize {
        var sz = CGSize.zero
        AXValueGetValue(axValue, .cgSize, &sz)
        lua_newtable(L)
        L.push(lua_Number(sz.height)); lua_setfield(L, -2, "h")
        L.push(lua_Number(sz.width));  lua_setfield(L, -2, "w")
    } else if valueType == .cgRect {
        var rect = CGRect.zero
        AXValueGetValue(axValue, .cgRect, &rect)
        lua_newtable(L)
        L.push(lua_Number(rect.origin.x));    lua_setfield(L, -2, "x")
        L.push(lua_Number(rect.origin.y));    lua_setfield(L, -2, "y")
        L.push(lua_Number(rect.size.height)); lua_setfield(L, -2, "h")
        L.push(lua_Number(rect.size.width));  lua_setfield(L, -2, "w")
    } else if valueType == .cfRange {
        var range = CFRange(location: 0, length: 0)
        AXValueGetValue(axValue, .cfRange, &range)
        lua_newtable(L)
        L.push(lua_Integer(range.location)); lua_setfield(L, -2, "location")
        L.push(lua_Integer(range.length));   lua_setfield(L, -2, "length")
    } else if valueType == .axError {
        var err: AXError = .success
        AXValueGetValue(axValue, .axError, &err)
        lua_newtable(L)
        L.push(lua_Integer(err.rawValue));           lua_setfield(L, -2, "_code")
        L.push(String(cString: AXErrorAsString(err))); lua_setfield(L, -2, "error")
    } else {
        L.push("unrecognized value type (\(axValue))")
    }
}

/// Pushes a simple (non-container, non-AXValue) CFType onto the Lua stack.
private func pushSimpleCFType(_ L: UnsafeMutablePointer<lua_State>!, _ theItem: CFTypeRef, _ theType: CFTypeID) {
    if theType == CGColor.typeID {
        lua_pushany(L, NSColor(cgColor: theItem as! CGColor))
    } else if theType == CGImage.typeID {
        let cgImage = theItem as! CGImage
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        lua_pushany(L, NSImage(cgImage: cgImage, size: imageSize))
    } else if theType == CFAttributedStringGetTypeID() {
        lua_pushany(L, theItem as! NSAttributedString)
    } else if theType == CFNullGetTypeID() {
        lua_pushany(L, NSNull())
    } else if theType == CFBooleanGetTypeID() || theType == CFNumberGetTypeID() {
        lua_pushany(L, theItem as! NSNumber)
    } else if theType == CFDataGetTypeID() {
        lua_pushany(L, theItem as! NSData)
    } else if theType == CFDateGetTypeID() {
        lua_pushany(L, theItem as! NSDate)
    } else if theType == CFStringGetTypeID() {
        lua_pushany(L, theItem as! NSString)
    } else if theType == CFURLGetTypeID() {
        lua_pushany(L, theItem as! NSURL)
    } else if theType == AXUIElementGetTypeID() {
        pushAXUIElement(L, theItem as! AXUIElement)
    } else if theType == AXObserverGetTypeID() {
        pushAXObserver(L, theItem as! AXObserver)
    } else if theType == AXTextMarkerGetTypeID() {
        pushAXTextMarker(L, theItem)
    } else if theType == AXTextMarkerRangeGetTypeID() {
        pushAXTextMarkerRange(L, theItem)
    } else {
        let typeLabel = "unrecognized type: \(theType)"
        os_log(.debug, "%{public}s", "\(String(cString: USERDATA_TAG)):\(typeLabel)")
        L.push(typeLabel)
    }
}

private func lua_toCFTypeHamster(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ seen: NSMutableDictionary) -> CFTypeRef {
    let index = lua_absindex(L, idx)

    let seenKey = NSValue(pointer: lua_topointer(L, index))
    if seen[seenKey] != nil {
        os_log(.info, "%{public}s", "\(String(cString: USERDATA_TAG)):multiple references to same table not currently supported for conversion")
        return kCFNull
    }

    guard lua_absindex(L, lua_gettop(L)) >= index else {
        return kCFNull
    }

    let luaType = lua_type(L, index)

    if luaType == LUA_TSTRING {
        return luaStringToCFType(L, index)
    } else if luaType == LUA_TBOOLEAN {
        return lua_toboolean(L, index) != 0 ? kCFBooleanTrue : kCFBooleanFalse
    } else if luaType == LUA_TNUMBER {
        return luaNumberToCFType(L, index)
    } else if luaType == LUA_TTABLE {
        return luaTableToCFType(L, index, seenKey, seen)
    } else if luaType == LUA_TUSERDATA {
        return luaUserdataToCFType(L, index)
    } else if luaType != LUA_TNIL {
        let typeName = String(cString: lua_typename(L, luaType))
        os_log(.error, "%{public}s", "\(String(cString: USERDATA_TAG)):type \(typeName) not supported for conversion")
        return kCFNull
    }

    return kCFNull
}

/// Converts a Lua string at `index` to a CFString or CFData.
private func luaStringToCFType(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    let holder: Any? = lua_tovalue(L, at: index)
    if let str = holder as? NSString { return str as CFString }
    if let data = holder as? NSData  { return data as CFData }
    return kCFNull
}

/// Converts a Lua number at `index` to a CFNumber (integer or double).
private func luaNumberToCFType(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    if lua_isinteger(L, index) != 0 {
        var holder = lua_tointeger(L, index)
        return CFNumberCreate(kCFAllocatorDefault, .longLongType, &holder)
    } else {
        var holder = lua_tonumber(L, index)
        return CFNumberCreate(kCFAllocatorDefault, .doubleType, &holder)
    }
}

/// Probes a Lua table for well-known keys and returns a struct of booleans.
private struct TableFieldProbe {
    let hasX, hasY, hasH, hasW: Bool
    let hasLoc, hasLen, hasStarts, hasEnds: Bool
    let hasError, hasDate, hasLuaSkinType: Bool
}

private func probeTableFields(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> TableFieldProbe {
    func hasField(_ name: String) -> Bool {
        let present = lua_getfield(L, index, name) != LUA_TNIL; lua_pop(L, 1)
        return present
    }
    return TableFieldProbe(
        hasX: hasField("x"), hasY: hasField("y"), hasH: hasField("h"), hasW: hasField("w"),
        hasLoc: hasField("location"), hasLen: hasField("length"),
        hasStarts: hasField("starts"), hasEnds: hasField("ends"),
        hasError: hasField("_code"), hasDate: hasField("_date"),
        hasLuaSkinType: hasField("__luaSkinType")
    )
}

/// Converts a Lua table to the appropriate CFType based on its fields.
private func luaTableToCFType(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32,
                              _ seenKey: NSValue, _ seen: NSMutableDictionary) -> CFTypeRef {
    let f = probeTableFields(L, index)

    if f.hasX && f.hasY && f.hasH && f.hasW {
        return luaTableToCGRect(L, index)
    } else if f.hasX && f.hasY {
        return luaTableToCGPoint(L, index)
    } else if f.hasH && f.hasW {
        return luaTableToCGSize(L, index)
    } else if f.hasLoc && f.hasLen {
        return luaTableToCFRangeObjC(L, index)
    } else if f.hasStarts && f.hasEnds {
        return luaTableToCFRangeLua(L, index)
    } else if f.hasError {
        return luaTableToAXError(L, index)
    } else if f.hasDate {
        return luaTableToCFDate(L, index)
    } else if f.hasLuaSkinType {
        return luaTableFromLuaSkinType(L, index)
    } else {
        return luaTableToArrayOrDict(L, index, seenKey, seen)
    }
}

private func luaTableToCGRect(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    lua_getfield(L, index, "x"); lua_getfield(L, index, "y")
    lua_getfield(L, index, "w"); lua_getfield(L, index, "h")
    var holder = CGRect(x: CGFloat(luaL_checknumber(L, -4)),
                        y: CGFloat(luaL_checknumber(L, -3)),
                        width: CGFloat(luaL_checknumber(L, -2)),
                        height: CGFloat(luaL_checknumber(L, -1)))
    lua_pop(L, 4)
    return AXValueCreate(.cgRect, &holder)!
}

private func luaTableToCGPoint(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    lua_getfield(L, index, "x"); lua_getfield(L, index, "y")
    var holder = CGPoint(x: CGFloat(luaL_checknumber(L, -2)),
                         y: CGFloat(luaL_checknumber(L, -1)))
    lua_pop(L, 2)
    return AXValueCreate(.cgPoint, &holder)!
}

private func luaTableToCGSize(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    lua_getfield(L, index, "w"); lua_getfield(L, index, "h")
    var holder = CGSize(width: CGFloat(luaL_checknumber(L, -2)),
                        height: CGFloat(luaL_checknumber(L, -1)))
    lua_pop(L, 2)
    return AXValueCreate(.cgSize, &holder)!
}

private func luaTableToCFRangeObjC(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    lua_getfield(L, index, "location"); lua_getfield(L, index, "length")
    var holder = CFRange(location: CFIndex(luaL_checkinteger(L, -2)),
                         length: CFIndex(luaL_checkinteger(L, -1)))
    lua_pop(L, 2)
    return AXValueCreate(.cfRange, &holder)!
}

private func luaTableToCFRangeLua(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    lua_getfield(L, index, "starts"); lua_getfield(L, index, "ends")
    let starts = luaL_checkinteger(L, -2)
    let ends   = luaL_checkinteger(L, -1)
    var holder = CFRange(location: CFIndex(starts - 1), length: CFIndex(ends + 1 - starts))
    lua_pop(L, 2)
    return AXValueCreate(.cfRange, &holder)!
}

private func luaTableToAXError(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    lua_getfield(L, index, "_code")
    var holder = AXError(rawValue: Int32(luaL_checkinteger(L, -1)))!
    lua_pop(L, 1)
    return AXValueCreate(.axError, &holder)!
}

private func luaTableToCFDate(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    let dateType = lua_getfield(L, index, "_date")
    if dateType == LUA_TNUMBER {
        let date = NSDate(timeIntervalSince1970: lua_tonumber(L, -1))
        lua_pop(L, 1)
        return CFDateCreate(kCFAllocatorDefault, date.timeIntervalSinceReferenceDate)
    } else if dateType == LUA_TSTRING {
        let rfc3339 = DateFormatter()
        rfc3339.locale = Locale(identifier: "en_US_POSIX")
        rfc3339.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
        rfc3339.timeZone = TimeZone(secondsFromGMT: 0)
        let str = lua_tovalue(L, at: -1) as? String
        lua_pop(L, 1)
        if let str = str, let date = rfc3339.date(from: str) {
            return CFDateCreate(kCFAllocatorDefault, (date as NSDate).timeIntervalSinceReferenceDate)
        }
        os_log(.error, "%{public}s", "\(String(cString: USERDATA_TAG)):invalid date format specified for conversion")
        return kCFNull
    } else {
        lua_pop(L, 1)
        os_log(.error, "%{public}s", "\(String(cString: USERDATA_TAG)):invalid date format specified for conversion")
        return kCFNull
    }
}

private func luaTableFromLuaSkinType(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    let object = lua_tovalue(L, at: index)
    if let color = object as? NSColor        { return color.cgColor }
    if let url = object as? NSURL            { return url as CFURL }
    if let img = object as? NSImage          {
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    if let attrStr = object as? NSAttributedString { return attrStr as CFAttributedString }
    lua_getfield(L, index, "__luaSkinType")
    let typeName = String(cString: lua_tostring(L, -1)!)
    os_log(.error, "%{public}s", "\(String(cString: USERDATA_TAG)):__luaSkinType table \(typeName) not supported for conversion")
    lua_pop(L, 1)
    return kCFNull
}

/// Converts a plain Lua table (no recognized geometry/date keys) to a CFArray or CFDictionary.
private func luaTableToArrayOrDict(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32,
                                   _ seenKey: NSValue, _ seen: NSMutableDictionary) -> CFTypeRef {
    seen[seenKey] = NSNumber(value: true)
    let len = luaL_len(L, index)
    if len == luaL_len(L, index) { // CFArray
        let holder = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks_)!
        for i in 0..<len {
            lua_geti(L, index, lua_Integer(i + 1))
            let val = lua_toCFTypeHamster(L, -1, seen)
            CFArrayAppendValue(holder, Unmanaged.passUnretained(val).toOpaque())
            lua_pop(L, 1)
        }
        return holder
    } else { // CFDictionary
        let holder = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks_, &kCFTypeDictionaryValueCallBacks_)!
        lua_pushnil(L)
        while lua_next(L, index) != 0 {
            let key = lua_toCFTypeHamster(L, -2, seen)
            let val = lua_toCFTypeHamster(L, -1, seen)
            CFDictionarySetValue(holder,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(val).toOpaque())
            lua_pop(L, 1)
        }
        return holder
    }
}

/// Converts Lua userdata at `index` to the corresponding CFType.
private func luaUserdataToCFType(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> CFTypeRef {
    if luaL_testudata(L, index, "hs.styledtext") != nil {
        return lua_tovalue(L, at: index) as! CFAttributedString
    } else if luaL_testudata(L, index, USERDATA_TAG) != nil {
        return get_axuielementref(L, index, USERDATA_TAG)
    } else if luaL_testudata(L, index, OBSERVER_TAG) != nil {
        return get_axobserverref(L, index, OBSERVER_TAG)
    } else if luaL_testudata(L, index, AXTEXTMARKER_TAG) != nil {
        return get_axtextmarkerref(L, index, AXTEXTMARKER_TAG)
    } else if luaL_testudata(L, index, AXTEXTMRKRNG_TAG) != nil {
        return get_axtextmarkerrangeref(L, index, AXTEXTMRKRNG_TAG)
    } else {
        os_log(.error, "%{public}s", "\(String(cString: USERDATA_TAG)):unrecognized userdata is not supported for conversion")
        return kCFNull
    }
}

// CF callback structs are not directly available in Swift as var references,
// so we store local copies for use with CFArrayCreateMutable/CFDictionaryCreateMutable.
private var kCFTypeArrayCallBacks_ = kCFTypeArrayCallBacks
private var kCFTypeDictionaryKeyCallBacks_ = kCFTypeDictionaryKeyCallBacks
private var kCFTypeDictionaryValueCallBacks_ = kCFTypeDictionaryValueCallBacks

@_cdecl("pushCFTypeToLua")
@discardableResult
public func pushCFTypeToLua(_ L: UnsafeMutablePointer<lua_State>!, _ theItem: CFTypeRef?, _ refTable: Int32) -> Int32 {
    let alreadySeen = NSMutableDictionary()
    _ = pushCFTypeHamster(L, theItem, alreadySeen, refTable)
    for entry in alreadySeen {
        if let seenRef = entry.value as? NSNumber {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, seenRef.int32Value)
        }
    }
    return 1
}

@_cdecl("lua_toCFType")
public func lua_toCFType(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> CFTypeRef {
    let seen = NSMutableDictionary()
    return lua_toCFTypeHamster(L, idx, seen)
}

// MARK: ============================================================
