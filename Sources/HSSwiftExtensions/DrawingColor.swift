import Cocoa
import Carbon
import LuaSkin

private var refTable: LSRefTable = 0
private var colorCollectionsTable: Int32 = LUA_NOREF

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
private func getColorLists(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    lua_newtable(L)
    for colorList in NSColorList.availableColorLists {
        skin.pushNSObject(colorList)
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
private func colorAsRGB(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBREAK)
    let theColor = skin.luaObject(at: 1, toClass: "NSColor") as! NSColor

    let safeColor = theColor.usingColorSpace(NSColorSpace.genericRGB)

    if let safeColor = safeColor {
        lua_newtable(L)
        lua_pushnumber(L, lua_Number(safeColor.redComponent))   ; lua_setfield(L, -2, "red")
        lua_pushnumber(L, lua_Number(safeColor.greenComponent)) ; lua_setfield(L, -2, "green")
        lua_pushnumber(L, lua_Number(safeColor.blueComponent))  ; lua_setfield(L, -2, "blue")
        lua_pushnumber(L, lua_Number(safeColor.alphaComponent)) ; lua_setfield(L, -2, "alpha")
    } else {
        lua_pushstring(L, "unable to convert colorspace \(theColor.colorSpace.description) to NSCalibratedRGBColorSpace")
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
private func colorAsHSB(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBREAK)
    let theColor = skin.luaObject(at: 1, toClass: "NSColor") as! NSColor

    let safeColor = theColor.usingColorSpace(NSColorSpace.genericRGB)

    if let safeColor = safeColor {
        lua_newtable(L)
        lua_pushnumber(L, lua_Number(safeColor.hueComponent))        ; lua_setfield(L, -2, "hue")
        lua_pushnumber(L, lua_Number(safeColor.saturationComponent)) ; lua_setfield(L, -2, "saturation")
        lua_pushnumber(L, lua_Number(safeColor.brightnessComponent)) ; lua_setfield(L, -2, "brightness")
        lua_pushnumber(L, lua_Number(safeColor.alphaComponent))      ; lua_setfield(L, -2, "alpha")
    } else {
        lua_pushstring(L, "unable to convert colorspace from \(theColor.colorSpace.description) to NSCalibratedRGBColorSpace")
    }

    return 1
}

// [skin pushNSObject:NSColor]
// C-API
// Pushes the provided NSColor onto the Lua Stack as an array meeting the color table description provided in `hs.drawing.color`
private func NSColor_tolua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theColor = obj as! NSColor
    let safeColor = theColor.usingColorSpace(NSColorSpace.genericRGB)

    if let safeColor = safeColor {
        lua_newtable(L)
        lua_pushnumber(L, lua_Number(safeColor.redComponent))   ; lua_setfield(L, -2, "red")
        lua_pushnumber(L, lua_Number(safeColor.greenComponent)) ; lua_setfield(L, -2, "green")
        lua_pushnumber(L, lua_Number(safeColor.blueComponent))  ; lua_setfield(L, -2, "blue")
        lua_pushnumber(L, lua_Number(safeColor.alphaComponent)) ; lua_setfield(L, -2, "alpha")
        lua_pushstring(L, "NSColor") ; lua_setfield(L, -2, "__luaSkinType")
    } else if theColor.colorSpaceName == .named {
        lua_newtable(L)
        skin.pushNSObject(theColor.catalogNameComponent)
        lua_setfield(L, -2, "list")
        skin.pushNSObject(theColor.colorNameComponent)
        lua_setfield(L, -2, "name")
        lua_pushstring(L, "NSColor") ; lua_setfield(L, -2, "__luaSkinType")
    } else if theColor.colorSpaceName == .pattern {
        lua_newtable(L)
        skin.pushNSObject(theColor.patternImage)
        lua_setfield(L, -2, "image")
        lua_pushstring(L, "NSColor") ; lua_setfield(L, -2, "__luaSkinType")
    } else {
        lua_pushstring(L, "unable to convert colorspace from \(theColor.colorSpace.description) to NSCalibratedRGBColorSpace")
    }

    return 1
}

// [skin pushNSObject:NSColorList]
// C-API
// Pushes the provided NSColorList onto the Lua Stack as a table of color tables meeting the color table description provided in `hs.drawing.color`
private func NSColorList_tolua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let colorList = obj as! NSColorList

    lua_newtable(L)
    for key in colorList.allKeys {
        skin.pushNSObject(colorList.color(withKey: key))
        lua_setfield(L, -2, key.utf8CString.withUnsafeBufferPointer { $0.baseAddress! })
    }

    return 1
}

private let COLOR_LOOP_LEVEL = 10

private func table_toNSColorHelper(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ level: Int) -> NSColor {
    let skin = LuaSkin.skin(with: L)
    var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
    var hue: CGFloat = 0.0, saturation: CGFloat = 0.0, brightness: CGFloat = 0.0
    var white: CGFloat = 0.0

    var rgbColor = true
    var image: NSImage? = nil

    // arbitrary cutoff to prevent infinite loop in table lookups
    if level < COLOR_LOOP_LEVEL {
        var colorList: NSString? = nil
        var colorName: NSString? = nil

        switch lua_type(L, idx) {
        case LUA_TTABLE:
            if lua_getfield(L, idx, "list") == LUA_TSTRING {
                colorList = skin.toNSObject(atIndex: -1) as? NSString
            }
            lua_pop(L, 1)
            if lua_getfield(L, idx, "name") == LUA_TSTRING {
                colorName = skin.toNSObject(atIndex: -1) as? NSString
            }
            lua_pop(L, 1)

            if lua_getfield(L, idx, "hex") == LUA_TSTRING {
                var hexString = skin.toNSObject(atIndex: -1) as! NSString
                if hexString.hasPrefix("#")  { hexString = hexString.substring(from: 1) as NSString }
                if hexString.hasPrefix("0x") { hexString = hexString.substring(from: 2) as NSString }
                var isBadHex = true
                var rHex: UInt64 = 0, gHex: UInt64 = 0, bHex: UInt64 = 0

                let scanner = Scanner(string: hexString as String)
                if scanner.scanHexInt64(nil) {
                    if hexString.length == 3 {
                        Scanner(string: hexString.substring(with: NSRange(location: 0, length: 1))).scanHexInt64(&rHex)
                        Scanner(string: hexString.substring(with: NSRange(location: 1, length: 1))).scanHexInt64(&gHex)
                        Scanner(string: hexString.substring(with: NSRange(location: 2, length: 1))).scanHexInt64(&bHex)
                        rHex = rHex * 0x11
                        gHex = gHex * 0x11
                        bHex = bHex * 0x11
                        isBadHex = false
                    } else if hexString.length == 6 {
                        Scanner(string: hexString.substring(with: NSRange(location: 0, length: 2))).scanHexInt64(&rHex)
                        Scanner(string: hexString.substring(with: NSRange(location: 2, length: 2))).scanHexInt64(&gHex)
                        Scanner(string: hexString.substring(with: NSRange(location: 4, length: 2))).scanHexInt64(&bHex)
                        isBadHex = false
                    }
                }
                if isBadHex {
                    skin.logWarn("invalid hexadecimal string #\(hexString) specified for color, ignoring")
                } else {
                    red   = CGFloat(rHex) / 255.0
                    green = CGFloat(gHex) / 255.0
                    blue  = CGFloat(bHex) / 255.0
                }
            }
            lua_pop(L, 1)

            if lua_getfield(L, idx, "red") == LUA_TNUMBER {
                red = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)
            if lua_getfield(L, idx, "green") == LUA_TNUMBER {
                green = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)
            if lua_getfield(L, idx, "blue") == LUA_TNUMBER {
                blue = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)

            if lua_getfield(L, idx, "hue") == LUA_TNUMBER {
                hue = CGFloat(lua_tonumber(L, -1))
                rgbColor = false
            }
            lua_pop(L, 1)
            if lua_getfield(L, idx, "saturation") == LUA_TNUMBER {
                saturation = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)
            if lua_getfield(L, idx, "brightness") == LUA_TNUMBER {
                brightness = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)

            if lua_getfield(L, idx, "white") == LUA_TNUMBER {
                white = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)

            if lua_getfield(L, idx, "alpha") == LUA_TNUMBER {
                alpha = CGFloat(lua_tonumber(L, -1))
            }
            lua_pop(L, 1)

            if lua_getfield(L, idx, "image") == LUA_TUSERDATA && luaL_testudata(L, -1, "hs.image") != nil {
                image = skin.toNSObject(atIndex: -1) as? NSImage
            }
            lua_pop(L, 1)

        default:
            skin.logError("returning BLACK, unexpected type passed as a color: \(String(cString: lua_typename(L, lua_type(L, idx))))")
        }

        if let colorList = colorList, let colorName = colorName, image == nil {
            if let holding = NSColorList(named: colorList as String)?.color(withKey: colorName as String) {
                return holding
            }
            if colorCollectionsTable != LUA_NOREF {
                skin.pushLuaRef(refTable, ref: colorCollectionsTable)
                if lua_getfield(L, -1, (colorList as String).utf8CString.withUnsafeBufferPointer({ $0.baseAddress! })) == LUA_TTABLE {
                    if lua_getfield(L, -1, (colorName as String).utf8CString.withUnsafeBufferPointer({ $0.baseAddress! })) == LUA_TTABLE {
                        let holding = table_toNSColorHelper(L, lua_absindex(L, -1), level + 1)
                        lua_pop(L, 3) // the colorName entry, colorList entry, and lookup table
                        return holding
                    }
                    lua_pop(L, 1) // the colorName entry
                }
                lua_pop(L, 2) // the colorList entry and the lookup table
            }
        }
    } else {
        skin.logError("returning BLACK, color list/name dereference depth > \(COLOR_LOOP_LEVEL): loop?")
    }

    if let image = image {
        return NSColor(patternImage: image)
    } else if rgbColor {
        if white != 0.0 {
            return NSColor(calibratedWhite: white, alpha: alpha)
        } else {
            return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
        }
    } else {
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
}

// [skin luaObjectAtIndex:idx toClass:"NSColor"]
// C-API
// Converts the table at the specified index on the Lua Stack into an NSColor and returns the NSColor.
private func table_toNSColor(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    return table_toNSColorHelper(L, idx, 0)
}

// register the lookup table for Lua defined color tables
private func registerColorCollectionsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBREAK)

    lua_pushvalue(L, 1)
    colorCollectionsTable = skin.luaRef(refTable)
    return 0
}

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("lists"), func: getColorLists),
    luaL_Reg(name: strdup("asRGB"), func: colorAsRGB),
    luaL_Reg(name: strdup("asHSB"), func: colorAsHSB),
    luaL_Reg(name: strdup("_registerColorCollectionsTable"), func: registerColorCollectionsTable),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libdrawing_color")
public func luaopen_hs_libdrawing_color(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary("hs.drawing", functions: &moduleLib, metaFunctions: nil)
    colorCollectionsTable = LUA_NOREF

    skin.registerPushNSHelper(NSColor_tolua, forClass: "NSColor")
    skin.registerLuaObjectHelper(table_toNSColor, forClass: "NSColor", withTableMapping: "NSColor")

    skin.registerPushNSHelper(NSColorList_tolua, forClass: "NSColorList")

    return 1
}
