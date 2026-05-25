// libaxuielement_new.swift
//
// Swift port of common.m, observer.m, and axtextmarker.m for hs.axuielement.
// These were originally four ObjC files; this single Swift file consolidates
// the shared helpers (common), the AXObserver wrapper (observer), and the
// AXTextMarker/AXTextMarkerRange wrappers (axtextmarker).

import Cocoa
import LuaSkin

// MARK: - Tag Constants

// These were #define in common.h.  They must be visible to libaxuielement.swift
// (same SPM target), so they are internal (not private).
// Use specific prefix to avoid colliding with other files' private USERDATA_TAG.
// libaxuielement.swift references these by their prefixed names.
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

// pushAXUIElement and AXErrorAsString are defined in libaxuielement.swift
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
    let skin = LuaSkin.skin(with: L)
    let obj = HSapplication(pid: pid, withState: L)

    if let obj = obj {
        skin.pushNSObject(obj)
        return true
    } else {
        lua_pushnil(L)
        return false
    }
}

@_cdecl("new_window")
@discardableResult
public func new_window(_ L: UnsafeMutablePointer<lua_State>!, _ win: AXUIElement) -> Bool {
    let skin = LuaSkin.skin(with: L)
    guard let hswClass: AnyClass = NSClassFromString("HSwindow") else {
        skin.logError("\(String(cString: USERDATA_TAG)):new_window - HSwindow class not present; may require Cosmic Hammer upgrade")
        lua_pushnil(L)
        return false
    }
    let obj = (hswClass as! NSObject.Type).init().perform(
        NSSelectorFromString("initWithAXUIElementRef:"),
        with: win
    )?.takeUnretainedValue() as? NSObject

    if let obj = obj {
        // the HSapplication initializer retains its elementRef; the HSwindow one doesn't
        // ARC manages CF object lifetimes in Swift — no manual retain needed
        skin.pushNSObject(obj)
        return true
    } else {
        lua_pushnil(L)
        return false
    }
}

// MARK: - pushCFTypeToLua / lua_toCFType

private func pushCFTypeHamster(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ theItem: CFTypeRef?,
    _ alreadySeen: NSMutableDictionary,
    _ refTable: LSRefTable
) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    guard let theItem = theItem else {
        lua_pushnil(L)
        return 1
    }

    let theType = CFGetTypeID(theItem)

    if theType == CFArrayGetTypeID() {
        let seenKey = theItem as AnyObject
        if let seenRef = alreadySeen[seenKey] as? NSNumber {
            skin.pushLuaRef(refTable, ref: seenRef.int32Value)
            return 1
        }
        lua_newtable(L)
        let ref = skin.luaRef(refTable)
        let seenRef = NSNumber(value: ref)
        alreadySeen[seenKey] = seenRef
        skin.pushLuaRef(refTable, ref: seenRef.int32Value)
        for thing in (theItem as! NSArray) {
            _ = pushCFTypeHamster(L, thing as CFTypeRef, alreadySeen, refTable)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else if theType == CFDictionaryGetTypeID() {
        let seenKey = theItem as AnyObject
        if let seenRef = alreadySeen[seenKey] as? NSNumber {
            skin.pushLuaRef(refTable, ref: seenRef.int32Value)
            return 1
        }
        lua_newtable(L)
        let ref = skin.luaRef(refTable)
        let seenRef = NSNumber(value: ref)
        alreadySeen[seenKey] = seenRef
        skin.pushLuaRef(refTable, ref: seenRef.int32Value)
        let dict = theItem as! NSDictionary
        let keys = dict.allKeys
        let values = dict.allValues
        for i in 0..<keys.count {
            _ = pushCFTypeHamster(L, keys[i] as CFTypeRef, alreadySeen, refTable)
            _ = pushCFTypeHamster(L, values[i] as CFTypeRef, alreadySeen, refTable)
            lua_settable(L, -3)
        }
    } else if theType == AXValueGetTypeID() {
        let axValue = theItem as! AXValue
        let valueType = AXValueGetType(axValue)
        if valueType == .cgPoint {
            var pt = CGPoint.zero
            AXValueGetValue(axValue, .cgPoint, &pt)
            lua_newtable(L)
            lua_pushnumber(L, lua_Number(pt.x)); lua_setfield(L, -2, "x")
            lua_pushnumber(L, lua_Number(pt.y)); lua_setfield(L, -2, "y")
        } else if valueType == .cgSize {
            var sz = CGSize.zero
            AXValueGetValue(axValue, .cgSize, &sz)
            lua_newtable(L)
            lua_pushnumber(L, lua_Number(sz.height)); lua_setfield(L, -2, "h")
            lua_pushnumber(L, lua_Number(sz.width));  lua_setfield(L, -2, "w")
        } else if valueType == .cgRect {
            var rect = CGRect.zero
            AXValueGetValue(axValue, .cgRect, &rect)
            lua_newtable(L)
            lua_pushnumber(L, lua_Number(rect.origin.x));    lua_setfield(L, -2, "x")
            lua_pushnumber(L, lua_Number(rect.origin.y));    lua_setfield(L, -2, "y")
            lua_pushnumber(L, lua_Number(rect.size.height)); lua_setfield(L, -2, "h")
            lua_pushnumber(L, lua_Number(rect.size.width));  lua_setfield(L, -2, "w")
        } else if valueType == .cfRange {
            var range = CFRange(location: 0, length: 0)
            AXValueGetValue(axValue, .cfRange, &range)
            lua_newtable(L)
            lua_pushinteger(L, lua_Integer(range.location)); lua_setfield(L, -2, "location")
            lua_pushinteger(L, lua_Integer(range.length));   lua_setfield(L, -2, "length")
        } else if valueType == .axError {
            var err: AXError = .success
            AXValueGetValue(axValue, .axError, &err)
            lua_newtable(L)
            lua_pushinteger(L, lua_Integer(err.rawValue));           lua_setfield(L, -2, "_code")
            lua_pushstring(L, AXErrorAsString(err)); lua_setfield(L, -2, "error")
        } else {
            lua_pushstring(L, "unrecognized value type (\(theItem))")
        }
    } else if theType == CGColor.typeID {
        skin.pushNSObject(NSColor(cgColor: theItem as! CGColor))
    } else if theType == CGImage.typeID {
        let cgImage = theItem as! CGImage
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        skin.pushNSObject(NSImage(cgImage: cgImage, size: imageSize))
    } else if theType == CFAttributedStringGetTypeID() {
        skin.pushNSObject(theItem as! NSAttributedString)
    } else if theType == CFNullGetTypeID() {
        skin.pushNSObject(NSNull())
    } else if theType == CFBooleanGetTypeID() || theType == CFNumberGetTypeID() {
        skin.pushNSObject(theItem as! NSNumber)
    } else if theType == CFDataGetTypeID() {
        skin.pushNSObject(theItem as! NSData)
    } else if theType == CFDateGetTypeID() {
        skin.pushNSObject(theItem as! NSDate)
    } else if theType == CFStringGetTypeID() {
        skin.pushNSObject(theItem as! NSString)
    } else if theType == CFURLGetTypeID() {
        skin.pushNSObject(theItem as! NSURL)
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
        skin.logDebug("\(String(cString: USERDATA_TAG)):\(typeLabel)")
        lua_pushstring(L, typeLabel)
    }
    return 1
}

private func lua_toCFTypeHamster(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ seen: NSMutableDictionary) -> CFTypeRef {
    let skin = LuaSkin.skin(with: L)
    let index = lua_absindex(L, idx)

    let seenKey = NSValue(pointer: lua_topointer(L, index))
    if seen[seenKey] != nil {
        skin.logWarn("\(String(cString: USERDATA_TAG)):multiple references to same table not currently supported for conversion")
        return kCFNull
    }

    guard lua_absindex(L, lua_gettop(L)) >= index else {
        return kCFNull
    }

    let luaType = lua_type(L, index)

    if luaType == LUA_TSTRING {
        let holder: Any? = skin.toNSObject(atIndex: index)
        if let str = holder as? NSString {
            return str as CFString
        } else if let data = holder as? NSData {
            return data as CFData
        }
        return kCFNull
    } else if luaType == LUA_TBOOLEAN {
        return lua_toboolean(L, index) != 0 ? kCFBooleanTrue : kCFBooleanFalse
    } else if luaType == LUA_TNUMBER {
        if lua_isinteger(L, index) != 0 {
            var holder = lua_tointeger(L, index)
            return CFNumberCreate(kCFAllocatorDefault, .longLongType, &holder)
        } else {
            var holder = lua_tonumber(L, index)
            return CFNumberCreate(kCFAllocatorDefault, .doubleType, &holder)
        }
    } else if luaType == LUA_TTABLE {
        // Check for __luaSkinType
        let has__luaSkinType = lua_getfield(L, index, "__luaSkinType") != LUA_TNIL; lua_pop(L, 1)

        // rect, point, size keys
        let hasX      = lua_getfield(L, index, "x")        != LUA_TNIL; lua_pop(L, 1)
        let hasY      = lua_getfield(L, index, "y")        != LUA_TNIL; lua_pop(L, 1)
        let hasH      = lua_getfield(L, index, "h")        != LUA_TNIL; lua_pop(L, 1)
        let hasW      = lua_getfield(L, index, "w")        != LUA_TNIL; lua_pop(L, 1)
        // range (objc style)
        let hasLoc    = lua_getfield(L, index, "location")  != LUA_TNIL; lua_pop(L, 1)
        let hasLen    = lua_getfield(L, index, "length")    != LUA_TNIL; lua_pop(L, 1)
        // range (lua style)
        let hasStarts = lua_getfield(L, index, "starts")    != LUA_TNIL; lua_pop(L, 1)
        let hasEnds   = lua_getfield(L, index, "ends")      != LUA_TNIL; lua_pop(L, 1)
        // AXError type
        let hasError  = lua_getfield(L, index, "_code")     != LUA_TNIL; lua_pop(L, 1)
        // date pseudo-table
        let hasDate   = lua_getfield(L, index, "_date")     != LUA_TNIL; lua_pop(L, 1)

        if hasX && hasY && hasH && hasW { // CGRect
            lua_getfield(L, index, "x")
            lua_getfield(L, index, "y")
            lua_getfield(L, index, "w")
            lua_getfield(L, index, "h")
            var holder = CGRect(x: CGFloat(luaL_checknumber(L, -4)),
                                y: CGFloat(luaL_checknumber(L, -3)),
                                width: CGFloat(luaL_checknumber(L, -2)),
                                height: CGFloat(luaL_checknumber(L, -1)))
            lua_pop(L, 4)
            return AXValueCreate(.cgRect, &holder)!
        } else if hasX && hasY { // CGPoint
            lua_getfield(L, index, "x")
            lua_getfield(L, index, "y")
            var holder = CGPoint(x: CGFloat(luaL_checknumber(L, -2)),
                                 y: CGFloat(luaL_checknumber(L, -1)))
            lua_pop(L, 2)
            return AXValueCreate(.cgPoint, &holder)!
        } else if hasH && hasW { // CGSize
            lua_getfield(L, index, "w")
            lua_getfield(L, index, "h")
            var holder = CGSize(width: CGFloat(luaL_checknumber(L, -2)),
                                height: CGFloat(luaL_checknumber(L, -1)))
            lua_pop(L, 2)
            return AXValueCreate(.cgSize, &holder)!
        } else if hasLoc && hasLen { // CFRange objc style
            lua_getfield(L, index, "location")
            lua_getfield(L, index, "length")
            var holder = CFRange(location: CFIndex(luaL_checkinteger(L, -2)),
                                 length: CFIndex(luaL_checkinteger(L, -1)))
            lua_pop(L, 2)
            return AXValueCreate(.cfRange, &holder)!
        } else if hasStarts && hasEnds { // CFRange lua style
            lua_getfield(L, index, "starts")
            lua_getfield(L, index, "ends")
            let starts = luaL_checkinteger(L, -2)
            let ends   = luaL_checkinteger(L, -1)
            var holder = CFRange(location: CFIndex(starts - 1), length: CFIndex(ends + 1 - starts))
            lua_pop(L, 2)
            return AXValueCreate(.cfRange, &holder)!
        } else if hasError { // AXError
            lua_getfield(L, index, "_code")
            var holder = AXError(rawValue: Int32(luaL_checkinteger(L, -1)))!
            lua_pop(L, 1)
            return AXValueCreate(.axError, &holder)!
        } else if hasDate { // CFDate
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
                let str = skin.toNSObject(atIndex: -1) as? String
                lua_pop(L, 1)
                if let str = str, let date = rfc3339.date(from: str) {
                    return CFDateCreate(kCFAllocatorDefault, (date as NSDate).timeIntervalSinceReferenceDate)
                }
                skin.logError("\(String(cString: USERDATA_TAG)):invalid date format specified for conversion")
                return kCFNull
            } else {
                lua_pop(L, 1)
                skin.logError("\(String(cString: USERDATA_TAG)):invalid date format specified for conversion")
                return kCFNull
            }
        } else if has__luaSkinType {
            let object = skin.toNSObject(atIndex: index)
            if let color = object as? NSColor        { return color.cgColor }
            else if let url = object as? NSURL       { return url as CFURL }
            else if let img = object as? NSImage      {
                return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            }
            else if let attrStr = object as? NSAttributedString { return attrStr as CFAttributedString }
            else {
                lua_getfield(L, index, "__luaSkinType")
                let typeName = String(cString: lua_tostring(L, -1)!)
                skin.logError("\(String(cString: USERDATA_TAG)):__luaSkinType table \(typeName) not supported for conversion")
                lua_pop(L, 1)
                return kCFNull
            }
        } else {
            // real CFDictionary or CFArray
            seen[seenKey] = NSNumber(value: true)
            let len = luaL_len(L, index)
            if len == skin.countNatIndex(index) { // CFArray
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
    } else if luaType == LUA_TUSERDATA {
        if luaL_testudata(L, index, "hs.styledtext") != nil {
            return skin.toNSObject(atIndex: index) as! CFAttributedString
        } else if luaL_testudata(L, index, USERDATA_TAG) != nil {
            let ref = get_axuielementref(L, index, USERDATA_TAG)
            return ref
        } else if luaL_testudata(L, index, OBSERVER_TAG) != nil {
            let ref = get_axobserverref(L, index, OBSERVER_TAG)
            return ref
        } else if luaL_testudata(L, index, AXTEXTMARKER_TAG) != nil {
            let ref = get_axtextmarkerref(L, index, AXTEXTMARKER_TAG)
            return ref
        } else if luaL_testudata(L, index, AXTEXTMRKRNG_TAG) != nil {
            let ref = get_axtextmarkerrangeref(L, index, AXTEXTMRKRNG_TAG)
            return ref
        } else {
            skin.logError("\(String(cString: USERDATA_TAG)):unrecognized userdata is not supported for conversion")
            return kCFNull
        }
    } else if luaType != LUA_TNIL {
        let typeName = String(cString: lua_typename(L, luaType))
        skin.logError("\(String(cString: USERDATA_TAG)):type \(typeName) not supported for conversion")
        return kCFNull
    }

    return kCFNull
}

// CF callback structs are not directly available in Swift as var references,
// so we store local copies for use with CFArrayCreateMutable/CFDictionaryCreateMutable.
private var kCFTypeArrayCallBacks_ = kCFTypeArrayCallBacks
private var kCFTypeDictionaryKeyCallBacks_ = kCFTypeDictionaryKeyCallBacks
private var kCFTypeDictionaryValueCallBacks_ = kCFTypeDictionaryValueCallBacks

@_cdecl("pushCFTypeToLua")
@discardableResult
public func pushCFTypeToLua(_ L: UnsafeMutablePointer<lua_State>!, _ theItem: CFTypeRef?, _ refTable: LSRefTable) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let alreadySeen = NSMutableDictionary()
    _ = pushCFTypeHamster(L, theItem, alreadySeen, refTable)
    for entry in alreadySeen {
        if let seenRef = entry.value as? NSNumber {
            skin.luaUnref(refTable, ref: seenRef.int32Value)
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
// MARK: axtextmarker.m — AXTextMarker / AXTextMarkerRange
// MARK: ============================================================

private var textmarkerRefTable: LSRefTable = LUA_NOREF

// MARK: - Push Helpers

@_cdecl("pushAXTextMarker")
@discardableResult
public func pushAXTextMarker(_ L: UnsafeMutablePointer<lua_State>!, _ theElement: CFTypeRef) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<Unmanaged<CFTypeRef>>.size)!
        .assumingMemoryBound(to: Unmanaged<CFTypeRef>.self)
    thePtr.pointee = Unmanaged.passRetained(theElement as CFTypeRef)
    luaL_getmetatable(L, AXTEXTMARKER_TAG)
    lua_setmetatable(L, -2)
    return 1
}

@_cdecl("pushAXTextMarkerRange")
@discardableResult
public func pushAXTextMarkerRange(_ L: UnsafeMutablePointer<lua_State>!, _ theElement: CFTypeRef) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<Unmanaged<CFTypeRef>>.size)!
        .assumingMemoryBound(to: Unmanaged<CFTypeRef>.self)
    thePtr.pointee = Unmanaged.passRetained(theElement as CFTypeRef)
    luaL_getmetatable(L, AXTEXTMRKRNG_TAG)
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
    skin.checkArgs(LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TBREAK)
    let startMarker = get_axtextmarkerref(L, 1, AXTEXTMARKER_TAG)
    let endMarker   = get_axtextmarkerref(L, 2, AXTEXTMARKER_TAG)

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
    skin.checkArgs(LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TBREAK)
    let marker = get_axtextmarkerref(L, 1, AXTEXTMARKER_TAG)

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
    skin.checkArgs(LS_TUSERDATA, AXTEXTMARKER_TAG, LS_TBREAK)
    let marker = get_axtextmarkerref(L, 1, AXTEXTMARKER_TAG)

    lua_pushinteger(L, lua_Integer(AXTextMarkerGetLength(marker)))
    return 1
}

/// hs.axuielement.axtextmarker:startMarker() -> axTextMarkerObject | nil, errorString
private func axtextmarker_rangeStartMarker(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, AXTEXTMRKRNG_TAG, LS_TBREAK)
    let range = get_axtextmarkerrangeref(L, 1, AXTEXTMRKRNG_TAG)

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
    skin.checkArgs(LS_TUSERDATA, AXTEXTMRKRNG_TAG, LS_TBREAK)
    let range = get_axtextmarkerrangeref(L, 1, AXTEXTMRKRNG_TAG)

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
    let tag = luaL_testudata(L, 1, AXTEXTMARKER_TAG) != nil ? AXTEXTMARKER_TAG : AXTEXTMRKRNG_TAG
    let tagStr = String(cString: tag)
    let ptr = Int(bitPattern: lua_topointer(L, 1))
    skin.pushNSObject(NSString(format: "%@: (0x%lx)", tagStr as NSString, ptr))
    return 1
}

private func textmarker_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if (luaL_testudata(L, 1, AXTEXTMARKER_TAG) != nil && luaL_testudata(L, 2, AXTEXTMARKER_TAG) != nil) ||
       (luaL_testudata(L, 1, AXTEXTMRKRNG_TAG) != nil && luaL_testudata(L, 2, AXTEXTMRKRNG_TAG) != nil) {
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
    textmarkerRefTable = skin.registerLibrary(withObject: AXTEXTMARKER_TAG,
                                              functions: &textmarker_moduleLib,
                                              metaFunctions: nil,
                                              objectFunctions: &marker_userdata_metaLib)
    skin.registerObject(AXTEXTMRKRNG_TAG, objectFunctions: &range_userdata_metaLib)
    return 1
}

// MARK: ============================================================
// MARK: observer.m — AXObserver Wrapper
// MARK: ============================================================

private var observerRefTable: LSRefTable = LUA_NOREF

private var observerDetails: NSMutableDictionary? = nil

private let keySelfRefCount = "selfRefCount" as CFString
private let keyCallbackRef  = "callbackRef" as CFString
private let keyIsRunning    = "isRunning" as CFString
private let keyWatching     = "watching" as CFString

// MARK: - Support Functions (observer)

@_cdecl("pushAXObserver")
@discardableResult
public func pushAXObserver(_ L: UnsafeMutablePointer<lua_State>!, _ observer: AXObserver) -> Int32 {
    if observerDetails == nil {
        observerDetails = NSMutableDictionary()
    }

    let observerKey = observer as AnyObject
    var details = observerDetails![observerKey] as? NSMutableDictionary
    if details == nil {
        details = NSMutableDictionary()
        details![keySelfRefCount as String] = NSNumber(value: 0 as Int32)
        details![keyCallbackRef as String]  = NSNumber(value: LUA_NOREF)
        details![keyIsRunning as String]    = NSNumber(value: false)
        details![keyWatching as String]     = NSMutableDictionary()
        observerDetails![observerKey] = details
    }

    var selfRefCount = (details![keySelfRefCount as String] as! NSNumber).int32Value
    selfRefCount += 1
    details![keySelfRefCount as String] = NSNumber(value: selfRefCount)

    let thePtr = lua_newuserdata(L, MemoryLayout<Unmanaged<AXObserver>>.size)!
        .assumingMemoryBound(to: Unmanaged<AXObserver>.self)
    thePtr.pointee = Unmanaged.passRetained(observer)
    luaL_getmetatable(L, OBSERVER_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func purgeWatchers(element: AXUIElement, notifications: NSMutableArray, observer: AXObserver) {
    for notification in notifications {
        guard let what = notification as? String else { continue }
        AXObserverRemoveNotification(observer, element, what as CFString)
    }
    notifications.removeAllObjects()
}

private func cleanupAXObserver(_ observer: AXObserver, _ details: NSMutableDictionary) {
    let skin = LuaSkin.skin(with: nil)

    var callbackRef = (details[keyCallbackRef as String] as? NSNumber)?.int32Value ?? LUA_NOREF
    callbackRef = skin.luaUnref(observerRefTable, ref: callbackRef)
    details[keyCallbackRef as String] = NSNumber(value: callbackRef)

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    if isRunning {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        details[keyIsRunning as String] = NSNumber(value: false)
    }

    // clean up the `watching` dictionary
    if let watching = details[keyWatching as String] as? NSMutableDictionary {
        for (key, value) in watching {
            let element = unsafeBitCast(key as AnyObject, to: AXUIElement.self)
            if let notifications = value as? NSMutableArray {
                purgeWatchers(element: element, notifications: notifications, observer: observer)
            }
        }
        watching.removeAllObjects()
        details.removeObject(forKey: keyWatching as String)
    }

    details.removeAllObjects()
}

private let observerCallbackPtr: AXObserverCallbackWithInfo = { (observer, element, notification, info, refcon) in
    let skin = LuaSkin.skin(with: nil)
    let L = skin.l!

    let observerKey = observer as AnyObject
    guard let details = observerDetails?[observerKey] as? NSMutableDictionary else {
        skin.logWarn("\(String(cString: OBSERVER_TAG)):callback triggered for unregistered observer")
        return
    }

    let callbackRef = (details[keyCallbackRef as String] as? NSNumber)?.int32Value ?? LUA_NOREF
    if callbackRef != LUA_NOREF {
        skin.pushLuaRef(observerRefTable, ref: callbackRef)
        pushAXObserver(L, observer)
        pushAXUIElement(L, element)
        skin.pushNSObject(notification as String)
        pushCFTypeToLua(L, info, observerRefTable)
        if !skin.protectedCallAndTraceback(4, nresults: 0) {
            skin.logError("\(String(cString: OBSERVER_TAG)):callback error:\(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions (observer)

/// hs.axuielement.observer.new(pid) -> observerObject
private func axobserver_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let appPid = pid_t(lua_tointeger(L, 1))
    var observer: AXObserver?
    let err = AXObserverCreateWithInfoCallback(appPid, observerCallbackPtr, &observer)

    if err != .success { return luaL_error(L, String(cString: AXErrorAsString(err))) }

    pushAXObserver(L, observer!)
    // ARC manages the extra reference from AXObserverCreateWithInfoCallback;
    // pushAXObserver uses Unmanaged.passRetained, so no manual release needed.
    return 1
}

// MARK: - Module Methods (observer)

/// hs.axuielement.observer:start() -> observerObject
private func axobserver_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    if !isRunning {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        details[keyIsRunning as String] = NSNumber(value: true)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:stop() -> observerObject
private func axobserver_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    if isRunning {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        details[keyIsRunning as String] = NSNumber(value: false)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:isRunning() -> boolean
private func axobserver_isRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    lua_pushboolean(L, isRunning ? 1 : 0)
    return 1
}

/// hs.axuielement.observer:callback([fn]) -> observerObject | fn | nil
private func axobserver_callback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    var callbackRef = (details[keyCallbackRef as String] as? NSNumber)?.int32Value ?? LUA_NOREF
    if lua_gettop(L) == 2 {
        callbackRef = skin.luaUnref(observerRefTable, ref: callbackRef)
        details[keyCallbackRef as String] = NSNumber(value: callbackRef)
        if lua_type(L, 2) != LUA_TNIL {
            lua_pushvalue(L, 2)
            callbackRef = skin.luaRef(observerRefTable)
            details[keyCallbackRef as String] = NSNumber(value: callbackRef)
            lua_pushvalue(L, 1)
        }
    } else {
        if callbackRef != LUA_NOREF {
            skin.pushLuaRef(observerRefTable, ref: callbackRef)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.axuielement.observer:addWatcher(element, notification) -> observerObject
private func axobserver_addWatchedElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary
    let element  = get_axuielementref(L, 2, USERDATA_TAG)
    let what     = skin.toNSObject(atIndex: 3) as! String

    let watching = details[keyWatching as String] as! NSMutableDictionary
    let elementKey = element as AnyObject
    var notifications = watching[elementKey] as? NSMutableArray

    var exists = false
    if let notifications = notifications {
        exists = notifications.contains(what)
    } else {
        notifications = NSMutableArray()
        watching[elementKey] = notifications
    }
    if !exists {
        let err = AXObserverAddNotification(observer, element, what as CFString, nil)
        if err != .success { return luaL_error(L, String(cString: AXErrorAsString(err))) }
        notifications!.add(what)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:removeWatcher(element, notification) -> observerObject
private func axobserver_removeWatchedElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary
    let element  = get_axuielementref(L, 2, USERDATA_TAG)
    let what     = skin.toNSObject(atIndex: 3) as! String

    let watching = details[keyWatching as String] as! NSMutableDictionary
    let elementKey = element as AnyObject
    let notifications = watching[elementKey] as? NSMutableArray

    if let notifications = notifications, let idx = notifications.index(of: what) as? Int, idx != NSNotFound {
        let err = AXObserverRemoveNotification(observer, element, what as CFString)
        notifications.removeObject(at: idx)
        if err != .success { return luaL_error(L, String(cString: AXErrorAsString(err))) }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:watching([element]) -> table
private func axobserver_watchedElements(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK | LS_TVARARG)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    var element: AXUIElement? = nil
    if lua_gettop(L) > 1 {
        skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
        element = get_axuielementref(L, 2, USERDATA_TAG)
    }

    let watching = details[keyWatching as String] as! NSMutableDictionary
    if let element = element {
        let elementKey = element as AnyObject
        if let notifications = watching[elementKey] as? NSArray {
            pushCFTypeToLua(L, notifications as CFTypeRef, observerRefTable)
        } else {
            lua_newtable(L)
        }
    } else {
        // Build a table of element -> notifications
        lua_newtable(L)
        for (key, value) in watching {
            let elem = unsafeBitCast(key as AnyObject, to: AXUIElement.self)
            if let notifs = value as? NSArray {
                pushAXUIElement(L, elem)
                pushCFTypeToLua(L, notifs as CFTypeRef, observerRefTable)
                lua_settable(L, -3)
            }
        }
    }
    return 1
}

// MARK: - Module Constants (observer)

private func pushNotificationsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    // Focus notifications
    skin.pushNSObject(kAXMainWindowChangedNotification as String);       lua_setfield(L, -2, "mainWindowChanged")
    skin.pushNSObject(kAXFocusedWindowChangedNotification as String);    lua_setfield(L, -2, "focusedWindowChanged")
    skin.pushNSObject(kAXFocusedUIElementChangedNotification as String); lua_setfield(L, -2, "focusedUIElementChanged")
    // Application notifications
    skin.pushNSObject(kAXApplicationActivatedNotification as String);    lua_setfield(L, -2, "applicationActivated")
    skin.pushNSObject(kAXApplicationDeactivatedNotification as String);  lua_setfield(L, -2, "applicationDeactivated")
    skin.pushNSObject(kAXApplicationHiddenNotification as String);       lua_setfield(L, -2, "applicationHidden")
    skin.pushNSObject(kAXApplicationShownNotification as String);        lua_setfield(L, -2, "applicationShown")
    // Window notifications
    skin.pushNSObject(kAXWindowCreatedNotification as String);           lua_setfield(L, -2, "windowCreated")
    skin.pushNSObject(kAXWindowMovedNotification as String);             lua_setfield(L, -2, "windowMoved")
    skin.pushNSObject(kAXWindowResizedNotification as String);           lua_setfield(L, -2, "windowResized")
    skin.pushNSObject(kAXWindowMiniaturizedNotification as String);      lua_setfield(L, -2, "windowMiniaturized")
    skin.pushNSObject(kAXWindowDeminiaturizedNotification as String);    lua_setfield(L, -2, "windowDeminiaturized")
    // New drawer, sheet, and help tag notifications
    skin.pushNSObject(kAXDrawerCreatedNotification as String);           lua_setfield(L, -2, "drawerCreated")
    skin.pushNSObject(kAXSheetCreatedNotification as String);            lua_setfield(L, -2, "sheetCreated")
    skin.pushNSObject(kAXHelpTagCreatedNotification as String);          lua_setfield(L, -2, "helpTagCreated")
    // Element notifications
    skin.pushNSObject(kAXValueChangedNotification as String);            lua_setfield(L, -2, "valueChanged")
    skin.pushNSObject(kAXUIElementDestroyedNotification as String);      lua_setfield(L, -2, "uIElementDestroyed")
    skin.pushNSObject(kAXElementBusyChangedNotification as String);      lua_setfield(L, -2, "elementBusyChanged")
    // Menu notifications
    skin.pushNSObject(kAXMenuOpenedNotification as String);              lua_setfield(L, -2, "menuOpened")
    skin.pushNSObject(kAXMenuClosedNotification as String);              lua_setfield(L, -2, "menuClosed")
    skin.pushNSObject(kAXMenuItemSelectedNotification as String);        lua_setfield(L, -2, "menuItemSelected")
    // Table and outline view notifications
    skin.pushNSObject(kAXRowCountChangedNotification as String);         lua_setfield(L, -2, "rowCountChanged")
    skin.pushNSObject(kAXRowCollapsedNotification as String);            lua_setfield(L, -2, "rowCollapsed")
    skin.pushNSObject(kAXRowExpandedNotification as String);             lua_setfield(L, -2, "rowExpanded")
    // Miscellaneous notifications
    skin.pushNSObject(kAXSelectedChildrenChangedNotification as String); lua_setfield(L, -2, "selectedChildrenChanged")
    skin.pushNSObject(kAXResizedNotification as String);                 lua_setfield(L, -2, "resized")
    skin.pushNSObject(kAXMovedNotification as String);                   lua_setfield(L, -2, "moved")
    skin.pushNSObject(kAXCreatedNotification as String);                 lua_setfield(L, -2, "created")
    skin.pushNSObject(kAXAnnouncementRequestedNotification as String);   lua_setfield(L, -2, "announcementRequested")
    skin.pushNSObject(kAXLayoutChangedNotification as String);           lua_setfield(L, -2, "layoutChanged")
    skin.pushNSObject(kAXSelectedCellsChangedNotification as String);    lua_setfield(L, -2, "selectedCellsChanged")
    skin.pushNSObject(kAXSelectedChildrenMovedNotification as String);   lua_setfield(L, -2, "selectedChildrenMoved")
    skin.pushNSObject(kAXSelectedColumnsChangedNotification as String);  lua_setfield(L, -2, "selectedColumnsChanged")
    skin.pushNSObject(kAXSelectedRowsChangedNotification as String);     lua_setfield(L, -2, "selectedRowsChanged")
    skin.pushNSObject(kAXSelectedTextChangedNotification as String);     lua_setfield(L, -2, "selectedTextChanged")
    skin.pushNSObject(kAXTitleChangedNotification as String);            lua_setfield(L, -2, "titleChanged")
    skin.pushNSObject(kAXUnitsChangedNotification as String);            lua_setfield(L, -2, "unitsChanged")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure (observer)

private func observer_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let tagStr = String(cString: OBSERVER_TAG)
    let ptr = Int(bitPattern: lua_topointer(L, 1))
    skin.pushNSObject(NSString(format: "%@: (0x%lx)", tagStr as NSString, ptr))
    return 1
}

private func observer_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let observerKey = observer as AnyObject

    guard let details = observerDetails?[observerKey] as? NSMutableDictionary else {
        skin.logWarn("\(String(cString: OBSERVER_TAG)):__gc triggered for unregistered observer")
        lua_pushnil(L)
        lua_setmetatable(L, 1)
        return 0
    }

    var selfRefCount = (details[keySelfRefCount as String] as! NSNumber).int32Value
    selfRefCount -= 1
    details[keySelfRefCount as String] = NSNumber(value: selfRefCount)
    if selfRefCount == 0 {
        cleanupAXObserver(observer, details)
        observerDetails?.removeObject(forKey: observerKey)
    }

    // Release the observer reference that pushAXObserver retained
    let ptr = UnsafeMutableRawPointer(lua_touserdata(L, 1))!.assumingMemoryBound(to: Unmanaged<AXObserver>.self)
    ptr.pointee.release()

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func observer_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let observer1 = get_axobserverref(L, 1, OBSERVER_TAG)
    let observer2 = get_axobserverref(L, 2, OBSERVER_TAG)
    lua_pushboolean(L, CFEqual(observer1, observer2) ? 1 : 0)
    return 1
}

private func observer_meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let od = observerDetails {
        for (key, value) in od {
            let observer = unsafeBitCast(key as AnyObject, to: AXObserver.self)
            if let details = value as? NSMutableDictionary {
                cleanupAXObserver(observer, details)
            }
        }
        od.removeAllObjects()
        observerDetails = nil
    }
    return 0
}

// Metatable for observer userdata
private var observer_userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),         func: axobserver_start),
    luaL_Reg(name: strdup("stop"),          func: axobserver_stop),
    luaL_Reg(name: strdup("isRunning"),     func: axobserver_isRunning),
    luaL_Reg(name: strdup("callback"),      func: axobserver_callback),
    luaL_Reg(name: strdup("addWatcher"),    func: axobserver_addWatchedElement),
    luaL_Reg(name: strdup("removeWatcher"), func: axobserver_removeWatchedElement),
    luaL_Reg(name: strdup("watching"),      func: axobserver_watchedElements),
    luaL_Reg(name: strdup("__tostring"),    func: observer_userdata_tostring),
    luaL_Reg(name: strdup("__eq"),          func: observer_userdata_eq),
    luaL_Reg(name: strdup("__gc"),          func: observer_userdata_gc),
    luaL_Reg(name: nil,                     func: nil),
]

// Module functions
private var observer_moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: axobserver_new),
    luaL_Reg(name: nil,           func: nil),
]

// Module metatable
private var observer_module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: observer_meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

@_cdecl("luaopen_hs_libaxuielementobserver")
@discardableResult
public func luaopen_hs_libaxuielementobserver(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    observerRefTable = skin.registerLibrary(withObject: OBSERVER_TAG,
                                            functions: &observer_moduleLib,
                                            metaFunctions: &observer_module_metaLib,
                                            objectFunctions: &observer_userdata_metaLib)

    if observerDetails == nil {
        observerDetails = NSMutableDictionary()
    }

    pushNotificationsTable(L); lua_setfield(L, -2, "notifications")

    return 1
}
