import Cocoa
import LuaSkin

// keep this current with Hammerspoon's method for creating new hs.application and hs.window objects

@objc protocol PlaceHoldersHSuicoreMethods {
    @objc init(pid: pid_t, withState L: OpaquePointer!)
    @objc init(axuiElementRef winRef: AXUIElement)
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

@_cdecl("getElementRefPropertyFromClassObject")
public func getElementRefPropertyFromClassObject(_ object: NSObject) -> AXUIElement? {
    let selector = NSSelectorFromString("elementRef")

    guard object.responds(to: selector) else { return nil }

    let signature = NSMethodSignature.init(objCTypes: "^{__AXUIElement=}16@0:8")!
    let invocation = NSInvocation(methodSignature: signature)
    invocation.target = object
    invocation.selector = selector
    invocation.invoke()

    var ref: Unmanaged<AXUIElement>?
    invocation.getReturnValue(&ref)

    guard let element = ref?.takeUnretainedValue() else { return nil }
    CFRetain(element)
    return element
}

@_cdecl("new_application")
public func new_application(_ L: OpaquePointer!, _ pid: pid_t) -> ObjCBool {
    let skin = LuaSkin.shared(withState: L)!
    guard let HSA = NSClassFromString("HSapplication") as? NSObject.Type else {
        skin.logError(String(format: "%s:new_application - HSapplication class not present; may require Hammerspoon upgrade", USERDATA_TAG))
        lua_pushnil(L)
        return false
    }

    let sel = NSSelectorFromString("initWithPid:withState:")
    guard let instance = HSA.alloc() as? NSObject,
          instance.responds(to: sel) else {
        lua_pushnil(L)
        return false
    }

    let signature = NSMethodSignature.init(objCTypes: "@@:i^v")!
    let invocation = NSInvocation(methodSignature: signature)
    invocation.target = instance
    invocation.selector = sel
    var pidCopy = pid
    var lCopy = L
    invocation.setArgument(&pidCopy, at: 2)
    invocation.setArgument(&lCopy, at: 3)
    invocation.invoke()

    var result: Unmanaged<AnyObject>?
    invocation.getReturnValue(&result)
    if let obj = result?.takeUnretainedValue() as? NSObject {
        skin.pushNSObject(obj)
        return true
    } else {
        lua_pushnil(L)
        return false
    }
}

@_cdecl("new_window")
public func new_window(_ L: OpaquePointer!, _ win: AXUIElement) -> ObjCBool {
    let skin = LuaSkin.shared(withState: L)!
    guard let HSW = NSClassFromString("HSwindow") as? NSObject.Type else {
        skin.logError(String(format: "%s:new_window - HSapplication class not present; may require Hammerspoon upgrade", USERDATA_TAG))
        lua_pushnil(L)
        return false
    }

    let sel = NSSelectorFromString("initWithAXUIElementRef:")
    guard let instance = HSW.alloc() as? NSObject,
          instance.responds(to: sel) else {
        lua_pushnil(L)
        return false
    }

    let signature = NSMethodSignature.init(objCTypes: "@@:^v")!
    let invocation = NSInvocation(methodSignature: signature)
    invocation.target = instance
    invocation.selector = sel
    var winCopy: CFTypeRef = win
    invocation.setArgument(&winCopy, at: 2)
    invocation.invoke()

    var result: Unmanaged<AnyObject>?
    invocation.getReturnValue(&result)
    if let obj = result?.takeUnretainedValue() as? NSObject {
        // the HSapplication initializer retains its elementRef; the HSwindow one doesn't
        CFRetain(win)
        skin.pushNSObject(obj)
        return true
    } else {
        lua_pushnil(L)
        return false
    }
}

// Not sure if the alreadySeen trick is working here, but it hasn't crashed yet... of course I don't think I've found any loops that don't have a userdata object in-between that drops us back to Lua before deciding whether or not to delve deeper, either, so... should be safe in CFDictionary and CFArray, since they toll-free bridge; don't use for others -- fails for setting with AXUIElementRef as key, at least...

private func pushCFTypeHamster(_ L: OpaquePointer!, _ theItem: CFTypeRef?, _ alreadySeen: NSMutableDictionary, _ refTable: LSRefTable) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!

    guard let theItem = theItem else {
        lua_pushnil(L)
        return 1
    }

    let theType = CFGetTypeID(theItem)

    if theType == CFArrayGetTypeID() {
        if let seenRef = alreadySeen[theItem as AnyObject] as? NSNumber {
            skin.pushLuaRef(refTable, ref: seenRef.int32Value)
            return 1
        }
        lua_newtable(L)
        let seenRef = NSNumber(value: skin.luaRef(refTable))
        alreadySeen[theItem as AnyObject] = seenRef
        skin.pushLuaRef(refTable, ref: seenRef.int32Value) // put it back on the stack
        for thing in (theItem as! NSArray) {
            pushCFTypeHamster(L, thing as CFTypeRef, alreadySeen, refTable)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else if theType == CFDictionaryGetTypeID() {
        if let seenRef = alreadySeen[theItem as AnyObject] as? NSNumber {
            skin.pushLuaRef(refTable, ref: seenRef.int32Value)
            return 1
        }
        lua_newtable(L)
        let seenRef = NSNumber(value: skin.luaRef(refTable))
        alreadySeen[theItem as AnyObject] = seenRef
        skin.pushLuaRef(refTable, ref: seenRef.int32Value) // put it back on the stack
        let dict = theItem as! NSDictionary
        let keys = dict.allKeys
        let values = dict.allValues
        for i in 0..<keys.count {
            pushCFTypeHamster(L, keys[i] as CFTypeRef, alreadySeen, refTable)
            pushCFTypeHamster(L, values[i] as CFTypeRef, alreadySeen, refTable)
            lua_settable(L, -3)
        }
    } else if theType == AXValueGetTypeID() {
        let valueType = AXValueGetType(theItem as! AXValue)
        if valueType == .cgPoint {
            var thePoint = CGPoint.zero
            AXValueGetValue(theItem as! AXValue, .cgPoint, &thePoint)
            lua_newtable(L)
            lua_pushnumber(L, lua_Number(thePoint.x)); lua_setfield(L, -2, "x")
            lua_pushnumber(L, lua_Number(thePoint.y)); lua_setfield(L, -2, "y")
        } else if valueType == .cgSize {
            var theSize = CGSize.zero
            AXValueGetValue(theItem as! AXValue, .cgSize, &theSize)
            lua_newtable(L)
            lua_pushnumber(L, lua_Number(theSize.height)); lua_setfield(L, -2, "h")
            lua_pushnumber(L, lua_Number(theSize.width));  lua_setfield(L, -2, "w")
        } else if valueType == .cgRect {
            var theRect = CGRect.zero
            AXValueGetValue(theItem as! AXValue, .cgRect, &theRect)
            lua_newtable(L)
            lua_pushnumber(L, lua_Number(theRect.origin.x));    lua_setfield(L, -2, "x")
            lua_pushnumber(L, lua_Number(theRect.origin.y));    lua_setfield(L, -2, "y")
            lua_pushnumber(L, lua_Number(theRect.size.height)); lua_setfield(L, -2, "h")
            lua_pushnumber(L, lua_Number(theRect.size.width));  lua_setfield(L, -2, "w")
        } else if valueType == .cfRange {
            var theRange = CFRange(location: 0, length: 0)
            AXValueGetValue(theItem as! AXValue, .cfRange, &theRange)
            lua_newtable(L)
            lua_pushinteger(L, lua_Integer(theRange.location)); lua_setfield(L, -2, "location")
            lua_pushinteger(L, lua_Integer(theRange.length));   lua_setfield(L, -2, "length")
        } else if valueType == .axError {
            var theError: AXError = .success
            AXValueGetValue(theItem as! AXValue, .axError, &theError)
            lua_newtable(L)
            lua_pushinteger(L, lua_Integer(theError.rawValue));           lua_setfield(L, -2, "_code")
            lua_pushstring(L, AXErrorAsString(theError.rawValue)); lua_setfield(L, -2, "error")
        } else {
            lua_pushfstring(L, "unrecognized value type (%p)", theItem as! CVarArg)
        }
    } else if theType == CGColorGetTypeID() {
        skin.pushNSObject(NSColor(cgColor: theItem as! CGColor))
    } else if theType == CGImageGetTypeID() {
        let cgImage = theItem as! CGImage
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        skin.pushNSObject(NSImage(cgImage: cgImage, size: imageSize))
    } else if theType == CFAttributedStringGetTypeID() {
        skin.pushNSObject(theItem as! NSAttributedString)
    } else if theType == CFNullGetTypeID() {
        skin.pushNSObject(theItem as! NSNull)
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
        pushAXTextMarker(L, theItem as! AXTextMarkerRef)
    } else if theType == AXTextMarkerRangeGetTypeID() {
        pushAXTextMarkerRange(L, theItem as! AXTextMarkerRangeRef)
    } else {
        let typeLabel = String(format: "unrecognized type: %lu", theType)
        skin.logDebug(String(format: "%s:%@", USERDATA_TAG, typeLabel))
        lua_pushstring(L, typeLabel)
    }
    return 1
}

private func lua_toCFTypeHamster(_ L: OpaquePointer!, _ idx: Int32, _ seen: NSMutableDictionary) -> CFTypeRef {
    let skin = LuaSkin.shared(withState: L)!
    let index = lua_absindex(L, idx)

    var value: CFTypeRef = kCFNull

    if seen[NSValue(pointer: lua_topointer(L, index))] != nil {
        skin.logWarn(String(format: "%s:multiple references to same table not currently supported for conversion", USERDATA_TAG))
        return kCFNull
    } else if lua_absindex(L, lua_gettop(L)) >= index {
        let theType = lua_type(L, index)
        if theType == LUA_TSTRING {
            let holder: NSObject = skin.toNSObject(atIndex: index) as! NSObject
            if holder is NSString {
                value = holder as CFTypeRef
            } else {
                value = holder as CFTypeRef
            }
        } else if theType == LUA_TBOOLEAN {
            value = lua_toboolean(L, index) != 0 ? kCFBooleanTrue : kCFBooleanFalse
        } else if theType == LUA_TNUMBER {
            if lua_isinteger(L, index) != 0 {
                var holder = lua_tointeger(L, index)
                value = CFNumberCreate(kCFAllocatorDefault, .longLongType, &holder)
            } else {
                var holder = lua_tonumber(L, index)
                value = CFNumberCreate(kCFAllocatorDefault, .doubleType, &holder)
            }
        } else if theType == LUA_TTABLE {
            // for object LuaSkin types
            let has__luaSkinType = lua_getfield(L, index, "__luaSkinType") != LUA_TNIL; lua_pop(L, 1)

            // rect, point, and size are regularly tables in Hammerspoon, differentiated by which of these
            // keys are present.
            let hasX      = lua_getfield(L, index, "x")        != LUA_TNIL; lua_pop(L, 1)
            let hasY      = lua_getfield(L, index, "y")        != LUA_TNIL; lua_pop(L, 1)
            let hasH      = lua_getfield(L, index, "h")        != LUA_TNIL; lua_pop(L, 1)
            let hasW      = lua_getfield(L, index, "w")        != LUA_TNIL; lua_pop(L, 1)
            // objc-style indexing for range
            let hasLoc    = lua_getfield(L, index, "location") != LUA_TNIL; lua_pop(L, 1)
            let hasLen    = lua_getfield(L, index, "length")   != LUA_TNIL; lua_pop(L, 1)
            // lua-style indexing for range
            let hasStarts = lua_getfield(L, index, "starts")   != LUA_TNIL; lua_pop(L, 1)
            let hasEnds   = lua_getfield(L, index, "ends")     != LUA_TNIL; lua_pop(L, 1)
            // AXError type
            let hasError  = lua_getfield(L, index, "_code")    != LUA_TNIL; lua_pop(L, 1)
            // since date is just a number or string, we'll have to make it a "psuedo" table so that it can
            // be uniquely specified on the lua side
            let hasDate   = lua_getfield(L, index, "_date")    != LUA_TNIL; lua_pop(L, 1)

            if hasX && hasY && hasH && hasW { // CGRect
                lua_getfield(L, index, "x")
                lua_getfield(L, index, "y")
                lua_getfield(L, index, "w")
                lua_getfield(L, index, "h")
                var holder = CGRect(x: CGFloat(luaL_checknumber(L, -4)), y: CGFloat(luaL_checknumber(L, -3)),
                                    width: CGFloat(luaL_checknumber(L, -2)), height: CGFloat(luaL_checknumber(L, -1)))
                value = AXValueCreate(.cgRect, &holder)!
                lua_pop(L, 4)
            } else if hasX && hasY { // CGPoint
                lua_getfield(L, index, "x")
                lua_getfield(L, index, "y")
                var holder = CGPoint(x: CGFloat(luaL_checknumber(L, -2)), y: CGFloat(luaL_checknumber(L, -1)))
                value = AXValueCreate(.cgPoint, &holder)!
                lua_pop(L, 2)
            } else if hasH && hasW { // CGSize
                lua_getfield(L, index, "w")
                lua_getfield(L, index, "h")
                var holder = CGSize(width: CGFloat(luaL_checknumber(L, -2)), height: CGFloat(luaL_checknumber(L, -1)))
                value = AXValueCreate(.cgSize, &holder)!
                lua_pop(L, 2)
            } else if hasLoc && hasLen { // CFRange objc style
                lua_getfield(L, index, "location")
                lua_getfield(L, index, "length")
                var holder = CFRange(location: CFIndex(luaL_checkinteger(L, -2)), length: CFIndex(luaL_checkinteger(L, -1)))
                value = AXValueCreate(.cfRange, &holder)!
                lua_pop(L, 2)
            } else if hasStarts && hasEnds { // CFRange lua style
                // NOTE: Negative indexes and UTF8 as bytes can't be handled here without context.
                //       Maybe on lua side in wrapper functions?
                lua_getfield(L, index, "starts")
                lua_getfield(L, index, "ends")
                let starts = luaL_checkinteger(L, -2)
                let ends = luaL_checkinteger(L, -1)
                var holder = CFRange(location: CFIndex(starts - 1), length: CFIndex(ends + 1 - starts))
                value = AXValueCreate(.cfRange, &holder)!
                lua_pop(L, 2)
            } else if hasError { // AXError
                lua_getfield(L, index, "_code")
                var holder = AXError(luaL_checkinteger(L, -1))
                value = AXValueCreate(.axError, &holder)!
                lua_pop(L, 1)
            } else if hasDate { // CFDate
                let dateType = lua_getfield(L, index, "_date")
                if dateType == LUA_TNUMBER {
                    let interval = NSDate(timeIntervalSince1970: lua_tonumber(L, -1)).timeIntervalSinceReferenceDate
                    value = CFDateCreate(kCFAllocatorDefault, interval)
                } else if dateType == LUA_TSTRING {
                    // rfc3339 (Internet Date/Time) formated date.  More or less.
                    let rfc3339DateFormatter = DateFormatter()
                    let enUSPOSIXLocale = Locale(identifier: "en_US_POSIX")
                    rfc3339DateFormatter.locale = enUSPOSIXLocale
                    rfc3339DateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
                    rfc3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                    if let date = rfc3339DateFormatter.date(from: skin.toNSObject(atIndex: -1) as! String) {
                        value = date as CFDate
                    } else {
                        lua_pop(L, 1)
                        skin.logError(String(format: "%s:invalid date format specified for conversion", USERDATA_TAG))
                        return kCFNull
                    }
                } else {
                    lua_pop(L, 1)
                    skin.logError(String(format: "%s:invalid date format specified for conversion", USERDATA_TAG))
                    return kCFNull
                }
                lua_pop(L, 1)
            } else if has__luaSkinType {
                let object = skin.toNSObject(atIndex: index) as! NSObject
                if let color = object as? NSColor {
                    value = CFRetain(color.cgColor)
                } else if object is NSURL {
                    value = object as CFTypeRef
                } else if let image = object as? NSImage {
                    value = CFRetain(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                } else if object is NSAttributedString {
                    value = object as CFTypeRef
                } else {
                    lua_getfield(L, index, "__luaSkinType")
                    skin.logError(String(format: "%s:__luaSkinType table %s not supported for conversion", USERDATA_TAG, lua_tostring(L, -1)!))
                    lua_pop(L, 1)
                    return kCFNull
                }
            } else { // real CFDictionary or CFArray
                seen[NSValue(pointer: lua_topointer(L, index))] = NSNumber(value: true)
                if luaL_len(L, index) == skin.countNatIndex(index) { // CFArray
                    let holder = CFArrayCreateMutable(kCFAllocatorDefault, 0, nil)!
                    for i in 0..<luaL_len(L, index) {
                        lua_geti(L, index, i + 1)
                        let theVal = lua_toCFTypeHamster(L, -1, seen)
                        CFArrayAppendValue(holder, Unmanaged.passUnretained(theVal).toOpaque())
                        lua_pop(L, 1)
                    }
                    value = holder
                } else { // CFDictionary
                    let holder = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, nil, nil)!
                    lua_pushnil(L)
                    while lua_next(L, index) != 0 {
                        let theKey = lua_toCFTypeHamster(L, -2, seen)
                        let theVal = lua_toCFTypeHamster(L, -1, seen)
                        CFDictionarySetValue(holder,
                                             Unmanaged.passUnretained(theKey).toOpaque(),
                                             Unmanaged.passUnretained(theVal).toOpaque())
                        lua_pop(L, 1)
                    }
                    value = holder
                }
            }
        } else if theType == LUA_TUSERDATA {
            if luaL_testudata(L, index, "hs.styledtext") != nil {
                value = skin.toNSObject(atIndex: index) as! NSAttributedString as CFTypeRef
            } else if luaL_testudata(L, index, USERDATA_TAG) != nil {
                let ref = get_axuielementref(L, index, USERDATA_TAG)
                value = CFRetain(ref)
            } else if luaL_testudata(L, index, OBSERVER_TAG) != nil {
                let ref = get_axobserverref(L, index, OBSERVER_TAG)
                value = CFRetain(ref)
            } else if luaL_testudata(L, index, AXTEXTMARKER_TAG) != nil {
                let ref = get_axtextmarkerref(L, index, AXTEXTMARKER_TAG)
                value = CFRetain(ref)
            } else if luaL_testudata(L, index, AXTEXTMRKRNG_TAG) != nil {
                let ref = get_axtextmarkerrangeref(L, index, AXTEXTMRKRNG_TAG)
                value = CFRetain(ref)
            } else {
                skin.logError(String(format: "%s:unrecognized userdata is not supported for conversion", USERDATA_TAG))
                return kCFNull
            }
        } else if theType != LUA_TNIL { // value already set to kCFNull, no specific match necessary
            skin.logError(String(format: "%s:type %s not supported for conversion", USERDATA_TAG, lua_typename(L, theType)!))
            return kCFNull
        }
    }
    return value
}

@_cdecl("pushCFTypeToLua")
@discardableResult
public func pushCFTypeToLua(_ L: OpaquePointer!, _ theItem: CFTypeRef?, _ refTable: LSRefTable) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let alreadySeen = NSMutableDictionary()
    pushCFTypeHamster(L, theItem, alreadySeen, refTable)
    for entry in alreadySeen {
        if let seenRef = entry.value as? NSNumber {
            skin.luaUnref(refTable, ref: seenRef.int32Value)
        }
    }
    return 1
}

@_cdecl("lua_toCFType")
public func lua_toCFType(_ L: OpaquePointer!, _ idx: Int32) -> CFTypeRef {
    let seen = NSMutableDictionary()
    return lua_toCFTypeHamster(L, idx, seen)
}
