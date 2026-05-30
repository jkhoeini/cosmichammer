import Cocoa
import CLua
import os.log

// MARK: - Canvas value conversion

private let canvasMaxConversionDepth = 50

private let canvasObjectUserdataGC: lua_CFunction = { L in
    guard let L = L, let ptr = lua_touserdata(L, 1) else { return 0 }
    let raw = ptr.load(as: UnsafeRawPointer.self)
    _ = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
    return 0
}

func canvas_valueFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32, forKey keyName: String? = nil) -> Any? {
    canvas_valueFromLuaRecursive(L, at: index, forKey: keyName, depth: 0)
}

private func canvas_valueFromLuaRecursive(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32, forKey keyName: String?, depth: Int) -> Any? {
    guard depth < canvasMaxConversionDepth else { return nil }
    let idx = lua_absindex(L, index)

    if let keyName = keyName {
        if keyName == "fillGradientColors" {
            return canvas_gradientColorsFromLua(L, at: idx)
        } else if keyName.hasSuffix("Color") {
            return canvas_colorFromLua(L, at: idx)
        } else if keyName == "image" {
            return canvas_imageFromLua(L, at: idx)
        } else if keyName == "text" {
            if lua_type(L, idx) == LUA_TTABLE || lua_type(L, idx) == LUA_TUSERDATA {
                return canvas_styledTextFromLua(L, at: idx)
            }
            return canvas_valueFromLuaRecursive(L, at: idx, forKey: nil, depth: depth + 1)
        } else if keyName == "transformation" {
            return canvas_transformFromLua(L, at: idx)
        } else if keyName == "shadow" {
            return canvas_shadowFromLua(L, at: idx)
        } else if keyName == "canvas" {
            return lua_toAnyObject(L, at: idx) as? NSView
        }
    }

    switch lua_type(L, idx) {
    case LUA_TNIL, LUA_TNONE:
        return nil
    case LUA_TBOOLEAN:
        return NSNumber(value: lua_toboolean(L, idx) != 0)
    case LUA_TNUMBER:
        if lua_isinteger(L, idx) != 0 {
            return NSNumber(value: lua_tointeger(L, idx))
        }
        return NSNumber(value: lua_tonumber(L, idx))
    case LUA_TSTRING:
        return canvas_stringFromLua(L, at: idx)
    case LUA_TTABLE:
        return canvas_tableFromLua(L, at: idx, depth: depth + 1)
    case LUA_TUSERDATA:
        return canvas_imageFromLua(L, at: idx) ?? canvas_styledTextFromLua(L, at: idx)
    default:
        return nil
    }
}

private func canvas_tableFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32, depth: Int) -> Any? {
    let idx = lua_absindex(L, index)
    var totalKeys = 0
    var maxIntKey: lua_Integer = 0
    var allIntKeys = true

    lua_pushnil(L)
    while lua_next(L, idx) != 0 {
        lua_pop(L, 1)
        totalKeys += 1
        if lua_type(L, -1) == LUA_TNUMBER && lua_isinteger(L, -1) != 0 {
            let key = lua_tointeger(L, -1)
            if key < 1 { allIntKeys = false }
            if key > maxIntKey { maxIntKey = key }
        } else {
            allIntKeys = false
        }
    }

    if totalKeys == 0 { return NSMutableArray() }

    if allIntKeys && maxIntKey == lua_Integer(totalKeys) {
        let result = NSMutableArray(capacity: totalKeys)
        for i in 1...totalKeys {
            lua_rawgeti(L, idx, lua_Integer(i))
            result.add(canvas_valueFromLuaRecursive(L, at: -1, forKey: nil, depth: depth + 1) ?? NSNull())
            lua_pop(L, 1)
        }
        return result
    }

    let result = NSMutableDictionary(capacity: totalKeys)
    lua_pushnil(L)
    while lua_next(L, idx) != 0 {
        let key = canvas_tableKeyFromLua(L, at: -2)
        if key as? String != "__luaSkinType",
           let value = canvas_valueFromLuaRecursive(L, at: -1, forKey: key as? String, depth: depth + 1) {
            result[key] = value
        }
        lua_pop(L, 1)
    }
    return result
}

private func canvas_tableKeyFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSCopying {
    let idx = lua_absindex(L, index)
    if lua_type(L, idx) == LUA_TSTRING, let value = canvas_stringFromLua(L, at: idx) {
        return value as NSString
    } else if lua_type(L, idx) == LUA_TNUMBER {
        if lua_isinteger(L, idx) != 0 {
            return NSNumber(value: lua_tointeger(L, idx))
        }
        return NSNumber(value: lua_tonumber(L, idx))
    }
    return String(cString: lua_typename(L, lua_type(L, idx))) as NSString
}

private func canvas_stringFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> String? {
    var len: Int = 0
    guard let ptr = lua_tolstring(L, index, &len) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: len), as: UTF8.self)
}

private func canvas_numberFromLua(_ L: UnsafeMutablePointer<lua_State>!, at tableIndex: Int32, field: String) -> CGFloat? {
    let idx = lua_absindex(L, tableIndex)
    let type = lua_getfield(L, idx, field)
    defer { lua_pop(L, 1) }
    guard type == LUA_TNUMBER else { return nil }
    return CGFloat(lua_tonumber(L, -1))
}

private func canvas_stringFromLua(_ L: UnsafeMutablePointer<lua_State>!, at tableIndex: Int32, field: String) -> String? {
    let idx = lua_absindex(L, tableIndex)
    let type = lua_getfield(L, idx, field)
    defer { lua_pop(L, 1) }
    guard type == LUA_TSTRING else { return nil }
    return canvas_stringFromLua(L, at: -1)
}

func canvas_imageFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSImage? {
    toNSImage(L, at: index)
}

func canvas_styledTextFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSAttributedString? {
    let idx = lua_absindex(L, index)
    if let attributedString = toNSAttributedString(L, at: idx) {
        return attributedString
    }

    if lua_type(L, idx) == LUA_TSTRING || lua_type(L, idx) == LUA_TNUMBER {
        luaL_tolstring(L, idx, nil)
        let value = canvas_stringFromLua(L, at: -1) ?? ""
        lua_pop(L, 1)
        return NSAttributedString(string: value)
    }

    guard lua_type(L, idx) == LUA_TTABLE else { return nil }

    lua_rawgeti(L, idx, 1)
    luaL_tolstring(L, -1, nil)
    lua_remove(L, -2)
    let baseString = canvas_stringFromLua(L, at: -1) ?? ""
    lua_pop(L, 1)

    let result = NSMutableAttributedString(string: baseString)
    let byteMap = canvas_luaByteToObjCharMap(baseString as NSString)
    var styleIndex: lua_Integer = 2
    while lua_rawgeti(L, idx, styleIndex) != LUA_TNIL {
        if lua_type(L, -1) == LUA_TTABLE {
            let styleTable = lua_absindex(L, -1)
            let start = canvas_numberFromLua(L, at: styleTable, field: "starts").map { lua_Integer($0) } ?? 1
            let end = canvas_numberFromLua(L, at: styleTable, field: "ends").map { lua_Integer($0) } ?? lua_Integer(baseString.utf8.count)
            let resolved = canvas_luaRangeToObjCRange(byteMap, len: lua_Integer(baseString.utf8.count), luaI: start, luaJ: end)
            if !resolved.empty {
                lua_getfield(L, styleTable, "attributes")
                if let attributes = canvas_textAttributesFromLua(L, at: -1) {
                    result.setAttributes(attributes, range: NSRange(location: Int(resolved.i - 1), length: Int(resolved.j - (resolved.i - 1))))
                }
                lua_pop(L, 1)
            }
        }
        styleIndex += 1
        lua_pop(L, 1)
    }
    lua_pop(L, 1)
    return result
}

func canvas_colorFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSColor? {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return nil }

    if lua_getfield(L, idx, "image") == LUA_TUSERDATA, let image = canvas_imageFromLua(L, at: -1) {
        lua_pop(L, 1)
        return NSColor(patternImage: image)
    }
    lua_pop(L, 1)

    let alpha = canvas_numberFromLua(L, at: idx, field: "alpha") ?? 1.0
    if let list = canvas_stringFromLua(L, at: idx, field: "list"),
       let name = canvas_stringFromLua(L, at: idx, field: "name"),
       let color = NSColorList(named: list)?.color(withKey: NSColor.Name(name)) {
        return color
    }

    if let hex = canvas_stringFromLua(L, at: idx, field: "hex"),
       let color = canvas_colorFromHexString(hex, alpha: alpha) {
        return color
    }

    if let hue = canvas_numberFromLua(L, at: idx, field: "hue") {
        return NSColor(calibratedHue: hue,
                       saturation: canvas_numberFromLua(L, at: idx, field: "saturation") ?? 0,
                       brightness: canvas_numberFromLua(L, at: idx, field: "brightness") ?? 0,
                       alpha: alpha)
    }

    if let white = canvas_numberFromLua(L, at: idx, field: "white") {
        return NSColor(calibratedWhite: white, alpha: alpha)
    }

    return NSColor(calibratedRed: canvas_numberFromLua(L, at: idx, field: "red") ?? 0,
                   green: canvas_numberFromLua(L, at: idx, field: "green") ?? 0,
                   blue: canvas_numberFromLua(L, at: idx, field: "blue") ?? 0,
                   alpha: alpha)
}

private func canvas_gradientColorsFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSMutableArray? {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return nil }

    let count = Int(luaL_len(L, idx))
    let result = NSMutableArray(capacity: count)
    guard count > 0 else { return result }

    for i in 1...count {
        lua_rawgeti(L, idx, lua_Integer(i))
        result.add(canvas_colorFromLua(L, at: -1) ?? NSColor.black)
        lua_pop(L, 1)
    }
    return result
}

func canvas_transformFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSAffineTransform? {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return nil }

    let transform = NSAffineTransform()
    var structure = transform.transformStruct
    structure.m11 = canvas_numberFromLua(L, at: idx, field: "m11") ?? structure.m11
    structure.m12 = canvas_numberFromLua(L, at: idx, field: "m12") ?? structure.m12
    structure.m21 = canvas_numberFromLua(L, at: idx, field: "m21") ?? structure.m21
    structure.m22 = canvas_numberFromLua(L, at: idx, field: "m22") ?? structure.m22
    structure.tX = canvas_numberFromLua(L, at: idx, field: "tX") ?? structure.tX
    structure.tY = canvas_numberFromLua(L, at: idx, field: "tY") ?? structure.tY
    transform.transformStruct = structure
    return transform
}

func canvas_shadowFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> NSShadow? {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return nil }

    let shadow = NSShadow()
    if lua_getfield(L, idx, "offset") == LUA_TTABLE {
        shadow.shadowOffset = lua_tableToSize(L, at: -1)
    }
    lua_pop(L, 1)

    if let blurRadius = canvas_numberFromLua(L, at: idx, field: "blurRadius") {
        shadow.shadowBlurRadius = blurRadius
    }

    if lua_getfield(L, idx, "color") == LUA_TTABLE, let color = canvas_colorFromLua(L, at: -1) {
        shadow.shadowColor = color
    }
    lua_pop(L, 1)
    return shadow
}

func canvas_colorFromValue(_ value: Any?) -> NSColor? {
    if let color = value as? NSColor { return color }
    guard let dict = value as? NSDictionary else { return nil }

    if let image = dict["image"] as? NSImage {
        return NSColor(patternImage: image)
    }

    let alpha = canvas_numberFromValue(dict["alpha"]) ?? 1.0
    if let list = dict["list"] as? String,
       let name = dict["name"] as? String,
       let color = NSColorList(named: list)?.color(withKey: NSColor.Name(name)) {
        return color
    }

    if let hex = dict["hex"] as? String,
       let color = canvas_colorFromHexString(hex, alpha: alpha) {
        return color
    }

    if let hue = canvas_numberFromValue(dict["hue"]) {
        return NSColor(calibratedHue: hue,
                       saturation: canvas_numberFromValue(dict["saturation"]) ?? 0,
                       brightness: canvas_numberFromValue(dict["brightness"]) ?? 0,
                       alpha: alpha)
    }

    if let white = canvas_numberFromValue(dict["white"]) {
        return NSColor(calibratedWhite: white, alpha: alpha)
    }

    return NSColor(calibratedRed: canvas_numberFromValue(dict["red"]) ?? 0,
                   green: canvas_numberFromValue(dict["green"]) ?? 0,
                   blue: canvas_numberFromValue(dict["blue"]) ?? 0,
                   alpha: alpha)
}

func canvas_gradientColorsFromValue(_ value: Any?) -> NSMutableArray? {
    if let array = value as? NSArray {
        let result = NSMutableArray(capacity: array.count)
        for item in array {
            result.add(canvas_colorFromValue(item) ?? (item as? NSColor) ?? NSColor.black)
        }
        return result
    }
    return nil
}

func canvas_transformFromValue(_ value: Any?) -> NSAffineTransform? {
    if let transform = value as? NSAffineTransform { return transform }
    guard let dict = value as? NSDictionary else { return nil }

    let transform = NSAffineTransform()
    var structure = transform.transformStruct
    structure.m11 = canvas_numberFromValue(dict["m11"]) ?? structure.m11
    structure.m12 = canvas_numberFromValue(dict["m12"]) ?? structure.m12
    structure.m21 = canvas_numberFromValue(dict["m21"]) ?? structure.m21
    structure.m22 = canvas_numberFromValue(dict["m22"]) ?? structure.m22
    structure.tX = canvas_numberFromValue(dict["tX"]) ?? structure.tX
    structure.tY = canvas_numberFromValue(dict["tY"]) ?? structure.tY
    transform.transformStruct = structure
    return transform
}

func canvas_shadowFromValue(_ value: Any?) -> NSShadow? {
    if let shadow = value as? NSShadow { return shadow }
    guard let dict = value as? NSDictionary else { return nil }

    let shadow = NSShadow()
    if let offset = dict["offset"] as? NSDictionary {
        shadow.shadowOffset = NSSize(width: canvas_numberFromValue(offset["w"]) ?? 0,
                                     height: canvas_numberFromValue(offset["h"]) ?? 0)
    }
    if let blurRadius = canvas_numberFromValue(dict["blurRadius"]) {
        shadow.shadowBlurRadius = blurRadius
    }
    if let color = canvas_colorFromValue(dict["color"]) {
        shadow.shadowColor = color
    }
    return shadow
}

func canvas_styledTextFromValue(_ value: Any?) -> NSAttributedString? {
    if let attributedString = value as? NSAttributedString { return attributedString }
    if let string = value as? String { return NSAttributedString(string: string) }
    if let number = value as? NSNumber { return NSAttributedString(string: number.stringValue) }
    guard let array = value as? NSArray, array.count > 0 else { return nil }

    let result = NSMutableAttributedString(string: String(describing: array[0]))
    for idx in 1..<array.count {
        guard let style = array[idx] as? NSDictionary,
              let attributes = canvas_textAttributesFromValue(style["attributes"] as? NSDictionary) else { continue }
        let start = max(0, Int((canvas_numberFromValue(style["starts"]) ?? 1) - 1))
        let end = min(result.length, Int(canvas_numberFromValue(style["ends"]) ?? CGFloat(result.length)))
        if end >= start {
            result.setAttributes(attributes, range: NSRange(location: start, length: end - start))
        }
    }
    return result
}

private func canvas_textAttributesFromLua(_ L: UnsafeMutablePointer<lua_State>!, at index: Int32) -> [NSAttributedString.Key: Any]? {
    let idx = lua_absindex(L, index)
    guard lua_type(L, idx) == LUA_TTABLE else { return nil }

    var attributes: [NSAttributedString.Key: Any] = [:]
    if lua_getfield(L, idx, "font") == LUA_TTABLE || lua_type(L, -1) == LUA_TSTRING {
        if let font = tableToNSFont(L, at: -1) { attributes[.font] = font }
    }
    lua_pop(L, 1)

    for (luaKey, attrKey) in canvasNumericTextAttributes {
        if let value = canvas_numberFromLua(L, at: idx, field: luaKey) {
            attributes[attrKey] = NSNumber(value: Double(value))
        }
    }

    for (luaKey, attrKey) in canvasColorTextAttributes {
        if lua_getfield(L, idx, luaKey) == LUA_TTABLE, let color = canvas_colorFromLua(L, at: -1) {
            attributes[attrKey] = color
        }
        lua_pop(L, 1)
    }

    if lua_getfield(L, idx, "shadow") == LUA_TTABLE, let shadow = canvas_shadowFromLua(L, at: -1) {
        attributes[.shadow] = shadow
    }
    lua_pop(L, 1)
    return attributes
}

private func canvas_textAttributesFromValue(_ value: NSDictionary?) -> [NSAttributedString.Key: Any]? {
    guard let value = value else { return nil }
    var attributes: [NSAttributedString.Key: Any] = [:]

    if let font = value["font"] as? NSFont {
        attributes[.font] = font
    }

    for (luaKey, attrKey) in canvasNumericTextAttributes {
        if let number = canvas_numberFromValue(value[luaKey]) {
            attributes[attrKey] = NSNumber(value: Double(number))
        }
    }

    for (luaKey, attrKey) in canvasColorTextAttributes {
        if let color = canvas_colorFromValue(value[luaKey]) {
            attributes[attrKey] = color
        }
    }

    if let shadow = canvas_shadowFromValue(value["shadow"]) {
        attributes[.shadow] = shadow
    }
    return attributes
}

private let canvasNumericTextAttributes: [(String, NSAttributedString.Key)] = [
    ("underlineStyle", .underlineStyle),
    ("superscript", .superscript),
    ("ligature", .ligature),
    ("strikethroughStyle", .strikethroughStyle),
    ("baselineOffset", .baselineOffset),
    ("kerning", .kern),
    ("strokeWidth", .strokeWidth),
    ("obliqueness", .obliqueness),
    ("expansion", .expansion),
]

private let canvasColorTextAttributes: [(String, NSAttributedString.Key)] = [
    ("color", .foregroundColor),
    ("backgroundColor", .backgroundColor),
    ("strokeColor", .strokeColor),
    ("underlineColor", .underlineColor),
    ("strikethroughColor", .strikethroughColor),
]

private func canvas_numberFromValue(_ value: Any?) -> CGFloat? {
    if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
    if let number = value as? Double { return CGFloat(number) }
    if let number = value as? Float { return CGFloat(number) }
    if let number = value as? Int { return CGFloat(number) }
    if let number = value as? CGFloat { return number }
    return nil
}

private func canvas_colorFromHexString(_ hexString: String, alpha: CGFloat) -> NSColor? {
    var normalized = hexString
    if normalized.hasPrefix("#") { normalized.removeFirst() }
    if normalized.hasPrefix("0x") { normalized.removeFirst(2) }

    if normalized.count == 3 {
        normalized = normalized.map { "\($0)\($0)" }.joined()
    }

    guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return nil }
    let red = CGFloat((value & 0xFF0000) >> 16) / 255.0
    let green = CGFloat((value & 0x00FF00) >> 8) / 255.0
    let blue = CGFloat(value & 0x0000FF) / 255.0
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

private func canvas_luaByteToObjCharMap(_ string: NSString) -> NSDictionary {
    let result = NSMutableDictionary()
    var luaPos: UInt = 1
    var idx: UInt = 0
    while idx < UInt(string.length) {
        let utf16Char = string.substring(with: NSRange(location: Int(idx), length: 1))
        var charString = utf16Char
        let utf16Unichar = (utf16Char as NSString).character(at: 0)
        if CFStringIsSurrogateHighCharacter(utf16Unichar) {
            charString = string.substring(with: NSRange(location: Int(idx), length: 2))
        }
        let byteCount = UInt(charString.data(using: .utf8)?.count ?? 1)
        var surrogateHandled = (charString as NSString).length == 1
        for byteIndex in 0..<byteCount {
            if !surrogateHandled && byteIndex >= (byteCount / 2) {
                idx += 1
                surrogateHandled = true
            }
            result[NSNumber(value: luaPos)] = NSNumber(value: idx + 1)
            luaPos += 1
        }
        idx += 1
    }
    return result
}

private func canvas_luaRangeToObjCRange(_ map: NSDictionary, len: lua_Integer, luaI: lua_Integer, luaJ: lua_Integer) -> (i: lua_Integer, j: lua_Integer, empty: Bool) {
    var i = luaI
    var j = luaJ
    if i < 0 { i = len + 1 + i }
    if j < 0 { j = len + 1 + j }
    if i < 1 { i = 1 }
    if j > len { j = len }
    if i > j { return (i, j, true) }
    i = lua_Integer((map.object(forKey: NSNumber(value: i)) as? NSNumber)?.intValue ?? Int(i))
    j = lua_Integer((map.object(forKey: NSNumber(value: j)) as? NSNumber)?.intValue ?? Int(j))
    return (i, j, false)
}

func canvas_pushValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?) {
    canvas_pushValueRecursive(L, value, depth: 0)
}

private func canvas_pushValueRecursive(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?, depth: Int) {
    guard depth < canvasMaxConversionDepth else {
        lua_pushnil(L)
        return
    }

    guard let value = value, !(value is NSNull) else {
        lua_pushnil(L)
        return
    }

    switch value {
    case let canvas as HSCanvasView:
        _ = canvas_pushHSCanvasView(L, obj: canvas)
    case let color as NSColor:
        canvas_pushColor(L, color)
    case let image as NSImage:
        canvas_pushObjectUserdata(L, image, tag: "hs.image")
    case let string as NSAttributedString:
        canvas_pushObjectUserdata(L, string, tag: "hs.styledtext")
    case let transform as NSAffineTransform:
        canvas_pushTransform(L, transform)
    case let shadow as NSShadow:
        canvas_pushShadow(L, shadow, depth: depth + 1)
    case let font as NSFont:
        canvas_pushFont(L, font)
    case let paragraphStyle as NSParagraphStyle:
        canvas_pushParagraphStyle(L, paragraphStyle)
    case let set as NSSet:
        canvas_pushArray(L, set.allObjects, depth: depth + 1)
    case let array as NSArray:
        canvas_pushArray(L, (0..<array.count).map { array[$0] }, depth: depth + 1)
    case let array as [Any]:
        canvas_pushArray(L, array, depth: depth + 1)
    case let dictionary as NSDictionary:
        canvas_pushDictionary(L, dictionary, depth: depth + 1)
    case let dictionary as [String: Any]:
        canvas_pushDictionary(L, dictionary as NSDictionary, depth: depth + 1)
    default:
        lua_pushany(L, value)
    }
}

private func canvas_pushArray(_ L: UnsafeMutablePointer<lua_State>!, _ array: [Any], depth: Int) {
    lua_createtable(L, Int32(array.count), 0)
    for (index, item) in array.enumerated() {
        canvas_pushValueRecursive(L, item, depth: depth + 1)
        lua_rawseti(L, -2, lua_Integer(index + 1))
    }
}

private func canvas_pushDictionary(_ L: UnsafeMutablePointer<lua_State>!, _ dictionary: NSDictionary, depth: Int) {
    lua_createtable(L, 0, Int32(dictionary.count))
    for (key, value) in dictionary {
        lua_pushany(L, key)
        canvas_pushValueRecursive(L, value, depth: depth + 1)
        lua_settable(L, -3)
    }
}

private func canvas_pushColor(_ L: UnsafeMutablePointer<lua_State>!, _ color: NSColor) {
    lua_newtable(L)
    if let rgb = color.usingColorSpace(.genericRGB) {
        lua_pushnumber(L, lua_Number(rgb.redComponent)); lua_setfield(L, -2, "red")
        lua_pushnumber(L, lua_Number(rgb.greenComponent)); lua_setfield(L, -2, "green")
        lua_pushnumber(L, lua_Number(rgb.blueComponent)); lua_setfield(L, -2, "blue")
        lua_pushnumber(L, lua_Number(rgb.alphaComponent)); lua_setfield(L, -2, "alpha")
    } else if color.colorSpaceName == .named {
        lua_pushstring(L, color.catalogNameComponent); lua_setfield(L, -2, "list")
        lua_pushstring(L, color.colorNameComponent); lua_setfield(L, -2, "name")
    } else if color.colorSpaceName == .pattern {
        canvas_pushValue(L, color.patternImage); lua_setfield(L, -2, "image")
    }
    lua_pushstring(L, "NSColor"); lua_setfield(L, -2, "__luaSkinType")
}

private func canvas_pushTransform(_ L: UnsafeMutablePointer<lua_State>!, _ transform: NSAffineTransform) {
    let structure = transform.transformStruct
    lua_newtable(L)
    lua_pushnumber(L, lua_Number(structure.m11)); lua_setfield(L, -2, "m11")
    lua_pushnumber(L, lua_Number(structure.m12)); lua_setfield(L, -2, "m12")
    lua_pushnumber(L, lua_Number(structure.m21)); lua_setfield(L, -2, "m21")
    lua_pushnumber(L, lua_Number(structure.m22)); lua_setfield(L, -2, "m22")
    lua_pushnumber(L, lua_Number(structure.tX)); lua_setfield(L, -2, "tX")
    lua_pushnumber(L, lua_Number(structure.tY)); lua_setfield(L, -2, "tY")
    lua_pushstring(L, "NSAffineTransform"); lua_setfield(L, -2, "__luaSkinType")
    canvas_setMetatableIfAvailable(L, tag: "hs.canvas.matrix")
}

private func canvas_pushShadow(_ L: UnsafeMutablePointer<lua_State>!, _ shadow: NSShadow, depth: Int) {
    lua_newtable(L)
    lua_pushNSSize(L, shadow.shadowOffset); lua_setfield(L, -2, "offset")
    lua_pushnumber(L, lua_Number(shadow.shadowBlurRadius)); lua_setfield(L, -2, "blurRadius")
    canvas_pushValueRecursive(L, shadow.shadowColor, depth: depth + 1); lua_setfield(L, -2, "color")
    lua_pushstring(L, "NSShadow"); lua_setfield(L, -2, "__luaSkinType")
}

private func canvas_pushFont(_ L: UnsafeMutablePointer<lua_State>!, _ font: NSFont) {
    lua_newtable(L)
    lua_pushstring(L, font.fontName); lua_setfield(L, -2, "name")
    lua_pushnumber(L, lua_Number(font.pointSize)); lua_setfield(L, -2, "size")
    lua_pushstring(L, "NSFont"); lua_setfield(L, -2, "__luaSkinType")
}

private func canvas_pushParagraphStyle(_ L: UnsafeMutablePointer<lua_State>!, _ paragraphStyle: NSParagraphStyle) {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(paragraphStyle.alignment.rawValue)); lua_setfield(L, -2, "alignment")
    lua_pushinteger(L, lua_Integer(paragraphStyle.lineBreakMode.rawValue)); lua_setfield(L, -2, "lineBreak")
    lua_pushstring(L, "NSParagraphStyle"); lua_setfield(L, -2, "__luaSkinType")
}

private func canvas_pushObjectUserdata(_ L: UnsafeMutablePointer<lua_State>!, _ object: AnyObject, tag: String) {
    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    ptr.storeBytes(of: Unmanaged.passRetained(object).toOpaque(), as: UnsafeRawPointer.self)
    canvas_setMetatableCreatingFallback(L, tag: tag)
}

private func canvas_setMetatableIfAvailable(_ L: UnsafeMutablePointer<lua_State>!, tag: String) {
    if luaL_getmetatable(L, tag) == LUA_TTABLE {
        lua_setmetatable(L, -2)
    } else {
        lua_pop(L, 1)
    }
}

private func canvas_setMetatableCreatingFallback(_ L: UnsafeMutablePointer<lua_State>!, tag: String) {
    if luaL_getmetatable(L, tag) == LUA_TTABLE {
        lua_setmetatable(L, -2)
        return
    }
    lua_pop(L, 1)
    if luaL_newmetatable(L, tag) != 0 {
        lua_pushcfunction(L, canvasObjectUserdataGC)
        lua_setfield(L, -2, "__gc")
    }
    lua_setmetatable(L, -2)
}

// MARK: - Module Functions

/// hs.canvas.useCustomAccessibilitySubrole([state]) -> boolean
/// Function
/// Get or set whether or not canvas objects use a custom accessibility subrole for the containing system window.
func canvas_useCustomAccessibilitySubrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_gettop(L) == 1 {
        canvas_defaultCustomSubRole = lua_toboolean(L, 1) != 0
    }
    lua_pushboolean(L, canvas_defaultCustomSubRole ? 1 : 0)
    return 1
}

/// hs.canvas.new(rect) -> canvasObject
/// Constructor
/// Create a new canvas object at the specified coordinates
func canvas_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TTABLE)

    let canvasWindow = HSCanvasWindow(contentRect: lua_tableToRect(L, at: 1),
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: true)
    let canvasView = HSCanvasView(frame: canvasWindow.contentView!.bounds)
    canvasView.wrapperWindow = canvasWindow
    canvasWindow.contentView = canvasView

    _ = canvas_pushHSCanvasView(L, obj: canvasView)
    return 1
}

/// hs.canvas.elementSpec() -> table
/// Function
/// Returns the list of attributes and their specifications that are recognized for canvas elements by this module.
func dumpLanguageDictionary(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    canvas_pushValue(L, canvas_languageDictionary)
    return 1
}

/// hs.canvas.defaultTextStyle() -> `hs.styledtext` attributes table
/// Function
/// Returns a table containing the default font, size, color, and paragraphStyle used by `hs.canvas` for text drawing objects.
func default_textAttributes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    if let fontName = (canvas_languageDictionary["textFont"] as? NSDictionary)?["default"] as? String {
        let size = ((canvas_languageDictionary["textSize"] as? NSDictionary)?["default"] as? NSNumber)?.doubleValue ?? 27.0
        canvas_pushValue(L, NSFont(name: fontName, size: CGFloat(size)))
        lua_setfield(L, -2, "font")
        canvas_pushValue(L, (canvas_languageDictionary["textColor"] as? NSDictionary)?["default"])
        lua_setfield(L, -2, "color")
        canvas_pushValue(L, NSParagraphStyle.default)
        lua_setfield(L, -2, "paragraphStyle")
    } else {
        return luaL_error(L, "\(canvas_USERDATA_TAG):unable to get default font name from element language dictionary")
    }
    return 1
}


// MARK: - Module Methods

/// hs.canvas:draggingCallback(fn) -> canvasObject
func canvas_draggingCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, canvasView.draggingCallbackRef)


    canvasView.draggingCallbackRef = LUA_NOREF
    canvasView.unregisterDraggedTypes()
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        canvasView.draggingCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        canvasView.registerForDraggedTypes([.fileURL])
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:_accessibilitySubrole([subrole]) -> canvasObject | current value
func canvas_accessibilitySubrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        canvas_pushValue(L, canvasWindow?.subroleOverride as NSString?)
    } else {
        canvasWindow?.subroleOverride = lua_isstring(L, 2) != 0 ? (lua_tovalue(L, at: 2) as? String) : nil
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.canvas:show([fadeInTime]) -> canvasObject
func canvas_show(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    if lua_gettop(L) == 1 {
        if canvas_parentIsWindow(canvasView) {
            (canvasView.window as? HSCanvasWindow)?.makeKeyAndOrderFront(nil)
        } else {
            canvasView.isHidden = false
        }
    } else {
        if canvas_parentIsWindow(canvasView) {
            (canvasView.window as? HSCanvasWindow)?.fadeIn(lua_tonumber(L, 2))
        } else {
            canvasView.fadeIn(lua_tonumber(L, 2))
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:hide([fadeOutTime]) -> canvasObject
func canvas_hide(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        if canvas_parentIsWindow(canvasView) {
            canvasWindow?.orderOut(nil)
        } else {
            canvasView.isHidden = true
        }
    } else {
        if canvas_parentIsWindow(canvasView) {
            canvasWindow?.fadeOut(lua_tonumber(L, 2), andDelete: false, withState: L)
        } else {
            canvasView.fadeOut(lua_tonumber(L, 2), andDelete: false, withState: L)
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:mouseCallback(mouseCallbackFn) -> canvasObject
func canvas_mouseCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.wrapperWindow

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, canvasView.mouseCallbackRef)


    canvasView.mouseCallbackRef = LUA_NOREF
    canvasView.previousTrackedIndex = UInt(NSNotFound)
    canvasWindow?.ignoresMouseEvents = true

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        canvasView.mouseCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        canvasWindow?.ignoresMouseEvents = false
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:clickActivating([flag]) -> canvasObject | currentValue
func canvas_clickActivating(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.wrapperWindow!

    if lua_type(L, 2) != LUA_TNONE {
        if lua_toboolean(L, 2) != 0 {
            canvasWindow.styleMask.remove(.nonactivatingPanel)
        } else {
            canvasWindow.styleMask.insert(.nonactivatingPanel)
        }
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, !canvasWindow.styleMask.contains(.nonactivatingPanel) ? 1 : 0)
    }

    return 1
}

/// hs.canvas:canvasMouseEvents([down], [up], [enterExit], [move]) -> canvasObject | current values
func canvas_canvasMouseEvents(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    if lua_gettop(L) == 1 {
        lua_pushboolean(L, canvasView.canvasMouseDown ? 1 : 0)
        lua_pushboolean(L, canvasView.canvasMouseUp ? 1 : 0)
        lua_pushboolean(L, canvasView.canvasMouseEnterExit ? 1 : 0)
        lua_pushboolean(L, canvasView.canvasMouseMove ? 1 : 0)
        return 4
    } else {
        if lua_type(L, 2) == LUA_TBOOLEAN { canvasView.canvasMouseDown      = lua_toboolean(L, 2) != 0 }
        if lua_type(L, 3) == LUA_TBOOLEAN { canvasView.canvasMouseUp        = lua_toboolean(L, 3) != 0 }
        if lua_type(L, 4) == LUA_TBOOLEAN { canvasView.canvasMouseEnterExit = lua_toboolean(L, 4) != 0 }
        if lua_type(L, 5) == LUA_TBOOLEAN { canvasView.canvasMouseMove      = lua_toboolean(L, 5) != 0 }

        lua_pushvalue(L, 1)
        return 1
    }
}

/// hs.canvas:topLeft([point]) -> canvasObject | currentValue
func canvas_topLeft(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow
        let oldFrame = canvas_RectWithFlippedYCoordinate(canvasWindow.frame)

        if lua_gettop(L) == 1 {
            lua_pushNSPoint(L, oldFrame.origin)
        } else {
            let newCoord = lua_tableToPoint(L, at: 2)
            let newFrame = canvas_RectWithFlippedYCoordinate(NSMakeRect(newCoord.x, newCoord.y, oldFrame.size.width, oldFrame.size.height))
            canvasWindow.setFrame(newFrame, display: true, animate: false)
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }
    return 1
}

/// hs.canvas:imageFromCanvas() -> hs.image object
func canvas_canvasAsImage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let image = canvasView.imageWithSubviews()
    canvas_pushValue(L, image)
    return 1
}

/// hs.canvas:size([size]) -> canvasObject | currentValue
func canvas_size(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow
        let oldFrame = canvasWindow.frame

        if lua_gettop(L) == 1 {
            lua_pushNSSize(L, oldFrame.size)
        } else {
            let newSize = lua_tableToSize(L, at: 2)
            let newFrame = NSMakeRect(oldFrame.origin.x,
                                      oldFrame.origin.y + oldFrame.size.height - newSize.height,
                                      newSize.width,
                                      newSize.height)
            let xFactor = newFrame.size.width / oldFrame.size.width
            let yFactor = newFrame.size.height / oldFrame.size.height

            for i in 0..<canvasView.elementList.count {
                let absPos = canvasView.getElementValue(for: "absolutePosition", atIndex: UInt(i)) as? NSNumber
                let absSiz = canvasView.getElementValue(for: "absoluteSize", atIndex: UInt(i)) as? NSNumber
                if let absPos = absPos, let absSiz = absSiz {
                    let absolutePosition = absPos.boolValue
                    let absoluteSize = absSiz.boolValue
                    guard let attributeDefinition = canvasView.elementList[i] as? NSMutableDictionary else { continue }

                    if !absolutePosition {
                        for (key, val) in attributeDefinition {
                            guard let keyName = key as? String, let keyValue = val as? NSMutableDictionary else { continue }
                            if keyName == "center" || keyName == "frame" {
                                if let x = keyValue["x"] as? NSNumber { keyValue["x"] = NSNumber(value: x.doubleValue * xFactor) }
                                if let y = keyValue["y"] as? NSNumber { keyValue["y"] = NSNumber(value: y.doubleValue * yFactor) }
                            } else if keyName == "coordinates", let coords = keyValue as? NSMutableArray {
                                for subItem in coords {
                                    guard let sub = subItem as? NSMutableDictionary else { continue }
                                    for field in ["x", "y", "c1x", "c1y", "c2x", "c2y"] {
                                        if let num = sub[field] as? NSNumber {
                                            let factor = field.hasSuffix("x") ? xFactor : yFactor
                                            sub[field] = NSNumber(value: num.doubleValue * Double(factor))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !absoluteSize {
                        for (key, val) in attributeDefinition {
                            guard let keyName = key as? String else { continue }
                            if keyName == "frame", let keyValue = val as? NSMutableDictionary {
                                if let h = keyValue["h"] as? NSNumber { keyValue["h"] = NSNumber(value: h.doubleValue * Double(yFactor)) }
                                if let w = keyValue["w"] as? NSNumber { keyValue["w"] = NSNumber(value: w.doubleValue * Double(xFactor)) }
                            } else if keyName == "radius", let num = val as? NSNumber {
                                attributeDefinition[keyName] = NSNumber(value: num.doubleValue * Double(xFactor))
                            }
                        }
                    }
                } else {
                    os_log(.error, "%{public}s", "\(canvas_USERDATA_TAG):unable to get absolute positioning info for index position \(i + 1)")
                }
            }
            canvasWindow.setFrame(newFrame, display: true, animate: false)
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }
    return 1
}

/// hs.canvas:alpha([alpha]) -> canvasObject | currentValue
func canvas_alpha(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        if canvas_parentIsWindow(canvasView) {
            lua_pushnumber(L, lua_Number(canvasWindow!.alphaValue))
        } else {
            lua_pushnumber(L, lua_Number(canvasView.alphaValue))
        }
    } else {
        let newLevel = CGFloat(luaL_checknumber(L, 2))
        let clamped = max(0.0, min(1.0, newLevel))
        if canvas_parentIsWindow(canvasView) {
            canvasWindow!.alphaValue = clamped
        } else {
            canvasView.alphaValue = clamped
        }
        lua_pushvalue(L, 1)
    }

    return 1
}

/// hs.canvas:orderAbove([canvas2]) -> canvasObject
func canvas_orderAbove(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return canvas_orderHelper(L, mode: .above)
}

/// hs.canvas:orderBelow([canvas2]) -> canvasObject
func canvas_orderBelow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return canvas_orderHelper(L, mode: .below)
}

/// hs.canvas:level([level]) -> canvasObject | currentValue
func canvas_level(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window!

        if lua_gettop(L) == 1 {
            lua_pushinteger(L, lua_Integer(canvasWindow.level.rawValue))
        } else {
            var targetLevel: lua_Integer
            if lua_type(L, 2) == LUA_TNUMBER {
                targetLevel = lua_tointeger(L, 2)
            } else {
                canvas_cg_windowLevels(L)
                if lua_getfield(L, -1, (lua_tovalue(L, at: 2) as! NSString).utf8String) == LUA_TNUMBER {
                    targetLevel = lua_tointeger(L, -1)
                    lua_pop(L, 2)
                } else {
                    lua_pop(L, 2)
                    return luaL_error(L, "unrecognized window level: \(lua_tovalue(L, at: 2) ?? "unknown")")
                }
            }

            let minLevel = lua_Integer(CGWindowLevelForKey(.minimumWindow))
            let maxLevel = lua_Integer(CGWindowLevelForKey(.maximumWindow))
            targetLevel = max(minLevel, min(maxLevel, targetLevel))
            canvasWindow.level = NSWindow.Level(rawValue: Int(targetLevel))
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }

    return 1
}

/// hs.canvas:wantsLayer([flag]) -> canvasObject | currentValue
func canvas_wantsLayer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    if lua_type(L, 2) != LUA_TNONE {
        canvasView.wantsLayer = lua_toboolean(L, 2) != 0
        canvasView.needsDisplay = true
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, canvasView.wantsLayer ? 1 : 0)
    }

    return 1
}

func canvas_behavior(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window!

        if lua_gettop(L) == 1 {
            lua_pushinteger(L, lua_Integer(canvasWindow.collectionBehavior.rawValue))
        } else {
            let newLevel = lua_tointeger(L, 2)
            canvasWindow.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }

    return 1
}

/// hs.canvas:delete([fadeOutTime]) -> none
func canvas_delete(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    canvas_hide(L)
    lua_pop(L, 1) // remove userdata pushed by hide

    lua_pushnil(L)
    return 1
}

/// hs.canvas:isShowing() -> boolean
func canvas_isShowing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow
    if canvas_parentIsWindow(canvasView) {
        lua_pushboolean(L, (canvasWindow?.isVisible ?? false) ? 1 : 0)
    } else {
        lua_pushboolean(L, (!canvasView.isHidden && (canvasWindow?.isVisible ?? false)) ? 1 : 0)
    }
    return 1
}

/// hs.canvas:isOccluded() -> boolean
func canvas_isOccluded(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow
    if canvas_parentIsWindow(canvasView) {
        let visible = canvasWindow?.occlusionState.contains(.visible) ?? false
        lua_pushboolean(L, visible ? 0 : 1)
    } else {
        let visible = canvasWindow?.occlusionState.contains(.visible) ?? false
        lua_pushboolean(L, (canvasView.isHidden || !visible) ? 1 : 0)
    }
    return 1
}

/// hs.canvas:transformation([matrix]) -> canvasObject | current value
func canvas_canvasTransformation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    if lua_gettop(L) == 1 {
        canvas_pushValue(L, canvasView.canvasTransform)
    } else {
        var transform = NSAffineTransform()
        if lua_type(L, 2) == LUA_TTABLE {
            transform = canvas_transformFromLua(L, at: 2) ?? NSAffineTransform()
        }
        canvasView.canvasTransform = transform
        canvasView.needsDisplay = true
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.canvas:elementCount() -> integer
func canvas_elementCount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    lua_pushinteger(L, lua_Integer(canvasView.elementList.count))
    return 1
}

/// hs.canvas:minimumTextSize([index], text) -> table
func canvas_getTextElementSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    var textIndex: Int32 = 2
    var elementIndex = UInt(NSNotFound)

    if lua_gettop(L) == 3 {
        elementIndex = UInt(lua_tointeger(L, 2)) - 1
        textIndex = 3
    }

    let theSize: NSSize
    if lua_type(L, textIndex) == LUA_TSTRING {
        let theText = lua_tovalue(L, at: textIndex) as? String ?? ""
        let myFont: String
        let mySize: NSNumber
        let alignment: String
        let wrap: String
        let color: NSColor

        if elementIndex == UInt(NSNotFound) {
            myFont = canvasView.getDefaultValue(for: "textFont", onlyIfSet: false) as? String ?? ""
            mySize = canvasView.getDefaultValue(for: "textSize", onlyIfSet: false) as? NSNumber ?? NSNumber(value: 27.0)
            alignment = canvasView.getDefaultValue(for: "textAlignment", onlyIfSet: false) as? String ?? "natural"
            wrap = canvasView.getDefaultValue(for: "textLineBreak", onlyIfSet: false) as? String ?? "wordWrap"
            color = canvasView.getDefaultValue(for: "textColor", onlyIfSet: false) as? NSColor ?? .white
        } else {
            myFont = canvasView.getElementValue(for: "textFont", atIndex: elementIndex) as? String ?? ""
            mySize = canvasView.getElementValue(for: "textSize", atIndex: elementIndex) as? NSNumber ?? NSNumber(value: 27.0)
            alignment = canvasView.getElementValue(for: "textAlignment", atIndex: elementIndex) as? String ?? "natural"
            wrap = canvasView.getElementValue(for: "textLineBreak", atIndex: elementIndex) as? String ?? "wordWrap"
            color = canvasView.getElementValue(for: "textColor", atIndex: elementIndex) as? NSColor ?? .white
        }

        let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraphStyle.alignment = NSTextAlignment(rawValue: TEXTALIGNMENT_TYPES[alignment]?.intValue ?? 0) ?? .natural
        paragraphStyle.lineBreakMode = NSLineBreakMode(rawValue: UInt(TEXTWRAP_TYPES[wrap]?.intValue ?? 0)) ?? .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont(name: myFont, size: CGFloat(mySize.doubleValue)) ?? NSFont.systemFont(ofSize: CGFloat(mySize.doubleValue)),
            .paragraphStyle: paragraphStyle,
        ]
        theSize = (theText as NSString).size(withAttributes: attributes)
    } else {
        let attrStr = canvas_styledTextFromLua(L, at: textIndex) ?? NSAttributedString()
        theSize = attrStr.size()
    }
    lua_pushNSSize(L, theSize)
    return 1
}

/// hs.canvas:canvasDefaultFor(keyName, [newValue]) -> canvasObject | currentValue
func canvas_canvasDefaultFor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let keyName = lua_tovalue(L, at: 2) as! String

    guard canvas_languageDictionary[keyName] != nil else {
        return luaL_argerror(L, 2, "attribute name \(keyName) unrecognized")
    }

    guard let attributeDefault = canvasView.getDefaultValue(for: keyName, onlyIfSet: false) else {
        return luaL_argerror(L, 2, "attribute \(keyName) has no default value")
    }

    if lua_gettop(L) == 2 {
        canvas_pushValue(L, attributeDefault)
    } else {
        let keyValue = canvas_valueFromLua(L, at: 3, forKey: keyName)
        let result = AttributeValidity(rawValue: canvasView.setDefault(for: keyName, to: keyValue, withState: L)) ?? .invalid
        switch result {
        case .valid, .nulling:
            break
        case .invalid:
            if let langEntry = canvas_languageDictionary[keyName] as? NSDictionary,
               (langEntry["nullable"] as? NSNumber)?.boolValue == true {
                return luaL_argerror(L, 3, "invalid argument type for \(keyName) specified")
            } else {
                return luaL_argerror(L, 2, "attribute default for \(keyName) cannot be changed")
            }
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.canvas:insertElement(elementTable, [index]) -> canvasObject
func canvas_insertElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let elementCount = canvasView.elementList.count
    let tablePosition = (lua_gettop(L) == 3) ? Int(lua_tointeger(L, 3)) - 1 : elementCount

    guard tablePosition >= 0 && tablePosition <= elementCount else {
        return luaL_argerror(L, 3, "index \(tablePosition + 1) out of bounds")
    }

    guard let element = canvas_valueFromLua(L, at: 2) as? NSDictionary else {
        return luaL_argerror(L, 2, "invalid element definition; must contain key-value pairs")
    }

    guard let elementType = element["type"] as? String, ALL_TYPES.contains(elementType) else {
        return luaL_argerror(L, 2, "invalid type \(element["type"] ?? "nil"); must be one of \(ALL_TYPES.joined(separator: ", "))")
    }

    canvasView.elementList.insert(NSMutableDictionary(), at: tablePosition)
    element.enumerateKeysAndObjects { (keyName, keyValue, _) in
        if let key = keyName as? String, key != "type" {
            _ = canvasView.setElementValue(for: key, atIndex: UInt(tablePosition), to: keyValue, withState: L)
        }
    }
    _ = canvasView.setElementValue(for: "type", atIndex: UInt(tablePosition), to: elementType, withState: L)

    canvasView.needsDisplay = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:removeElement([index]) -> canvasObject
func canvas_removeElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let elementCount = canvasView.elementList.count
    let tablePosition = (lua_gettop(L) == 2) ? Int(lua_tointeger(L, 2)) - 1 : elementCount - 1

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    let realIndex = tablePosition
    if let elemDict = canvasView.elementList[realIndex] as? NSDictionary,
       let canvasSubview = elemDict["canvas"] as? NSView {
        canvasSubview.removeFromSuperview()
    }
    canvasView.elementList.removeObject(at: realIndex)

    canvasView.needsDisplay = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:elementAttribute(index, key, [value]) -> canvasObject | current value
func canvas_elementAttributeAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    var keyName = lua_tovalue(L, at: 3) as! String

    let elementCount = canvasView.elementList.count
    let tablePosition = Int(lua_tointeger(L, 2)) - 1

    var resolvePercentages = false

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    if canvas_languageDictionary[keyName] == nil {
        if lua_gettop(L) == 3 {
            // check if keyname ends with _raw
            if keyName.hasSuffix("_raw") {
                let trimmedName = String(keyName.dropLast(4))
                if canvas_languageDictionary[trimmedName] != nil {
                    keyName = trimmedName
                    resolvePercentages = true
                }
            }
            if !resolvePercentages {
                lua_pushnil(L)
                return 1
            }
        } else {
            return luaL_argerror(L, 3, "attribute name \(keyName) unrecognized")
        }
    }

    if lua_gettop(L) == 3 {
        let value = canvasView.getElementValue(for: keyName, atIndex: UInt(tablePosition), resolvePercentages: resolvePercentages, onlyIfSet: false)
        canvas_pushValue(L, value)
    } else {
        let keyValue = canvas_valueFromLua(L, at: 4, forKey: keyName)
        let result = AttributeValidity(rawValue: canvasView.setElementValue(for: keyName, atIndex: UInt(tablePosition), to: keyValue, withState: L)) ?? .invalid
        switch result {
        case .valid, .nulling:
            lua_pushvalue(L, 1)
        case .invalid:
            return luaL_argerror(L, 4, "invalid argument type for \(keyName) specified")
        }
    }
    return 1
}

/// hs.canvas:elementKeys(index, [optional]) -> table
func canvas_elementKeysAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    let elementCount = canvasView.elementList.count
    let tablePosition = Int(lua_tointeger(L, 2)) - 1

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    let list = NSMutableSet(array: (canvasView.elementList[tablePosition] as! NSDictionary).allKeys)
    if lua_gettop(L) == 3 && lua_toboolean(L, 3) != 0 {
        let ourType = (canvasView.elementList[tablePosition] as! NSDictionary)["type"] as? String
        (canvas_languageDictionary as! [String: NSDictionary]).forEach { (keyName, keyValue) in
            if let optionalFor = keyValue["optionalFor"] as? [String], let t = ourType, optionalFor.contains(t) {
                list.add(keyName)
            }
        }
    }
    canvas_pushValue(L, list)
    return 1
}

/// hs.canvas:canvasDefaults([module]) -> table
func canvas_canvasDefaults(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        lua_newtable(L)
        for key in (canvas_languageDictionary as! [String: Any]).keys {
            if let keyValue = canvasView.getDefaultValue(for: key, onlyIfSet: false) {
                canvas_pushValue(L, keyValue)
                lua_setfield(L, -2, key)
            }
        }
    } else {
        canvas_pushValue(L, canvasView.canvasDefaults)
    }
    return 1
}

/// hs.canvas:canvasDefaultKeys([module]) -> table
func canvas_canvasDefaultKeys(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    let list = NSMutableSet(array: canvasView.canvasDefaults.allKeys)
    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        (canvas_languageDictionary as! [String: NSDictionary]).forEach { (keyName, keyValue) in
            if keyValue["default"] != nil {
                list.add(keyName)
            }
        }
    }
    canvas_pushValue(L, list)
    return 1
}

/// hs.canvas:canvasElements() -> table
func canvas_canvasElements(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    canvas_pushValue(L, canvasView.elementList)
    return 1
}

/// hs.canvas:elementBounds(index) -> rectTable
func canvas_elementBoundsAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    let elementCount = canvasView.elementList.count
    let tablePosition = Int(lua_tointeger(L, 2)) - 1

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    let idx = UInt(tablePosition)
    var boundingBox = NSZeroRect
    if let itemPath = canvasView.pathForElement(atIndex: idx) {
        if itemPath.isEmpty {
            boundingBox = NSZeroRect
        } else {
            boundingBox = itemPath.bounds
        }
    } else {
        let itemType = (canvasView.elementList[tablePosition] as! NSDictionary)["type"] as? String
        if itemType == "image" || itemType == "text" || itemType == "canvas" {
            let frame = canvasView.getElementValue(for: "frame", atIndex: idx, resolvePercentages: true) as? NSDictionary ?? [:]
            boundingBox = NSMakeRect(CGFloat((frame["x"] as? NSNumber)?.doubleValue ?? 0),
                                     CGFloat((frame["y"] as? NSNumber)?.doubleValue ?? 0),
                                     CGFloat((frame["w"] as? NSNumber)?.doubleValue ?? 0),
                                     CGFloat((frame["h"] as? NSNumber)?.doubleValue ?? 0))
        } else {
            lua_pushnil(L)
            return 1
        }
    }
    lua_pushNSRect(L, boundingBox)
    return 1
}

/// hs.canvas:assignElement(elementTable, [index]) -> canvasObject
func canvas_assignElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView

    let elementCount = canvasView.elementList.count
    let tablePosition = (lua_gettop(L) == 3) ? Int(lua_tointeger(L, 3)) - 1 : elementCount

    guard tablePosition >= 0 && tablePosition <= elementCount else {
        return luaL_argerror(L, 3, "index \(tablePosition + 1) out of bounds")
    }

    if lua_isnil(L, 2) {
        if tablePosition == elementCount - 1 {
            canvasView.elementList.removeLastObject()
        } else {
            return luaL_argerror(L, 3, "nil only valid for final element")
        }
    } else {
        guard let element = canvas_valueFromLua(L, at: 2) as? NSDictionary else {
            return luaL_argerror(L, 2, "invalid element definition; must contain key-value pairs")
        }
        guard let elementType = element["type"] as? String, ALL_TYPES.contains(elementType) else {
            return luaL_argerror(L, 2, "invalid type \(element["type"] ?? "nil"); must be one of \(ALL_TYPES.joined(separator: ", "))")
        }

        let realIndex = tablePosition
        if realIndex < elementCount {
            if let canvasSubview = (canvasView.elementList[realIndex] as? NSDictionary)?["canvas"] as? NSView {
                canvasSubview.removeFromSuperview()
            }
            canvasView.elementList[realIndex] = NSMutableDictionary()
        } else {
            canvasView.elementList.add(NSMutableDictionary())
        }

        element.enumerateKeysAndObjects { (keyName, keyValue, _) in
            if let key = keyName as? String, key != "type" {
                _ = canvasView.setElementValue(for: key, atIndex: UInt(realIndex), to: keyValue, withState: L)
            }
        }
        _ = canvasView.setElementValue(for: "type", atIndex: UInt(realIndex), to: elementType, withState: L)
    }

    canvasView.needsDisplay = true
    lua_pushvalue(L, 1)
    return 1
}
