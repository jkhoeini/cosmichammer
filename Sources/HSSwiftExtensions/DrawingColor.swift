import Cocoa
import CLua
import Lua
import Carbon
import os.log

private var colorCollectionsTable: LuaValue?

/// hs.drawing.color.lists() -> table
/// Function
/// Returns a table containing the system color lists and hs.drawing.color collections with their defined colors.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table whose keys are made from the currently defined system color lists and hs.drawing.color collections.  Each color list key refers to a table whose keys make up the colors provided by the specific color list.
///
/// Notes:
///  * Where possible, each color node is provided as its RGB color representation.  Where this is not possible, the color node contains the keys `list` and `name` which identify the indicated color.  This means that you can use the following wherever a color parameter is expected: `hs.drawing.color.lists()["list-name"]["color-name"]`
///  * This function provides a tostring metatable method which allows listing the defined color lists in the Cosmic Hammer console with: `hs.drawing.color.lists()`
///  * See also `hs.drawing.color.colorsFor`
private func getColorLists(_ L: LuaState) throws -> CInt {

    lua_newtable(L)
    for colorList in NSColorList.availableColorLists {
        NSColorList_tolua(L, colorList)
        lua_setfield(L, -2, colorList.name!.utf8CString.withUnsafeBufferPointer { $0.baseAddress! })
    }
    return 1
}

/// hs.drawing.color.asRGB(color) -> table | string
/// Function
/// Returns a table containing the RGB representation of the specified color.
///
/// Parameters:
///  * color - a table specifying a color as described in the module definition (see `hs.drawing.color` in the online help or Dash documentation)
///
/// Returns:
///  * a table containing the red, blue, green, and alpha keys representing the specified color as RGB or a string describing the color's colorspace if conversion is not possible.
///
/// Notes:
///  * See also `hs.drawing.color.asHSB`
private func colorAsRGB(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TTABLE)
    guard let theColor = table_toNSColor(L, 1) as? NSColor else {
        throw LuaCallError("bad argument #1 (expected color table)")
    }

    let safeColor = theColor.usingColorSpace(NSColorSpace.genericRGB)

    if let safeColor = safeColor {
        lua_newtable(L)
        L.push(lua_Number(safeColor.redComponent))   ; lua_setfield(L, -2, "red")
        L.push(lua_Number(safeColor.greenComponent)) ; lua_setfield(L, -2, "green")
        L.push(lua_Number(safeColor.blueComponent))  ; lua_setfield(L, -2, "blue")
        L.push(lua_Number(safeColor.alphaComponent)) ; lua_setfield(L, -2, "alpha")
    } else {
        L.push("unable to convert colorspace \(theColor.colorSpace.description) to NSCalibratedRGBColorSpace")
    }

    return 1
}

/// hs.drawing.color.asHSB(color) -> table | string
/// Function
/// Returns a table containing the HSB representation of the specified color.
///
/// Parameters:
///  * color - a table specifying a color as described in the module definition (see `hs.drawing.color` in the online help or Dash documentation)
///
/// Returns:
///  * a table containing the hue, saturation, brightness, and alpha keys representing the specified color as HSB or a string describing the color's colorspace if conversion is not possible.
///
/// Notes:
///  * See also `hs.drawing.color.asRGB`
private func colorAsHSB(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TTABLE)
    guard let theColor = table_toNSColor(L, 1) as? NSColor else {
        throw LuaCallError("bad argument #1 (expected color table)")
    }

    let safeColor = theColor.usingColorSpace(NSColorSpace.genericRGB)

    if let safeColor = safeColor {
        lua_newtable(L)
        L.push(lua_Number(safeColor.hueComponent))        ; lua_setfield(L, -2, "hue")
        L.push(lua_Number(safeColor.saturationComponent)) ; lua_setfield(L, -2, "saturation")
        L.push(lua_Number(safeColor.brightnessComponent)) ; lua_setfield(L, -2, "brightness")
        L.push(lua_Number(safeColor.alphaComponent))      ; lua_setfield(L, -2, "alpha")
    } else {
        L.push("unable to convert colorspace from \(theColor.colorSpace.description) to NSCalibratedRGBColorSpace")
    }

    return 1
}

// [skin pushNSObject:NSColor]
// C-API
// Pushes the provided NSColor onto the Lua Stack as an array meeting the color table description provided in `hs.drawing.color`
@discardableResult
func NSColor_tolua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theColor = obj as! NSColor
    let safeColor = theColor.usingColorSpace(NSColorSpace.genericRGB)

    if let safeColor = safeColor {
        lua_newtable(L)
        L.push(lua_Number(safeColor.redComponent))   ; lua_setfield(L, -2, "red")
        L.push(lua_Number(safeColor.greenComponent)) ; lua_setfield(L, -2, "green")
        L.push(lua_Number(safeColor.blueComponent))  ; lua_setfield(L, -2, "blue")
        L.push(lua_Number(safeColor.alphaComponent)) ; lua_setfield(L, -2, "alpha")
        L.push("NSColor") ; lua_setfield(L, -2, "__luaSkinType")
    } else if theColor.colorSpaceName == .named {
        lua_newtable(L)
        lua_pushany(L, theColor.catalogNameComponent)
        lua_setfield(L, -2, "list")
        lua_pushany(L, theColor.colorNameComponent)
        lua_setfield(L, -2, "name")
        L.push("NSColor") ; lua_setfield(L, -2, "__luaSkinType")
    } else if theColor.colorSpaceName == .pattern {
        lua_newtable(L)
        if NSImage_tolua(L, theColor.patternImage) == 0 {
            lua_pushnil(L)
        }
        lua_setfield(L, -2, "image")
        L.push("NSColor") ; lua_setfield(L, -2, "__luaSkinType")
    } else {
        L.push("unable to convert colorspace from \(theColor.colorSpace.description) to NSCalibratedRGBColorSpace")
    }

    return 1
}

// [skin pushNSObject:NSColorList]
// C-API
// Pushes the provided NSColorList onto the Lua Stack as a table of color tables meeting the color table description provided in `hs.drawing.color`
@discardableResult
private func NSColorList_tolua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let colorList = obj as! NSColorList

    lua_newtable(L)
    for key in colorList.allKeys {
        if let color = colorList.color(withKey: key) {
            NSColor_tolua(L, color)
        } else {
            lua_pushnil(L)
        }
        lua_setfield(L, -2, key.utf8CString.withUnsafeBufferPointer { $0.baseAddress! })
    }

    return 1
}

private let COLOR_LOOP_LEVEL = 10

private struct ParsedColorComponents {
    var red: CGFloat = 0.0
    var green: CGFloat = 0.0
    var blue: CGFloat = 0.0
    var alpha: CGFloat = 1.0
    var hue: CGFloat = 0.0
    var saturation: CGFloat = 0.0
    var brightness: CGFloat = 0.0
    var white: CGFloat = 0.0
    var rgbColor: Bool = true
    var image: NSImage? = nil
    var colorList: NSString? = nil
    var colorName: NSString? = nil
}

private func table_toNSColorHelper(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ level: Int) -> NSColor {
    guard level < COLOR_LOOP_LEVEL else {
        os_log(.error, "%{public}s", "returning BLACK, color list/name dereference depth > \(COLOR_LOOP_LEVEL): loop?")
        return NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)
    }

    var c = ParsedColorComponents()

    if lua_type(L, idx) == LUA_TTABLE {
        parseColorListAndName(L, idx, &c)
        parseHexColor(L, idx, &c)
        parseRGBComponents(L, idx, &c)
        parseHSBComponents(L, idx, &c)
        parseWhiteAlphaImage(L, idx, &c)
    } else {
        os_log(.error, "%{public}s", "returning BLACK, unexpected type passed as a color: \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }

    if let resolved = resolveNamedColor(L, c, level: level) {
        return resolved
    }

    return buildNSColor(from: c)
}

private func parseColorListAndName(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ c: inout ParsedColorComponents) {
    if lua_getfield(L, idx, "list") == LUA_TSTRING {
        c.colorList = lua_tovalue(L, at: -1) as? NSString
    }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "name") == LUA_TSTRING {
        c.colorName = lua_tovalue(L, at: -1) as? NSString
    }
    lua_pop(L, 1)
}

private func parseHexColor(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ c: inout ParsedColorComponents) {
    guard lua_getfield(L, idx, "hex") == LUA_TSTRING else {
        lua_pop(L, 1)
        return
    }
    var hexString = lua_tovalue(L, at: -1) as! NSString
    lua_pop(L, 1)

    if hexString.hasPrefix("#")  { hexString = hexString.substring(from: 1) as NSString }
    if hexString.hasPrefix("0x") { hexString = hexString.substring(from: 2) as NSString }
    var rHex: UInt64 = 0, gHex: UInt64 = 0, bHex: UInt64 = 0

    let scanner = Scanner(string: hexString as String)
    guard scanner.scanHexInt64(nil) else {
        os_log(.info, "%{public}s", "invalid hexadecimal string #\(hexString) specified for color, ignoring")
        return
    }

    if hexString.length == 3 {
        Scanner(string: hexString.substring(with: NSRange(location: 0, length: 1))).scanHexInt64(&rHex)
        Scanner(string: hexString.substring(with: NSRange(location: 1, length: 1))).scanHexInt64(&gHex)
        Scanner(string: hexString.substring(with: NSRange(location: 2, length: 1))).scanHexInt64(&bHex)
        rHex = rHex * 0x11; gHex = gHex * 0x11; bHex = bHex * 0x11
    } else if hexString.length == 6 {
        Scanner(string: hexString.substring(with: NSRange(location: 0, length: 2))).scanHexInt64(&rHex)
        Scanner(string: hexString.substring(with: NSRange(location: 2, length: 2))).scanHexInt64(&gHex)
        Scanner(string: hexString.substring(with: NSRange(location: 4, length: 2))).scanHexInt64(&bHex)
    } else {
        os_log(.info, "%{public}s", "invalid hexadecimal string #\(hexString) specified for color, ignoring")
        return
    }
    c.red   = CGFloat(rHex) / 255.0
    c.green = CGFloat(gHex) / 255.0
    c.blue  = CGFloat(bHex) / 255.0
}

private func parseRGBComponents(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ c: inout ParsedColorComponents) {
    if lua_getfield(L, idx, "red") == LUA_TNUMBER { c.red = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "green") == LUA_TNUMBER { c.green = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "blue") == LUA_TNUMBER { c.blue = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
}

private func parseHSBComponents(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ c: inout ParsedColorComponents) {
    if lua_getfield(L, idx, "hue") == LUA_TNUMBER {
        c.hue = CGFloat(lua_tonumber(L, -1))
        c.rgbColor = false
    }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "saturation") == LUA_TNUMBER { c.saturation = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "brightness") == LUA_TNUMBER { c.brightness = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
}

private func parseWhiteAlphaImage(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ c: inout ParsedColorComponents) {
    if lua_getfield(L, idx, "white") == LUA_TNUMBER { c.white = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "alpha") == LUA_TNUMBER { c.alpha = CGFloat(lua_tonumber(L, -1)) }
    lua_pop(L, 1)
    if lua_getfield(L, idx, "image") == LUA_TUSERDATA && luaL_testudata(L, -1, "hs.image") != nil {
        c.image = toNSImage(L, at: -1)
    }
    lua_pop(L, 1)
}

private func resolveNamedColor(_ L: UnsafeMutablePointer<lua_State>!, _ c: ParsedColorComponents, level: Int) -> NSColor? {
    guard let colorList = c.colorList, let colorName = c.colorName, c.image == nil else { return nil }

    if let holding = NSColorList(named: colorList as String)?.color(withKey: colorName as String) {
        return holding
    }
    guard let collectionsRef = colorCollectionsTable else { return nil }

    collectionsRef.push(onto: L)
    if lua_getfield(L, -1, (colorList as String).utf8CString.withUnsafeBufferPointer({ $0.baseAddress! })) == LUA_TTABLE {
        if lua_getfield(L, -1, (colorName as String).utf8CString.withUnsafeBufferPointer({ $0.baseAddress! })) == LUA_TTABLE {
            let holding = table_toNSColorHelper(L, lua_absindex(L, -1), level + 1)
            lua_pop(L, 3) // the colorName entry, colorList entry, and lookup table
            return holding
        }
        lua_pop(L, 1) // the colorName entry
    }
    lua_pop(L, 2) // the colorList entry and the lookup table
    return nil
}

private func buildNSColor(from c: ParsedColorComponents) -> NSColor {
    if let image = c.image {
        return NSColor(patternImage: image)
    } else if c.rgbColor {
        if c.white != 0.0 {
            return NSColor(calibratedWhite: c.white, alpha: c.alpha)
        } else {
            return NSColor(calibratedRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    } else {
        return NSColor(calibratedHue: c.hue, saturation: c.saturation, brightness: c.brightness, alpha: c.alpha)
    }
}

// [skin luaObjectAtIndex:idx toClass:"NSColor"]
// C-API
// Converts the table at the specified index on the Lua Stack into an NSColor and returns the NSColor.
func table_toNSColor(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    return table_toNSColorHelper(L, idx, 0)
}

// register the lookup table for Lua defined color tables
private func registerColorCollectionsTable(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TTABLE)

    colorCollectionsTable = L.ref(index: 1)
    return 0
}

@_cdecl("luaopen_hs_libdrawing_color")
public func luaopen_hs_libdrawing_color(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create module table
        lua_createtable(L, 0, 4)
        L.push(getColorLists)
        lua_setfield(L, -2, "lists")
        L.push(colorAsRGB)
        lua_setfield(L, -2, "asRGB")
        L.push(colorAsHSB)
        lua_setfield(L, -2, "asHSB")
        L.push(registerColorCollectionsTable)
        lua_setfield(L, -2, "_registerColorCollectionsTable")

        colorCollectionsTable = nil
    }
}
