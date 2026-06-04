import Cocoa
import CLua

// MARK: - Lua userdata conversion seam

/// Objects that can be pushed by `lua_pushany` as retained userdata.
///
/// Extension modules still own their metatable names and any side bookkeeping
/// such as self-reference counts. This protocol keeps the retained pointer
/// storage and metatable installation in one place without making `lua_tovalue`
/// guess at arbitrary userdata.
protocol LuaUserdataConvertible: AnyObject {
    var luaUserdataMetatableName: String { get }
    func luaUserdataWillRetain()
}

// MARK: - Boolean detection

/// Detect whether a value is a CFBoolean (__NSCFBoolean).
/// Swift's pattern matching and type bridging can re-box NSNumber values,
/// losing the __NSCFBoolean singleton identity. We use a type comparison
/// against the known CFBoolean type to detect booleans reliably.
private func isCFBoolean(_ obj: Any) -> Bool {
    guard let nsNum = obj as? NSNumber else { return false }
    return nsNum === kCFBooleanTrue || nsNum === kCFBooleanFalse
}

/// Get the boolean value from any value that `isCFBoolean` returns true for.
private func cfBooleanValue(_ obj: Any) -> Bool {
    return (obj as? NSNumber)?.boolValue ?? false
}

// MARK: - Push helpers: Swift/Foundation values -> Lua stack

/// Maximum recursion depth for nested tables to prevent stack overflow.
private let kMaxPushDepth: Int = 50

/// Push any Swift/Foundation value onto the Lua stack.
///
/// Handles: nil, Bool, Int, Double, Float, String, NSString, NSNumber
/// (with Bool detection via kCFBooleanTrue/kCFBooleanFalse), NSDate,
/// NSURL, NSData, NSNull, Array/NSArray, Dictionary/NSDictionary.
/// Unknown types are pushed as their debugDescription string.
func lua_pushany(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?) {
    lua_pushvalue_recursive(L, value, depth: 0)
}

private func lua_pushvalue_recursive(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?, depth: Int) {
    guard depth < kMaxPushDepth else {
        lua_pushnil(L)
        return
    }

    guard let value = value else {
        lua_pushnil(L)
        return
    }

    // Unwrap Optional<Any> layers that NSArray/NSDictionary can produce.
    let obj: Any
    if let optional = value as? Any?, optional == nil {
        lua_pushnil(L)
        return
    } else {
        obj = value
    }

    // Check for CFBoolean BEFORE the switch statement, since Swift's
    // pattern matching can re-box NSNumber values and lose the identity
    // of kCFBooleanTrue / kCFBooleanFalse singletons.
    if isCFBoolean(obj) {
        lua_pushboolean(L, cfBooleanValue(obj) ? 1 : 0)
        return
    }

    switch obj {

    // NSNull (must come before NSNumber because NSNull is not an NSNumber)
    case is NSNull:
        lua_pushnil(L)

    // NSNumber — must come before Bool because NSNumber(value: 1) bridges to Bool in Swift
    case let n as NSNumber:
        if lua_pushNSNumber(L, n) {
            // pushed by helper
        } else {
            lua_pushnumber(L, n.doubleValue)
        }

    // Int (Swift native, not bridged through NSNumber path on arm64)
    case let i as Int:
        lua_pushinteger(L, lua_Integer(i))

    case let i as Int32:
        lua_pushinteger(L, lua_Integer(i))

    case let i as Int64:
        lua_pushinteger(L, lua_Integer(i))

    case let i as UInt:
        lua_pushinteger(L, lua_Integer(i))

    case let i as UInt32:
        lua_pushinteger(L, lua_Integer(i))

    // Double
    case let d as Double:
        lua_pushnumber(L, d)

    // Float
    case let f as Float:
        lua_pushnumber(L, lua_Number(f))

    // String (Swift)
    case let s as String:
        s.withCString { cstr in
            let len = s.utf8.count
            lua_pushlstring(L, cstr, len)
        }

    // NSString
    case let ns as NSString:
        let len = ns.lengthOfBytes(using: String.Encoding.utf8.rawValue)
        if let cstr = ns.utf8String {
            lua_pushlstring(L, cstr, len)
        } else {
            lua_pushnil(L)
        }

    // NSData -> raw bytes string
    case let data as NSData:
        lua_pushlstring(L, data.bytes.assumingMemoryBound(to: CChar.self), data.length)

    // Data (Swift) -> raw bytes string
    case let data as Data:
        lua_pushdata(L, data)

    // NSDate -> epoch seconds (integer)
    case let date as NSDate:
        lua_pushnumber(L, date.timeIntervalSince1970)

    // NSURL -> string
    case let url as NSURL:
        if let abs = url.absoluteString {
            lua_pushstring(L, abs)
        } else {
            lua_pushnil(L)
        }

    // URL (Swift)
    case let url as URL:
        lua_pushstring(L, url.absoluteString)

    // NSArray / Array
    // Use luaL_len+1 for indexing (matching LuaSkin behavior): when a nil
    // is pushed, the next element takes its position, collapsing holes.
    case let arr as NSArray:
        lua_createtable(L, Int32(arr.count), 0)
        for i in 0..<arr.count {
            let item: Any = arr[i]
            lua_pushvalue_recursive(L, item, depth: depth + 1)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }

    case let arr as [Any]:
        lua_createtable(L, Int32(arr.count), 0)
        for item in arr {
            lua_pushvalue_recursive(L, item, depth: depth + 1)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }

    // NSDictionary / Dictionary
    case let dict as NSDictionary:
        lua_createtable(L, 0, Int32(dict.count))
        for (key, val) in dict {
            lua_pushvalue_recursive(L, key, depth: depth + 1)
            lua_pushvalue_recursive(L, val, depth: depth + 1)
            lua_settable(L, -3)
        }

    case let dict as [String: Any]:
        lua_createtable(L, 0, Int32(dict.count))
        for (key, val) in dict {
            lua_pushstring(L, key)
            lua_pushvalue_recursive(L, val, depth: depth + 1)
            lua_settable(L, -3)
        }

    // NSValue containing geometry types
    case let val as NSValue:
        lua_pushNSValue(L, val)

    case let color as NSColor:
        if lua_pushNSColor(L, color) {
            return
        }
        lua_pushstring(L, String(describing: obj))

    // Known retained-pointer userdata adapters.
    case let image as NSImage:
        image.cacheMode = .never
        if lua_pushretainedUserdata(L, image, metatableName: "hs.image") {
            return
        }
        lua_pushstring(L, String(describing: obj))

    case let attributedString as NSAttributedString:
        if lua_pushretainedUserdata(L, attributedString, metatableName: "hs.styledtext") {
            return
        }
        lua_pushstring(L, String(describing: obj))

    case let convertible as LuaUserdataConvertible:
        if lua_pushretainedUserdata(
            L,
            convertible,
            metatableName: convertible.luaUserdataMetatableName,
            beforeRetain: { convertible.luaUserdataWillRetain() }
        ) {
            return
        }
        lua_pushstring(L, String(describing: obj))

    // Fallback: push the debugDescription
    default:
        let desc = String(describing: obj)
        lua_pushstring(L, desc)
    }
}

/// Push an NSNumber as the appropriate Lua type (integer or number).
/// Returns true if it was pushed successfully.
private func lua_pushNSNumber(_ L: UnsafeMutablePointer<lua_State>!, _ number: NSNumber) -> Bool {
    let t = number.objCType.pointee
    switch t {
    case CChar(UInt8(ascii: "c")), CChar(UInt8(ascii: "C")),
         CChar(UInt8(ascii: "s")), CChar(UInt8(ascii: "S")),
         CChar(UInt8(ascii: "i")), CChar(UInt8(ascii: "I")),
         CChar(UInt8(ascii: "l")), CChar(UInt8(ascii: "L")),
         CChar(UInt8(ascii: "q")):
        lua_pushinteger(L, lua_Integer(number.int64Value))
        return true
    case CChar(UInt8(ascii: "Q")):
        // Unsigned long long: use integer if it fits, otherwise double
        let val = number.uint64Value
        if val < 0x8000000000000000 {
            lua_pushinteger(L, lua_Integer(Int64(val)))
        } else {
            lua_pushnumber(L, lua_Number(val))
        }
        return true
    case CChar(UInt8(ascii: "f")):
        lua_pushnumber(L, lua_Number(number.floatValue))
        return true
    case CChar(UInt8(ascii: "d")):
        lua_pushnumber(L, number.doubleValue)
        return true
    default:
        lua_pushnumber(L, number.doubleValue)
        return true
    }
}

/// Push an NSValue as a Lua table. Handles NSPoint, NSSize, NSRect, NSRange.
private func lua_pushNSValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: NSValue) {
    let objCType = String(cString: value.objCType)

    // Compare against the @encode strings for the geometry types.
    let pointType = String(cString: NSValue(point: .zero).objCType)
    let sizeType = String(cString: NSValue(size: .zero).objCType)
    let rectType = String(cString: NSValue(rect: .zero).objCType)
    let rangeType = String(cString: NSValue(range: NSRange(location: 0, length: 0)).objCType)

    if objCType == pointType {
        lua_pushNSPoint(L, value.pointValue)
    } else if objCType == sizeType {
        lua_pushNSSize(L, value.sizeValue)
    } else if objCType == rectType {
        lua_pushNSRect(L, value.rectValue)
    } else if objCType == rangeType {
        let range = value.rangeValue
        lua_createtable(L, 0, 3)
        lua_pushinteger(L, lua_Integer(range.location)); lua_setfield(L, -2, "location")
        lua_pushinteger(L, lua_Integer(range.length));   lua_setfield(L, -2, "length")
        lua_pushstring(L, "NSRange");                    lua_setfield(L, -2, "__luaSkinType")
    } else {
        // Unknown NSValue type: push description
        lua_pushstring(L, value.description)
    }
}

// MARK: - Geometry push helpers

/// Push an NSPoint as a Lua table `{x=n, y=n, __luaSkinType="NSPoint"}`.
func lua_pushNSPoint(_ L: UnsafeMutablePointer<lua_State>!, _ point: NSPoint) {
    lua_createtable(L, 0, 3)
    lua_pushnumber(L, lua_Number(point.x)); lua_setfield(L, -2, "x")
    lua_pushnumber(L, lua_Number(point.y)); lua_setfield(L, -2, "y")
    lua_pushstring(L, "NSPoint");           lua_setfield(L, -2, "__luaSkinType")
}

/// Push an NSSize as a Lua table `{w=n, h=n, __luaSkinType="NSSize"}`.
func lua_pushNSSize(_ L: UnsafeMutablePointer<lua_State>!, _ size: NSSize) {
    lua_createtable(L, 0, 3)
    lua_pushnumber(L, lua_Number(size.width));  lua_setfield(L, -2, "w")
    lua_pushnumber(L, lua_Number(size.height)); lua_setfield(L, -2, "h")
    lua_pushstring(L, "NSSize");                lua_setfield(L, -2, "__luaSkinType")
}

/// Push an NSRect as a Lua table `{x=n, y=n, w=n, h=n, __luaSkinType="NSRect"}`.
func lua_pushNSRect(_ L: UnsafeMutablePointer<lua_State>!, _ rect: NSRect) {
    lua_createtable(L, 0, 5)
    lua_pushnumber(L, lua_Number(rect.origin.x));    lua_setfield(L, -2, "x")
    lua_pushnumber(L, lua_Number(rect.origin.y));    lua_setfield(L, -2, "y")
    lua_pushnumber(L, lua_Number(rect.size.width));  lua_setfield(L, -2, "w")
    lua_pushnumber(L, lua_Number(rect.size.height)); lua_setfield(L, -2, "h")
    lua_pushstring(L, "NSRect");                     lua_setfield(L, -2, "__luaSkinType")
}

/// Push an RGB-convertible NSColor as a Lua table `{red=n, green=n, blue=n, alpha=n}`.
@discardableResult
func lua_pushNSColor(_ L: UnsafeMutablePointer<lua_State>!, _ color: NSColor) -> Bool {
    guard let converted = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else {
        return false
    }
    lua_createtable(L, 0, 5)
    lua_pushnumber(L, lua_Number(converted.redComponent));   lua_setfield(L, -2, "red")
    lua_pushnumber(L, lua_Number(converted.greenComponent)); lua_setfield(L, -2, "green")
    lua_pushnumber(L, lua_Number(converted.blueComponent));  lua_setfield(L, -2, "blue")
    lua_pushnumber(L, lua_Number(converted.alphaComponent)); lua_setfield(L, -2, "alpha")
    lua_pushstring(L, "NSColor");                           lua_setfield(L, -2, "__luaSkinType")
    return true
}

// MARK: - Raw bytes and retained userdata helpers

/// Push raw bytes as a Lua string. Lua strings are byte buffers and may contain NULs.
func lua_pushdata(_ L: UnsafeMutablePointer<lua_State>!, _ data: Data) {
    _ = data.withUnsafeBytes { ptr in
        if let base = ptr.baseAddress {
            lua_pushlstring(L, base.assumingMemoryBound(to: CChar.self), data.count)
        } else {
            lua_pushlstring(L, "", 0)
        }
    }
}

/// Pull a Lua string as raw bytes without UTF-8 decoding or NUL truncation.
func lua_todata(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> Data? {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TSTRING else { return nil }

    var len: Int = 0
    guard let ptr = lua_tolstring(L, idx, &len) else { return nil }
    return Data(bytes: ptr, count: len)
}

/// Checked raw-byte pull for APIs that accept binary Lua strings.
func lua_checkdata(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> Data {
    luaL_checktype(L, index, LUA_TSTRING)
    guard let data = lua_todata(L, at: index) else {
        _ = luaL_argerror(L, index, "string expected")
        fatalError("luaL_argerror returned")
    }
    return data
}

/// Pull a Lua string as Swift text while respecting Lua's byte length.
func lua_tostringValue(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> String? {
    guard let data = lua_todata(L, at: index) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// Store a retained Swift/Objective-C object pointer in userdata and attach a metatable.
@discardableResult
func lua_pushretainedUserdata(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ object: AnyObject,
    metatableName: String,
    beforeRetain: (() -> Void)? = nil
) -> Bool {
    luaL_getmetatable(L, metatableName)
    guard lua_type(L, -1) != LUA_TNIL else {
        lua_pop(L, 1)
        return false
    }

    beforeRetain?()
    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer?>.size)!
    ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = Unmanaged.passRetained(object).toOpaque()
    lua_pushvalue(L, -2)
    lua_setmetatable(L, -2)
    lua_remove(L, -2)
    return true
}

/// Pull a retained-pointer userdata object if the metatable and runtime type both match.
func lua_testUserdataObject<T: AnyObject>(
    _ type: T.Type,
    _ L: UnsafeMutablePointer<lua_State>!,
    at index: Int32,
    metatableName: String
) -> T? {
    guard let ptr = luaL_testudata(L, index, metatableName) else { return nil }
    guard let opaque = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee else { return nil }
    let object = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(opaque)).takeUnretainedValue()
    return object as? T
}

/// Checked retained-pointer userdata pull with Lua argument errors for invalid casts.
func lua_checkUserdataObject<T: AnyObject>(
    _ type: T.Type,
    _ L: UnsafeMutablePointer<lua_State>!,
    at index: Int32,
    metatableName: String
) -> T {
    guard let object = lua_testUserdataObject(type, L, at: index, metatableName: metatableName) else {
        _ = luaL_argerror(L, index, "\(metatableName) userdata expected")
        fatalError("luaL_argerror returned")
    }
    return object
}

/// Transfer the retained object out of userdata if it has not already been cleared.
func lua_takeRetainedUserdataObjectIfPresent<T: AnyObject>(
    _ type: T.Type,
    _ L: UnsafeMutablePointer<lua_State>!,
    at index: Int32,
    metatableName: String
) -> T? {
    let ptr = luaL_checkudata(L, index, metatableName)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let opaque = ptr.pointee else {
        return nil
    }
    ptr.pointee = nil
    let object = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(opaque)).takeRetainedValue()
    guard let typed = object as? T else {
        _ = luaL_argerror(L, index, "\(metatableName) userdata type mismatch")
        fatalError("luaL_argerror returned")
    }
    return typed
}

/// Transfer the retained object out of userdata, for use outside tolerant `__gc` paths.
func lua_takeRetainedUserdataObject<T: AnyObject>(
    _ type: T.Type,
    _ L: UnsafeMutablePointer<lua_State>!,
    at index: Int32,
    metatableName: String
) -> T {
    guard let object = lua_takeRetainedUserdataObjectIfPresent(type, L, at: index, metatableName: metatableName) else {
        _ = luaL_argerror(L, index, "\(metatableName) userdata pointer missing")
        fatalError("luaL_argerror returned")
    }
    return object
}

/// Pull struct-backed userdata as a typed pointer after checking its metatable.
func lua_checkUserdataPointer<T>(
    _ type: T.Type,
    _ L: UnsafeMutablePointer<lua_State>!,
    at index: Int32,
    metatableName: String
) -> UnsafeMutablePointer<T> {
    guard let ptr = luaL_testudata(L, index, metatableName) else {
        _ = luaL_argerror(L, index, "\(metatableName) userdata expected")
        fatalError("luaL_argerror returned")
    }
    return ptr.assumingMemoryBound(to: T.self)
}

func lua_unrefRegistryRef(_ L: UnsafeMutablePointer<lua_State>!, _ ref: inout Int32) {
    if ref != LUA_NOREF && ref != LUA_REFNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, ref)
        ref = LUA_NOREF
    }
}

func lua_replaceRegistryFunctionRef(_ L: UnsafeMutablePointer<lua_State>!, _ ref: inout Int32, at index: Int32) {
    lua_unrefRegistryRef(L, &ref)
    let valueType = lua_type(L, index)
    if valueType == LUA_TNONE || valueType == LUA_TNIL {
        return
    }
    guard valueType == LUA_TFUNCTION else {
        _ = luaL_argerror(L, index, "function or nil expected")
        fatalError("luaL_argerror returned")
    }
    lua_pushvalue(L, index)
    ref = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
}

// MARK: - Pull helpers: Lua stack -> Swift values

/// Pull a value from the Lua stack as a Swift `Any?`.
///
/// Handles: string, number (integer or float), boolean, table
/// (array if sequential integer keys 1..n, otherwise dictionary), nil.
func lua_tovalue(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> Any? {
    lua_tovalue_recursive(L, at: index, depth: 0)
}

private func lua_tovalue_recursive(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32, depth: Int) -> Any? {
    guard depth < kMaxPushDepth else { return nil }

    let idx = lua_absindex(L, index)

    switch lua_type(L, idx) {
    case LUA_TNIL:
        return nil

    case LUA_TBOOLEAN:
        return lua_toboolean(L, idx) != 0

    case LUA_TNUMBER:
        if lua_isinteger(L, idx) != 0 {
            return Int(lua_tointeger(L, idx))
        } else {
            return lua_tonumber(L, idx)
        }

    case LUA_TSTRING:
        return lua_tostringValue(L, at: idx)

    case LUA_TTABLE:
        return lua_tableToValue(L, at: idx, depth: depth)

    case LUA_TUSERDATA:
        return nil

    default:
        return nil
    }
}

/// Convert a Lua table at the given stack index to either an Array or Dictionary.
private func lua_tableToValue(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32, depth: Int) -> Any? {
    let absIdx = lua_absindex(L, idx)

    // Determine if array-like: count total keys and find max integer key.
    var totalKeys: Int = 0
    var maxIntKey: lua_Integer = 0
    var allIntKeys = true

    lua_pushnil(L)
    while lua_next(L, absIdx) != 0 {
        lua_pop(L, 1) // pop value, keep key
        totalKeys += 1
        if lua_type(L, -1) == LUA_TNUMBER && lua_isinteger(L, -1) != 0 {
            let k = lua_tointeger(L, -1)
            if k < 1 { allIntKeys = false }
            if k > maxIntKey { maxIntKey = k }
        } else {
            allIntKeys = false
        }
    }

    if totalKeys == 0 {
        // Empty table: default to empty array
        return [Any]()
    }

    if allIntKeys && maxIntKey == lua_Integer(totalKeys) {
        // Sequential integer keys from 1..n -> Array
        var arr = [Any]()
        arr.reserveCapacity(totalKeys)
        for i in 1...totalKeys {
            lua_rawgeti(L, absIdx, lua_Integer(i))
            let val = lua_tovalue_recursive(L, at: -1, depth: depth + 1) ?? NSNull()
            arr.append(val)
            lua_pop(L, 1)
        }
        return arr
    } else {
        // Dictionary
        var dict = [String: Any]()
        lua_pushnil(L)
        while lua_next(L, absIdx) != 0 {
            let val = lua_tovalue_recursive(L, at: -1, depth: depth + 1)
            lua_pop(L, 1) // pop value, keep key

            // Convert key to string
            let keyStr: String?
            switch lua_type(L, -1) {
            case LUA_TSTRING:
                keyStr = lua_tostringValue(L, at: -1)
            case LUA_TNUMBER:
                if lua_isinteger(L, -1) != 0 {
                    keyStr = String(lua_tointeger(L, -1))
                } else {
                    keyStr = String(lua_tonumber(L, -1))
                }
            default:
                keyStr = nil
            }

            if let key = keyStr, let v = val {
                dict[key] = v
            }
        }
        return dict
    }
}

// MARK: - Geometry pull helpers

/// Read an NSPoint from a Lua table at the given stack index.
/// Expected format: `{x=n, y=n}`. Missing fields default to 0.
func lua_tableToPoint(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSPoint {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return .zero }

    let x: CGFloat = (lua_getfield(L, idx, "x") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    let y: CGFloat = (lua_getfield(L, idx, "y") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    lua_pop(L, 2)
    return NSMakePoint(x, y)
}

/// Read an NSSize from a Lua table at the given stack index.
/// Expected format: `{w=n, h=n}`. Missing fields default to 0.
func lua_tableToSize(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSSize {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return .zero }

    let w: CGFloat = (lua_getfield(L, idx, "w") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    let h: CGFloat = (lua_getfield(L, idx, "h") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    lua_pop(L, 2)
    return NSMakeSize(w, h)
}

/// Read an NSRect from a Lua table at the given stack index.
/// Expected format: `{x=n, y=n, w=n, h=n}`. Missing fields default to 0.
func lua_tableToRect(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSRect {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return .zero }

    let x: CGFloat = (lua_getfield(L, idx, "x") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    let y: CGFloat = (lua_getfield(L, idx, "y") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    let w: CGFloat = (lua_getfield(L, idx, "w") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    let h: CGFloat = (lua_getfield(L, idx, "h") == LUA_TNUMBER) ? CGFloat(lua_tonumber(L, -1)) : 0.0
    lua_pop(L, 4)
    return NSMakeRect(x, y, w, h)
}

// MARK: - Typed userdata extraction helpers

/// Extract an NSImage from hs.image userdata at the given stack index.
func toNSImage(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSImage? {
    lua_testUserdataObject(NSImage.self, L, at: idx, metatableName: "hs.image")
}

/// Extract any class-pointer userdata as AnyObject. Only safe for userdata
/// that stores an Unmanaged<T>.toOpaque() pointer (the standard pattern for
/// class-based extensions). NOT safe for struct-based userdata (e.g., Milight).
func lua_toAnyObject(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject? {
    guard lua_type(L, idx) == LUA_TUSERDATA else { return nil }
    guard let ptr = lua_touserdata(L, idx) else { return nil }
    guard let opaque = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(opaque)).takeUnretainedValue()
}

/// Extract an NSAttributedString from hs.styledtext userdata at the given stack index.
func toNSAttributedString(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSAttributedString? {
    lua_testUserdataObject(NSAttributedString.self, L, at: idx, metatableName: "hs.styledtext")
}

/// Convert a Lua color table `{red=, green=, blue=, alpha=}` to NSColor.
func tableToNSColor(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSColor? {
    guard lua_type(L, idx) == LUA_TTABLE else { return nil }
    let absIdx = lua_absindex(L, idx)
    lua_getfield(L, absIdx, "red")
    let r = lua_isnumber(L, -1) != 0 ? CGFloat(lua_tonumber(L, -1)) : 0
    lua_getfield(L, absIdx, "green")
    let g = lua_isnumber(L, -1) != 0 ? CGFloat(lua_tonumber(L, -1)) : 0
    lua_getfield(L, absIdx, "blue")
    let b = lua_isnumber(L, -1) != 0 ? CGFloat(lua_tonumber(L, -1)) : 0
    lua_getfield(L, absIdx, "alpha")
    let a = lua_isnumber(L, -1) != 0 ? CGFloat(lua_tonumber(L, -1)) : 1.0
    lua_pop(L, 4)
    return NSColor(red: r, green: g, blue: b, alpha: a)
}

/// Convert a Lua font table `{name=, size=}` or font name string to NSFont.
func tableToNSFont(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSFont? {
    var theName = NSFont.systemFont(ofSize: 0).fontName
    var theSize = NSFont.systemFontSize

    if lua_type(L, idx) == LUA_TSTRING {
        theName = lua_tostringValue(L, at: idx) ?? theName
    } else if lua_type(L, idx) == LUA_TTABLE {
        if lua_getfield(L, idx, "name") == LUA_TSTRING {
            theName = lua_tostringValue(L, at: -1) ?? theName
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "size") == LUA_TNUMBER {
            theSize = CGFloat(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
    } else {
        return nil
    }

    return NSFont(name: theName, size: theSize) ?? NSFont.systemFont(ofSize: theSize)
}

// MARK: - Global lua_State accessor

private var _currentLuaState: UnsafeMutablePointer<lua_State>?

func lua_setCurrentState(_ L: UnsafeMutablePointer<lua_State>?) {
    _currentLuaState = L
}

func lua_getCurrentState() -> UnsafeMutablePointer<lua_State>? {
    return _currentLuaState
}

// MARK: - GC Canary (replaces LSGCCanary)

private var _luaStateGeneration: UInt64 = 0

func lua_bumpStateGeneration() {
    _luaStateGeneration &+= 1
}

func lua_currentStateGeneration() -> UInt64 {
    return _luaStateGeneration
}

func lua_isStateGenerationValid(_ generation: UInt64) -> Bool {
    return generation == _luaStateGeneration
}

// MARK: - ObjC Exception Safety

@_silgen_name("objc_tryCatch")
private func _objc_tryCatch(_ block: @convention(block) () -> Void, _ outError: UnsafeMutablePointer<NSString?>?) -> Bool

/// Run a closure that may trigger an NSException. Returns the error
/// description if an exception was caught, or nil on success.
func catchingObjCException(_ block: () -> Void) -> String? {
    var error: NSString?
    let ok = _objc_tryCatch(block, &error)
    return ok ? nil : (error as String? ?? "unknown ObjC exception")
}

/// Run a closure that may trigger an NSException, returning a value.
/// Returns nil if an exception was caught.
func catchingObjCException<T>(_ block: () -> T?) -> T? {
    var result: T?
    var error: NSString?
    let ok = _objc_tryCatch({ result = block() }, &error)
    return ok ? result : nil
}
