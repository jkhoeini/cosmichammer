import Cocoa
import LuaSkin
import os.log

private let USERDATA_TAG = "hs.styledtext"
private var refTable: Int32 = LUA_NOREF

// MARK: - Helpers

private func get_objectFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSAttributedString {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<NSAttributedString>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_objectFromUserdata_transfer(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSAttributedString {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<NSAttributedString>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
}

// Lua treats strings (and therefore indexes within strings) as a sequence of bytes.  Objective-C's
// NSString and NSAttributedString treat them as a sequence of characters.  This works fine until
// Unicode characters are involved.
//
// This function creates a dictionary mapping of this where the keys are the byte positions in the
// Lua string and the values are the corresponding character positions in the NSString.
private func luaByteToObjCharMap(_ theString: NSString) -> NSDictionary {
    let luaByteToObjChar = NSMutableDictionary()

    var luaPos: UInt = 1
    var i: UInt = 0
    while i < UInt(theString.length) {
        let utf16Char = theString.substring(with: NSRange(location: Int(i), length: 1))
        var charStr = utf16Char
        let utf16Unichar = (utf16Char as NSString).character(at: 0)
        if CFStringIsSurrogateHighCharacter(utf16Unichar) {
            charStr = theString.substring(with: NSRange(location: Int(i), length: 2))
        }
        let utf8Data = charStr.data(using: .utf8)!
        let dataLength = UInt(utf8Data.count)
        var surrogateHandled = (charStr as NSString).length == 1 // false only required if length = 2

        for j in 0..<dataLength {
            // trick for high/low surrogate pairs
            if !surrogateHandled && j >= (dataLength / 2) {
                i += 1
                surrogateHandled = true
            }
            luaByteToObjChar.setObject(NSNumber(value: i + 1), forKey: NSNumber(value: luaPos) as NSCopying)
            luaPos += 1
        }
        i += 1
    }

    return luaByteToObjChar
}

// Helper to resolve lua byte range to ObjC character range
private func luaRangeToObjCRange(_ theMap: NSDictionary, len: lua_Integer, luaI: lua_Integer, luaJ: lua_Integer) -> (i: lua_Integer, j: lua_Integer, empty: Bool) {
    var i = luaI
    var j = luaJ
    if i < 0 { i = len + 1 + i }
    if j < 0 { j = len + 1 + j }
    if i < 1 { i = 1 }
    if j > len { j = len }
    if i > j { return (i, j, true) }
    i = lua_Integer((theMap.object(forKey: NSNumber(value: i)) as! NSNumber).intValue)
    j = lua_Integer((theMap.object(forKey: NSNumber(value: j)) as! NSNumber).intValue)
    return (i, j, false)
}

// Helper to look up document type from string
private func documentType(from requestType: String?) -> NSAttributedString.DocumentType? {
    guard let requestType = requestType else { return nil }
    switch requestType {
    case "text":       return .plain
    case "rtf":        return .rtf
    case "rtfd":       return .rtfd
    case "simpleText": return .macSimpleText
    case "html":       return .html
    case "word":       return .docFormat
    case "wordXML":    return .wordML
    case "openXML":    return .officeOpenXML
    case "webArchive": return .webArchive
    case "open":       return .openDocument
    default:           return nil
    }
}

// Helper for attribute name from short name
private func attributeNameForKey(_ key: String) -> NSAttributedString.Key? {
    switch key {
    case "font":               return .font
    case "paragraphStyle":     return .paragraphStyle
    case "underlineStyle":     return .underlineStyle
    case "superscript":        return .superscript
    case "ligature":           return .ligature
    case "strikethroughStyle": return .strikethroughStyle
    case "baselineOffset":     return .baselineOffset
    case "kerning":            return .kern
    case "strokeWidth":        return .strokeWidth
    case "obliqueness":        return .obliqueness
    case "expansion":          return .expansion
    case "color":              return .foregroundColor
    case "backgroundColor":    return .backgroundColor
    case "strokeColor":        return .strokeColor
    case "underlineColor":     return .underlineColor
    case "strikethroughColor": return .strikethroughColor
    case "shadow":             return .shadow
    case "link":               return .link
    case "tooltip":            return .toolTip
    default:                   return nil
    }
}

// Reverse: attribute key to short lua name
private func luaNameForAttributeKey(_ key: NSAttributedString.Key) -> String? {
    switch key {
    case .font:               return "font"
    case .underlineStyle:     return "underlineStyle"
    case .superscript:        return "superscript"
    case .ligature:           return "ligature"
    case .baselineOffset:     return "baselineOffset"
    case .kern:               return "kerning"
    case .strokeWidth:        return "strokeWidth"
    case .strikethroughStyle: return "strikethroughStyle"
    case .obliqueness:        return "obliqueness"
    case .expansion:          return "expansion"
    case .link:               return "link"
    case .toolTip:            return "tooltip"
    case .foregroundColor:    return "color"
    case .backgroundColor:    return "backgroundColor"
    case .strokeColor:        return "strokeColor"
    case .underlineColor:     return "underlineColor"
    case .strikethroughColor: return "strikethroughColor"
    case .shadow:             return "shadow"
    case .paragraphStyle:     return "paragraphStyle"
    default:                  return nil
    }
}

// MARK: - NSAttributedString Constructors

/// hs.styledtext.new(string, [attributes]) -> styledText object
/// Constructor
/// Create an `hs.styledtext` object from the string or table representation provided.  Attributes to apply to the resulting string may also be optionally provided.
///
/// Parameters:
///  * string     - a string, table, or `hs.styledtext` object to create a new `hs.styledtext` object from.
///  * attributes - an optional table containing attribute key-value pairs to apply to the entire `hs.styledtext` object to be returned.
///
/// Returns:
///  * an `hs.styledtext` object
///
/// Notes:
///  * See `hs.styledtext:asTable` for a description of the table representation of an `hs.styledtext` object
///  * See the module description documentation (`help.hs.styledtext`) for a description of the attributes table format which can be provided for the optional second argument.
///
///  * Passing an `hs.styledtext` object as the first parameter without specifying an `attributes` table is the equivalent of invoking `hs.styledtext:copy`.
private func string_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let newString = (lua_tovalue(L, at: 1) as! NSAttributedString).mutableCopy() as! NSMutableAttributedString
    if lua_gettop(L) == 2 {
        if let attributes = lua_tovalue(L, at: 2) as? [NSAttributedString.Key: Any] {
            let theRange = NSRange(location: 0, length: newString.length)
            newString.addAttributes(attributes, range: theRange)
        }
    }
    lua_pushany(L, newString)
    return 1
}

/// hs.styledtext.getStyledTextFromData(data, [type]) -> styledText object
/// Constructor
/// Converts the provided data into a styled text string.
///
/// Parameters:
///  * data          - the data, as a lua string, which contains the raw data to be converted to a styledText object
///  * type          - a string indicating the format of the contents in `data`.  Defaults to "html".
///
/// Returns:
///  * the styledText object
///
/// Notes:
///  * See also `hs.styledtext.getStyledTextFromFile`
private func getStyledTextFromData(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    var dataType: NSAttributedString.DocumentType = .html
    if lua_type(L, 2) != LUA_TNONE {
        if let requestType = lua_tovalue(L, at: 2) as? String,
           let resolved = documentType(from: requestType) {
            dataType = resolved
        } else {
            return luaL_argerror(L, 2, "unrecognized encoding type")
        }
    }

    let theInput: Any! = lua_tovalue(L, at: 1)
    let dataToPresent: Data
    if let str = theInput as? String {
        dataToPresent = str.data(using: .utf8)!
    } else {
        dataToPresent = theInput as! Data
    }

    do {
        let newString = try NSAttributedString(data: dataToPresent,
                                               options: [.documentType: dataType],
                                               documentAttributes: nil)
        lua_pushany(L, newString)
    } catch {
        return luaL_error(L, "setTextFromData: conversion error: \(error.localizedDescription)")
    }
    return 1
}

/// hs.styledtext.getStyledTextFromFile(file, [type]) -> styledText object
/// Constructor
/// Converts the data in the specified file into a styled text string.
///
/// Parameters:
///  * file          - the path to the file to use as the source for the data to convert into a styledText object
///  * type          - a string indicating the format of the contents in `data`.  Defaults to "html".
///
/// Returns:
///  * the styledText object
///
/// Notes:
///  * See also `hs.styledtext.getStyledTextFromData`
private func getStyledTextFromFile(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    var dataType: NSAttributedString.DocumentType = .html
    if lua_type(L, 2) != LUA_TNONE {
        if let requestType = lua_tovalue(L, at: 2) as? String,
           let resolved = documentType(from: requestType) {
            dataType = resolved
        } else {
            return luaL_argerror(L, 2, "unrecognized encoding type")
        }
    }

    let path = (lua_tovalue(L, at: 1) as! NSString).expandingTildeInPath
    do {
        let newString = try NSAttributedString(url: URL(fileURLWithPath: path),
                                               options: [.documentType: dataType],
                                               documentAttributes: nil)
        lua_pushany(L, newString)
    } catch {
        return luaL_error(L, "setTextFromFile: conversion error: \(error.localizedDescription)")
    }
    return 1
}

// MARK: - Font Information Functions

/// hs.styledtext.fontNames() -> table
/// Function
/// Returns the names of all installed fonts for the system.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the names of every font installed for the system.  The individual names are strings which can be used in the `hs.drawing:setTextFont(fontname)` method.
private func fontNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if let names = NSFontManager.shared.availableFonts as NSArray? {
        lua_pushany(L, names.sortedArray(using: #selector(NSString.localizedCaseInsensitiveCompare(_:))) as NSArray)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.styledtext.fontFamilies() -> table
/// Function
/// Returns the names of all font families installed for the system.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the names of every font family installed for the system.
private func fontFamilies(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if let families = NSFontManager.shared.availableFontFamilies as NSArray? {
        lua_pushany(L, families.sortedArray(using: #selector(NSString.localizedCaseInsensitiveCompare(_:))) as NSArray)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func fontsForFamily(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    if let fontFamily = lua_tovalue(L, at: 1) as? String {
        let details = NSFontManager.shared.availableMembers(ofFontFamily: fontFamily)
        lua_pushany(L, details as NSArray?)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.styledtext.convertFont(fontTable, trait) -> table
/// Function
/// Returns the font which most closely matches the given font and the trait change requested.
///
/// Parameters:
///  * font - a string or a table which specifies a font.  If a string is given, the default system font size is assumed.  If a table is provided, it should contain the following keys:
///    * name - the name of the font (defaults to the system font)
///    * size - the point size of the font (defaults to the default system font size)
///  * trait - a number corresponding to a trait listed in `hs.styledtext.fontTraits` you wish to add or remove (unboldFont and unitalicFont) from the given font, or a boolean indicating whether you want a heavier version (true) or a lighter version (false).
///
/// Returns:
///  * a table containing the name and size of the font which most closely matches the specified font and the trait change requested.  If no such font is available, then the original font is returned unchanged.
private func font_convertFont(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    guard let theFont = lua_tovalue(L, at: 1) as? NSFont else {
        return luaL_argerror(L, 1, "does not specify a font")
    }
    if lua_type(L, 2) == LUA_TNUMBER {
        lua_pushany(L, NSFontManager.shared.convert(theFont, toHaveTrait: NSFontTraitMask(rawValue: UInt(luaL_checkinteger(L, 2)))))
    } else {
        lua_pushany(L, NSFontManager.shared.convertWeight(lua_toboolean(L, 2) != 0, of: theFont))
    }
    return 1
}

/// hs.styledtext.fontNamesWithTraits(fontTraitMask) -> table
/// Function
/// Returns the names of all installed fonts for the system with the specified traits.
///
/// Parameters:
///  * traits - a number, specifying the fontTraitMask, or a table containing traits listed in `hs.styledtext.fontTraits` which are logically 'OR'ed together to create the fontTraitMask used.
///
/// Returns:
///  * a table containing the names of every font installed for the system which matches the fontTraitMask specified.  The individual names are strings which can be used in the `hs.drawing:setTextFont(fontname)` method.
///
/// Notes:
///  * specifying 0 or an empty table will match all fonts that are neither italic nor bold.  This would be the same list as you'd get with { hs.styledtext.fontTraits.unBold, hs.styledtext.fontTraits.unItalic } as the parameter.
private func fontNamesWithTraits(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    var theTraits: NSFontTraitMask = NSFontTraitMask(rawValue: 0)

    switch lua_type(L, 1) {
    case LUA_TNIL, LUA_TNONE:
        break
    case LUA_TNUMBER:
        theTraits = NSFontTraitMask(rawValue: UInt(luaL_checkinteger(L, 1)))
    case LUA_TTABLE:
        lua_pushnil(L)
        while lua_next(L, 1) != 0 {
            theTraits = NSFontTraitMask(rawValue: theTraits.rawValue | UInt(lua_tointeger(L, -1)))
            lua_pop(L, 1)
        }
    default:
        return luaL_argerror(L, 1, "expected integer or table")
    }

    if let names = NSFontManager.shared.availableFontNames(with: theTraits) {
        lua_newtable(L)
        for (indFont, name) in names.enumerated() {
            lua_pushstring(L, name)
            lua_rawseti(L, -2, lua_Integer(indFont + 1))
        }
    } else {
        lua_newtable(L)
    }
    return 1
}

/// hs.styledtext.fontTraits -> table
/// Constant
/// A table for containing Font Trait masks for use with `hs.styledtext.fontNamesWithTraits(...)`
private func fontTraits(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.boldFontMask.rawValue))
    lua_setfield(L, -2, "boldFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.compressedFontMask.rawValue))
    lua_setfield(L, -2, "compressedFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.condensedFontMask.rawValue))
    lua_setfield(L, -2, "condensedFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.expandedFontMask.rawValue))
    lua_setfield(L, -2, "expandedFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.fixedPitchFontMask.rawValue))
    lua_setfield(L, -2, "fixedPitchFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.italicFontMask.rawValue))
    lua_setfield(L, -2, "italicFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.narrowFontMask.rawValue))
    lua_setfield(L, -2, "narrowFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.posterFontMask.rawValue))
    lua_setfield(L, -2, "posterFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.smallCapsFontMask.rawValue))
    lua_setfield(L, -2, "smallCapsFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.nonStandardCharacterSetFontMask.rawValue))
    lua_setfield(L, -2, "nonStandardCharacterSetFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.unboldFontMask.rawValue))
    lua_setfield(L, -2, "unboldFont")
    lua_pushinteger(L, lua_Integer(NSFontTraitMask.unitalicFontMask.rawValue))
    lua_setfield(L, -2, "unitalicFont")
    return 1
}

/// hs.styledtext.validFont(font) -> boolean
/// Function
/// Checks to see if a font is valid.
///
/// Parameters:
///  * font - a string containing the name of the font you want to check.
///
/// Returns:
///  * `true` if valid, otherwise `false`.
private func validFont(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    let fontName = lua_tovalue(L, at: 1) as! String
    let theFont = NSFont(name: fontName, size: 1)
    lua_pushboolean(L, theFont != nil ? 1 : 0)
    return 1
}

/// hs.styledtext.fontInfo(font) -> table
/// Function
/// Get information about the font Specified in the attributes table.
///
/// Parameters:
///  * font - a string or a table which specifies a font.  If a string is given, the default system font size is assumed.  If a table is provided, it should contain the following keys:
///    * name - the name of the font (defaults to the system font)
///    * size - the point size of the font (defaults to the default system font size)
///
/// Returns:
///  * a table containing font information keys
private func fontInformation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    let theFont = skin.luaObject(at:-1, toClass: "NSFont") as! NSFont

    lua_newtable(L)
    lua_pushany(L, theFont.fontName as NSString)
    lua_setfield(L, -2, "fontName")
    lua_pushany(L, theFont.familyName as NSString?)
    lua_setfield(L, -2, "familyName")
    lua_pushany(L, theFont.displayName as NSString?)
    lua_setfield(L, -2, "displayName")
    lua_pushboolean(L, theFont.isFixedPitch ? 1 : 0)
    lua_setfield(L, -2, "fixedPitch")
    lua_pushnumber(L, lua_Number(theFont.ascender))
    lua_setfield(L, -2, "ascender")
    let boundingRect = theFont.boundingRectForFont
    lua_newtable(L)
    lua_pushnumber(L, lua_Number(boundingRect.origin.x))
    lua_setfield(L, -2, "x")
    lua_pushnumber(L, lua_Number(boundingRect.origin.y))
    lua_setfield(L, -2, "y")
    lua_pushnumber(L, lua_Number(boundingRect.size.height))
    lua_setfield(L, -2, "h")
    lua_pushnumber(L, lua_Number(boundingRect.size.width))
    lua_setfield(L, -2, "w")
    lua_setfield(L, -2, "boundingRect")
    lua_pushnumber(L, lua_Number(theFont.capHeight))
    lua_setfield(L, -2, "capHeight")
    lua_pushnumber(L, lua_Number(theFont.descender))
    lua_setfield(L, -2, "descender")
    lua_pushnumber(L, lua_Number(theFont.italicAngle))
    lua_setfield(L, -2, "italicAngle")
    lua_pushnumber(L, lua_Number(theFont.leading))
    lua_setfield(L, -2, "leading")
    let maxAdvance = theFont.maximumAdvancement
    lua_newtable(L)
    lua_pushnumber(L, lua_Number(maxAdvance.height))
    lua_setfield(L, -2, "h")
    lua_pushnumber(L, lua_Number(maxAdvance.width))
    lua_setfield(L, -2, "w")
    lua_setfield(L, -2, "maximumAdvancement")
    lua_pushinteger(L, lua_Integer(theFont.numberOfGlyphs))
    lua_setfield(L, -2, "numberOfGlyphs")
    lua_pushnumber(L, lua_Number(theFont.pointSize))
    lua_setfield(L, -2, "pointSize")
    lua_pushnumber(L, lua_Number(theFont.underlinePosition))
    lua_setfield(L, -2, "underlinePosition")
    lua_pushnumber(L, lua_Number(theFont.underlineThickness))
    lua_setfield(L, -2, "underlineThickness")
    lua_pushnumber(L, lua_Number(theFont.xHeight))
    lua_setfield(L, -2, "xHeight")
    return 1
}

/// hs.styledtext.fontPath(font) -> table
/// Function
/// Get the path of a font.
///
/// Parameters:
///  * font - a string containing the name of the font you want to check.
///
/// Returns:
///  * The path to the font or `nil` if the font name is not valid.
private func fontPath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    let skin = LuaSkin.skin(with: L)
    let fontName = lua_tovalue(L, at: 1) as! String
    if NSFont(name: fontName, size: 1) != nil {
        let theFont = skin.luaObject(at:-1, toClass: "NSFont") as! NSFont
        let fontRef = CTFontDescriptorCreateWithNameAndSize(theFont.fontName as CFString, theFont.pointSize)
        if let url = CTFontDescriptorCopyAttribute(fontRef, kCTFontURLAttribute) as? URL {
            lua_pushany(L, url.path as NSString)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.styledtext.lineStyles
/// Constant
/// A table of styles which apply to the line for underlining or strike-through.
private func defineLineStyles(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, 0) // NSUnderlineStyleNone
    lua_setfield(L, -2, "none")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.single.rawValue))
    lua_setfield(L, -2, "single")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.thick.rawValue))
    lua_setfield(L, -2, "thick")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.double.rawValue))
    lua_setfield(L, -2, "double")
    return 1
}

/// hs.styledtext.linePatterns
/// Constant
/// A table of patterns which apply to the line for underlining or strike-through.
private func defineLinePatterns(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, 0) // NSUnderlineStyle.patternSolid (rawValue 0)
    lua_setfield(L, -2, "solid")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.patternDot.rawValue))
    lua_setfield(L, -2, "dot")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.patternDash.rawValue))
    lua_setfield(L, -2, "dash")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.patternDashDot.rawValue))
    lua_setfield(L, -2, "dashDot")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.patternDashDotDot.rawValue))
    lua_setfield(L, -2, "dashDotDot")
    return 1
}

/// hs.styledtext.lineAppliesTo
/// Constant
/// A table of values indicating how the line for underlining or strike-through are applied to the text.
private func defineLineAppliesTo(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, 0)
    lua_setfield(L, -2, "line")
    lua_pushinteger(L, lua_Integer(NSUnderlineStyle.byWord.rawValue))
    lua_setfield(L, -2, "word")
    return 1
}

/// hs.styledtext.defaultFonts
/// Constant
/// A table containing the system default fonts and sizes.
private func defineDefaultFonts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushany(L, NSFont.boldSystemFont(ofSize: 0));     lua_setfield(L, -2, "boldSystem")
    lua_pushany(L, NSFont.controlContentFont(ofSize: 0)); lua_setfield(L, -2, "controlContent")
    lua_pushany(L, NSFont.labelFont(ofSize: 0));          lua_setfield(L, -2, "label")
    lua_pushany(L, NSFont.menuFont(ofSize: 0));           lua_setfield(L, -2, "menu")
    lua_pushany(L, NSFont.menuBarFont(ofSize: 0));        lua_setfield(L, -2, "menuBar")
    lua_pushany(L, NSFont.messageFont(ofSize: 0));        lua_setfield(L, -2, "message")
    lua_pushany(L, NSFont.paletteFont(ofSize: 0));        lua_setfield(L, -2, "palette")
    lua_pushany(L, NSFont.systemFont(ofSize: 0));         lua_setfield(L, -2, "system")
    lua_pushany(L, NSFont.titleBarFont(ofSize: 0));       lua_setfield(L, -2, "titleBar")
    lua_pushany(L, NSFont.toolTipsFont(ofSize: 0));       lua_setfield(L, -2, "toolTips")
    lua_pushany(L, NSFont.userFont(ofSize: 0));           lua_setfield(L, -2, "user")
    lua_pushany(L, NSFont.userFixedPitchFont(ofSize: 0)); lua_setfield(L, -2, "userFixedPitch")
    return 1
}

// MARK: - Lua byte to ObjC char mapping validation

private func luaToObjCMap(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString = NSString(utf8String: lua_tostring(L, 1)!)!
    let theMap = luaByteToObjCharMap(theString)
    lua_pushany(L, theMap)
    lua_newtable(L)
    for entry in (theMap.allValues as! [NSNumber]) {
        lua_pushany(L, entry)
        let keys = (theMap.allKeys(for: entry) as NSArray).sortedArray(using: #selector(NSNumber.compare(_:)))
        lua_pushany(L, keys as NSArray)
        lua_settable(L, -3)
    }
    return 2
}

// MARK: - Methods unique to hs.styledtext objects

/// hs.styledtext:copy(styledText) -> styledText object
/// Method
/// Create a copy of the `hs.styledtext` object.
///
/// Parameters:
///  * styledText - an `hs.styledtext` object
///
/// Returns:
///  * a copy of the styledText object
private func string_copy(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theString = get_objectFromUserdata(L, at: 1)
    lua_pushany(L, theString.copy() as! NSAttributedString)
    return 1
}

/// hs.styledtext:isIdentical(styledText) -> boolean
/// Method
/// Determine if the `styledText` object is identical to the one specified.
///
/// Parameters:
///  * styledText - an `hs.styledtext` object
///
/// Returns:
///  * a boolean value indicating whether or not the styled text objects are identical, both in text content and attributes specified.
///
/// Notes:
///  * comparing two `hs.styledtext` objects with the `==` operator only compares whether or not the string values are identical.  This method also compares their attributes.
private func string_identical(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString1 = get_objectFromUserdata(L, at: 1)
    let theString2 = get_objectFromUserdata(L, at: 2)
    lua_pushboolean(L, theString1.isEqual(to: theString2) ? 1 : 0)
    return 1
}

/// hs.styledtext:asTable([starts], [ends]) -> table
/// Method
/// Returns the table representation of the `hs.styledtext` object or its specified substring.
///
/// Parameters:
///  * starts - an optional index position within the text of the `hs.styledtext` object indicating the beginning of the substring to return the table for.  Defaults to 1, the beginning of the objects text.  If this number is negative, it is counted backwards from the end of the object's text (i.e. -1 would be the last character position).
///  * ends   - an optional index position within the text of the `hs.styledtext` object indicating the end of the substring to return the table for.  Defaults to the length of the objects text.  If this number is negative, it is counted backwards from the end of the object's text.
///
/// Returns:
///  * a table representing the `hs.styledtext` object.
private func string_totable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let theString = get_objectFromUserdata(L, at: 1)
    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, 2) ? 1 : luaL_checkinteger(L, 2)
    let luaJ = lua_isnoneornil(L, 3) ? len : luaL_checkinteger(L, 3)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)

    lua_newtable(L)
    lua_pushstring(L, "NSAttributedString"); lua_setfield(L, -2, "__luaSkinType")

    if resolved.empty {
        lua_pushstring(L, "")
        lua_rawseti(L, -2, 1)
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        lua_pushstring(L, theString.attributedSubstring(from: theRange).string)
        lua_rawseti(L, -2, 1)

        var limitRange = theRange
        var effectiveRange = NSRange(location: 0, length: 0)

        while limitRange.length > 0 {
            lua_newtable(L)
            let attributes = theString.attributes(at: limitRange.location,
                                                  longestEffectiveRange: &effectiveRange,
                                                  in: limitRange)

            // convert starts and ends into their lua equivalents
            let pS = ((theMap.allKeys(for: NSNumber(value: effectiveRange.location + 1)) as! [NSNumber])
                .sorted { $0.compare($1) == .orderedAscending }).last!.intValue
            let pE = ((theMap.allKeys(for: NSNumber(value: NSMaxRange(effectiveRange))) as! [NSNumber])
                .sorted { $0.compare($1) == .orderedAscending }).last!.intValue

            lua_pushinteger(L, lua_Integer(pS))
            lua_setfield(L, -2, "starts")
            lua_pushinteger(L, lua_Integer(pE))
            lua_setfield(L, -2, "ends")

            var containsUnsupportedFields = false
            lua_newtable(L)
            for (key, value) in attributes {
                lua_pushany(L, value as AnyObject)
                if let luaName = luaNameForAttributeKey(key) {
                    lua_setfield(L, -2, luaName)
                } else {
                    containsUnsupportedFields = true
                    lua_setfield(L, -2, key.rawValue)
                }
            }
            lua_setfield(L, -2, "attributes")
            if containsUnsupportedFields {
                lua_pushboolean(L, 1)
                lua_setfield(L, -2, "unsupportedFields")
            }
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            limitRange = NSRange(location: NSMaxRange(effectiveRange),
                                 length: NSMaxRange(limitRange) - NSMaxRange(effectiveRange))
        }
    }
    return 1
}

/// hs.styledtext:getString([starts], [ends]) -> string
/// Method
/// Returns the text of the `hs.styledtext` object as a Lua String
///
/// Parameters:
///  * starts - an optional index position within the text of the `hs.styledtext` object indicating the beginning of the substring to return the string for.  Defaults to 1, the beginning of the objects text.  If this number is negative, it is counted backwards from the end of the object's text (i.e. -1 would be the last character position).
///  * ends   - an optional index position within the text of the `hs.styledtext` object indicating the end of the substring to return the string for.  Defaults to the length of the objects text.  If this number is negative, it is counted backwards from the end of the object's text.
///
/// Returns:
///  * a string containing the text of the `hs.styledtext` object specified
///
/// Notes:
///  * `starts` and `ends` follow the conventions of `i` and `j` for Lua's `string.sub` function.
private func string_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let theString = get_objectFromUserdata(L, at: 1)
    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, 2) ? 1 : luaL_checkinteger(L, 2)
    let luaJ = lua_isnoneornil(L, 3) ? len : luaL_checkinteger(L, 3)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)
    if resolved.empty {
        lua_pushstring(L, "")
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        lua_pushstring(L, theString.attributedSubstring(from: theRange).string)
    }
    return 1
}

/// hs.styledtext:setStyle(attributes, [starts], [ends], [clear]) -> styledText object
/// Method
/// Return a copy of the `hs.styledtext` object containing the changes to its attributes specified in the `attributes` table.
///
/// Parameters:
///  * attributes - a table of attribute key-value pairs to apply to the object between the positions of `starts` and `ends`
///  * starts     - an optional index position within the text of the `hs.styledtext` object indicating the beginning of the substring to set attributes for.  Defaults to 1, the beginning of the objects text.
///  * ends       - an optional index position within the text of the `hs.styledtext` object indicating the end of the substring to set attributes for.  Defaults to the length of the objects text.
///  * clear      - an optional boolean indicating whether or not the attributes specified should completely replace the existing attributes (true) or be added to/modify them (false).  Defaults to false.
///
/// Returns:
///  * a copy of the `hs.styledtext` object with the attributes specified applied to the given range of the original object.
///
/// Notes:
///  * `starts` and `ends` follow the conventions of `i` and `j` for Lua's `string.sub` function.
private func string_setStyleForRange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let theString = get_objectFromUserdata(L, at: 1)
    let attributes = lua_tovalue(L, at: 2) as? [NSAttributedString.Key: Any]
    let replaceAttributes = lua_isboolean(L, lua_gettop(L)) ? (lua_toboolean(L, lua_gettop(L)) != 0) : false

    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, 3) ? 1 : luaL_checkinteger(L, 3)
    let luaJ = lua_isnoneornil(L, 4) ? len : luaL_checkinteger(L, 4)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)
    if resolved.empty {
        lua_pushany(L, theString.copy() as! NSAttributedString)
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        let newString = theString.mutableCopy() as! NSMutableAttributedString
        if let attributes = attributes {
            if replaceAttributes {
                newString.setAttributes(attributes, range: theRange)
            } else {
                newString.addAttributes(attributes, range: theRange)
            }
        }
        lua_pushany(L, newString)
    }
    return 1
}

/// hs.styledtext:removeStyle(attributes, [starts], [ends]) -> styledText object
/// Method
/// Return a copy of the `hs.styledtext` object containing the changes to its attributes specified in the `attributes` table.
///
/// Parameters:
///  * attributes - an array of attribute labels to remove (set to `nil`) from the `hs.styledtext` object.
///  * starts     - an optional index position within the text of the `hs.styledtext` object indicating the beginning of the substring to remove attributes for.
///  * ends       - an optional index position within the text of the `hs.styledtext` object indicating the end of the substring to remove attributes for.
///
/// Returns:
///  * a copy of the `hs.styledtext` object with the attributes specified removed from the given range of the original object.
///
/// Notes:
///  * `starts` and `ends` follow the conventions of `i` and `j` for Lua's `string.sub` function.
private func string_removeStyleForRange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let theString = get_objectFromUserdata(L, at: 1)
    var attributeKeys: [NSAttributedString.Key] = []
    var nextArg: Int32 = 2
    if lua_type(L, 2) == LUA_TTABLE {
        var idx: lua_Integer = 1
        while lua_rawgeti(L, 2, idx) != LUA_TNIL {
            let value = String(cString: lua_tostring(L, -1)!)
            if let resolved = attributeNameForKey(value) {
                attributeKeys.append(resolved)
            } else {
                // allow raw ObjC attribute names
                attributeKeys.append(NSAttributedString.Key(rawValue: value))
            }
            lua_pop(L, 1)
            idx += 1
        }
        lua_pop(L, 1) // the terminating nil
        nextArg += 1
    }

    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, nextArg) ? 1 : luaL_checkinteger(L, nextArg)
    let luaJ = lua_isnoneornil(L, nextArg + 1) ? len : luaL_checkinteger(L, nextArg + 1)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)
    if resolved.empty {
        lua_pushany(L, theString.copy() as! NSAttributedString)
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        let newString = theString.mutableCopy() as! NSMutableAttributedString
        for key in attributeKeys {
            newString.removeAttribute(key, range: theRange)
        }
        lua_pushany(L, newString)
    }
    return 1
}

/// hs.styledtext:setString(string, [starts], [ends], [clear]) -> styledText object
/// Method
/// Return a copy of the `hs.styledtext` object containing the changes to its attributes specified in the `attributes` table.
///
/// Parameters:
///  * string     - a string, table, or `hs.styledtext` object to insert or replace the substring specified.
///  * starts     - an optional index position within the text of the `hs.styledtext` object indicating the beginning of the destination for the specified string.
///  * ends       - an optional index position within the text of the `hs.styledtext` object indicating the end of destination for the specified string.
///  * clear      - an optional boolean indicating whether or not the attributes of the new string should be included (true) or whether the new substring should inherit the attributes of the first character replaced (false).
///
/// Returns:
///  * a copy of the `hs.styledtext` object with the specified substring replacement to the original object, or nil if an error occurs
private func string_replaceSubstringForRange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let theString = get_objectFromUserdata(L, at: 1)
    var withAttributes = (lua_type(L, 2) == LUA_TSTRING || lua_type(L, 2) == LUA_TNUMBER) ? false : true
    if lua_isboolean(L, lua_gettop(L)) {
        withAttributes = lua_toboolean(L, lua_gettop(L)) != 0
    }

    let subString = lua_tovalue(L, at: 2) as! NSAttributedString

    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    var i = lua_isnumber(L, 3) ? luaL_checkinteger(L, 3) : 1
    var j = lua_isnumber(L, 4) ? luaL_checkinteger(L, 4) : len
    let insert = (j == 0)

    if i < 0 { i = len + 1 + i }
    if !insert && j < 0 { j = len + 1 + j }
    if i < 1 { i = 1 }
    if j > len { j = len }
    if insert && i > len + 1 { i = len + 1 }
    if !insert && i > j {
        return luaL_argerror(L, 3, "starts index must be < ends index")
    }

    i = lua_Integer((theMap.object(forKey: NSNumber(value: i)) as! NSNumber).intValue)
    j = lua_Integer((theMap.object(forKey: NSNumber(value: j)) as! NSNumber).intValue)
    let theRange = insert ? NSRange(location: Int(i - 1), length: 0) : NSRange(location: Int(i - 1), length: Int(j - (i - 1)))

    let newString = theString.mutableCopy() as! NSMutableAttributedString

    if withAttributes {
        newString.replaceCharacters(in: theRange, with: subString.copy() as! NSAttributedString)
    } else {
        newString.replaceCharacters(in: theRange, with: subString.string)
    }
    lua_pushany(L, newString)

    return 1
}

/// hs.styledtext:convert([type]) -> string
/// Method
/// Converts the styledtext object into the data format specified.
///
/// Parameters:
///  * type          - a string indicating the format to convert the styletext object into.  Defaults to "html".
///
/// Returns:
///  * a string containing the converted data
private func string_convert(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let theString = get_objectFromUserdata(L, at: 1)

    var dataType: NSAttributedString.DocumentType = .html
    if lua_type(L, 2) != LUA_TNONE {
        if let requestType = lua_tovalue(L, at: 2) as? String {
            // Note: simpleText omitted from convert (requires resource fork)
            switch requestType {
            case "text":       dataType = .plain
            case "rtf":        dataType = .rtf
            case "rtfd":       dataType = .rtfd
            case "html":       dataType = .html
            case "word":       dataType = .docFormat
            case "wordXML":    dataType = .wordML
            case "openXML":    dataType = .officeOpenXML
            case "webArchive": dataType = .webArchive
            case "open":       dataType = .openDocument
            default:
                return luaL_argerror(L, 2, "unrecognized encoding type")
            }
        } else {
            return luaL_argerror(L, 2, "unrecognized encoding type")
        }
    }

    do {
        let theResult = try theString.data(from: NSRange(location: 0, length: theString.length),
                                           documentAttributes: [.documentType: dataType])
        lua_pushany(L, theResult as NSData)
    } catch {
        return luaL_error(L, "convert: conversion error: \(error.localizedDescription)")
    }
    return 1
}

/// hs.styledtext.loadFont(path) -> boolean[, string]
/// Function
/// Loads a font from a file at the specified path.
///
/// Parameters:
///  * `path` - the path and filename of the font file to attempt to load
///
/// Returns:
///  * If the font can be registered returns `true`, otherwise `false` and an error message as string.
private func registerFontByPath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    let path = (lua_tovalue(L, at: 1) as! NSString).expandingTildeInPath
    var errorRef: Unmanaged<CFError>?
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &errorRef)
    if let errorRef = errorRef {
        let error = errorRef.takeRetainedValue() as Error
        lua_pushboolean(L, 0)
        lua_pushstring(L, (error as NSError).localizedDescription)
        return 2
    }
    lua_pushboolean(L, 1)
    return 1
}

// MARK: - Methods to mimic Lua's string type as closely as possible

/// hs.styledtext:upper() -> styledText object
/// Method
/// Returns a copy of the `hs.styledtext` object with all alpha characters converted to upper case.  Mimics the Lua `string.upper` function.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a copy of the `hs.styledtext` object with all alpha characters converted to upper case
private func string_upper(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theString = get_objectFromUserdata(L, at: 1)
    let newString = theString.mutableCopy() as! NSMutableAttributedString
    if newString.length > 0 {
        let stringRange = NSRange(location: 0, length: theString.length)
        newString.replaceCharacters(in: stringRange, with: theString.string.uppercased())
        lua_pushany(L, newString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.styledtext:lower() -> styledText object
/// Method
/// Returns a copy of the `hs.styledtext` object with all alpha characters converted to lower case.  Mimics the Lua `string.lower` function.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a copy of the `hs.styledtext` object with all alpha characters converted to lower case
private func string_lower(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theString = get_objectFromUserdata(L, at: 1)
    let newString = theString.mutableCopy() as! NSMutableAttributedString
    if newString.length > 0 {
        let stringRange = NSRange(location: 0, length: theString.length)
        newString.replaceCharacters(in: stringRange, with: theString.string.lowercased())
        lua_pushany(L, newString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.styledtext:sub(starts, [ends]) -> styledText object
/// Method
/// Returns a substring, including the style attributes, specified by the given indices from the `hs.styledtext` object.  Mimics the Lua `string.sub` function.
///
/// Parameters:
///  * starts - the index position within the text of the `hs.styledtext` object indicating the beginning of the substring to return.
///  * ends   - an optional index position within the text of the `hs.styledtext` object indicating the end of the substring to return.  Defaults to the length of the objects text.
///
/// Returns:
///  * an `hs.styledtext` object containing the specified substring.
///
/// Notes:
///  * `starts` and `ends` follow the conventions of `i` and `j` for Lua's `string.sub` function.
private func string_sub(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString = get_objectFromUserdata(L, at: 1)

    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = luaL_checkinteger(L, 2)
    var luaJ = len
    if lua_type(L, 3) == LUA_TNUMBER {
        luaJ = luaL_checkinteger(L, 3)
    }

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)
    if resolved.empty {
        lua_pushany(L, NSAttributedString(string: ""))
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        lua_pushany(L, theString.attributedSubstring(from: theRange))
    }
    return 1
}

// MARK: - LuaSkin conversion helpers

// NSAttributedString from userdata, table, or string/number at the specified index
private func lua_toNSAttributedString(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let skin = LuaSkin.skin(with: L)
    var theString: NSMutableAttributedString?

    if lua_type(L, idx) == LUA_TSTRING || lua_type(L, idx) == LUA_TNUMBER {
        luaL_tolstring(L, idx, nil)
        theString = NSMutableAttributedString(string: lua_tovalue(L, at: -1) as! String)
        lua_pop(L, 1)
    } else if lua_type(L, idx) == LUA_TUSERDATA && luaL_testudata(L, idx, USERDATA_TAG) != nil {
        theString = get_objectFromUserdata(L, at: idx).mutableCopy() as? NSMutableAttributedString
    } else if lua_type(L, idx) == LUA_TTABLE {
        lua_rawgeti(L, idx, 1)
        luaL_tolstring(L, -1, nil)
        lua_remove(L, -2) // luaL_tolstring pushes its value onto the stack without removing/touching the original
        theString = NSMutableAttributedString(string: lua_tovalue(L, at: -1) as! String)
        lua_pop(L, 1)

        let theMap = luaByteToObjCharMap(theString!.string as NSString)

        var locInTable: lua_Integer = 2
        while lua_rawgeti(L, idx, locInTable) != LUA_TNIL {
            if lua_type(L, -1) == LUA_TTABLE {
                let loc: UInt = (lua_getfield(L, -1, "starts") == LUA_TNUMBER) ? UInt(lua_tointeger(L, -1)) - 1 : 0
                lua_pop(L, 1)
                var length: UInt = (lua_getfield(L, -1, "ends") == LUA_TNUMBER) ? UInt(lua_tointeger(L, -1)) : UInt(theString!.length)
                lua_pop(L, 1)
                length = length - loc

                // convert starts and ends into their obj-c equivalents
                let objLoc = (theMap.object(forKey: NSNumber(value: loc)) as? NSNumber)?.uintValue ?? 0
                let objLen = (theMap.object(forKey: NSNumber(value: length)) as? NSNumber)?.uintValue ?? 0

                lua_getfield(L, -1, "attributes")
                if let attrs = skin.luaObject(at:-1, toClass: "hs.styledtext.AttributesDictionary") as? [NSAttributedString.Key: Any] {
                    theString!.setAttributes(attrs, range: NSRange(location: Int(objLoc), length: Int(objLen)))
                }
                lua_pop(L, 1) // attributes field
            } else {
                os_log(.info, "%{public}s", "skipping style specification \(locInTable - 1): expected table, found \(String(cString: lua_typename(L, lua_type(L, -1)))).")
            }
            locInTable += 1
            lua_pop(L, 1)
        }
        lua_pop(L, 1) // the loop terminating nil
    }

    return theString
}

// Pseudo class: converts a Lua table of attribute key-value pairs into an NSDictionary
private func table_toAttributesDictionary(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let skin = LuaSkin.skin(with: L)
    let theAttributes = NSMutableDictionary()

    if lua_type(L, idx) == LUA_TTABLE {
        if lua_getfield(L, idx, "font") == LUA_TTABLE || lua_type(L, -1) == LUA_TSTRING {
            if let font = skin.luaObject(at:-1, toClass: "NSFont") as? NSFont {
                theAttributes[NSAttributedString.Key.font] = font
            }
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "paragraphStyle") == LUA_TTABLE {
            if let ps = skin.luaObject(at:-1, toClass: "NSParagraphStyle") as? NSParagraphStyle {
                theAttributes[NSAttributedString.Key.paragraphStyle] = ps
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "underlineStyle") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.underlineStyle] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "superscript") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.superscript] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "ligature") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.ligature] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "strikethroughStyle") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.strikethroughStyle] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "baselineOffset") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.baselineOffset] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "kerning") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.kern] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "strokeWidth") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.strokeWidth] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "obliqueness") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.obliqueness] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "expansion") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.expansion] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "color") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.foregroundColor] = skin.luaObject(at:-1, toClass: "NSColor")
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "backgroundColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.backgroundColor] = skin.luaObject(at:-1, toClass: "NSColor")
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "strokeColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.strokeColor] = skin.luaObject(at:-1, toClass: "NSColor")
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "underlineColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.underlineColor] = skin.luaObject(at:-1, toClass: "NSColor")
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "strikethroughColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.strikethroughColor] = skin.luaObject(at:-1, toClass: "NSColor")
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "shadow") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.shadow] = skin.luaObject(at:-1, toClass: "NSShadow")
        }
        lua_pop(L, 1)
    } else {
        os_log(.error, "%{public}s", "invalid attributes dictionary: expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }

    return theAttributes
}

private func NSAttributedString_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let theString = obj as! NSAttributedString
    let stringPtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    stringPtr.storeBytes(of: Unmanaged.passRetained(theString).toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func NSFont_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let theFont = obj as! NSFont

    lua_newtable(L)
    lua_pushany(L, theFont.fontName as NSString)
    lua_setfield(L, -2, "name")
    lua_pushnumber(L, lua_Number(theFont.pointSize))
    lua_setfield(L, -2, "size")
    lua_pushstring(L, "NSFont"); lua_setfield(L, -2, "__luaSkinType")

    return 1
}

private func table_toNSFont(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let skin = LuaSkin.skin(with: L)
    var theName = NSFont.systemFont(ofSize: 0).fontName
    var theSize = NSFont.systemFontSize

    if lua_type(L, idx) == LUA_TSTRING {
        theName = lua_tovalue(L, at: idx) as! String
    } else if lua_type(L, idx) == LUA_TTABLE {
        if lua_getfield(L, idx, "name") == LUA_TSTRING {
            theName = lua_tovalue(L, at: -1) as! String
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "size") == LUA_TNUMBER {
            theSize = CGFloat(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
    } else {
        os_log(.info, "%{public}s", "invalid font: expected table or string, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }

    if let theFont = NSFont(name: theName, size: theSize) {
        return theFont
    } else {
        os_log(.info, "%{public}s", "invalid font specified: \(theName)")
        return NSFont.systemFont(ofSize: 0)
    }
}

private func NSShadow_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let theShadow = obj as! NSShadow
    let offset = theShadow.shadowOffset

    lua_newtable(L)
    lua_newtable(L)
    lua_pushnumber(L, lua_Number(offset.height))
    lua_setfield(L, -2, "h")
    lua_pushnumber(L, lua_Number(offset.width))
    lua_setfield(L, -2, "w")
    lua_setfield(L, -2, "offset")
    lua_pushnumber(L, lua_Number(theShadow.shadowBlurRadius))
    lua_setfield(L, -2, "blurRadius")
    lua_pushany(L, theShadow.shadowColor)
    lua_setfield(L, -2, "color")
    lua_pushstring(L, "NSShadow"); lua_setfield(L, -2, "__luaSkinType")

    return 1
}

private func table_toNSShadow(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let skin = LuaSkin.skin(with: L)
    let theShadow = NSShadow()
    if lua_type(L, idx) == LUA_TTABLE {
        if lua_getfield(L, idx, "offset") == LUA_TTABLE {
            theShadow.shadowOffset = lua_tableToSize(L, at: -1)
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "blurRadius") == LUA_TNUMBER {
            theShadow.shadowBlurRadius = CGFloat(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "color") == LUA_TTABLE {
            theShadow.shadowColor = skin.luaObject(at:-1, toClass: "NSColor") as? NSColor
        }
        lua_pop(L, 1)
    } else {
        os_log(.info, "%{public}s", "invalid shadow object: expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return theShadow
}

private func NSParagraphStyle_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let thePS = obj as! NSParagraphStyle

    lua_newtable(L)

    switch thePS.alignment {
    case .left:       lua_pushstring(L, "left")
    case .right:      lua_pushstring(L, "right")
    case .center:     lua_pushstring(L, "center")
    case .justified:  lua_pushstring(L, "justified")
    case .natural:    lua_pushstring(L, "natural")
    @unknown default: lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "alignment")

    switch thePS.lineBreakMode {
    case .byWordWrapping:      lua_pushstring(L, "wordWrap")
    case .byCharWrapping:      lua_pushstring(L, "charWrap")
    case .byClipping:          lua_pushstring(L, "clip")
    case .byTruncatingHead:    lua_pushstring(L, "truncateHead")
    case .byTruncatingTail:    lua_pushstring(L, "truncateTail")
    case .byTruncatingMiddle:  lua_pushstring(L, "truncateMiddle")
    @unknown default:          lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "lineBreak")

    switch thePS.baseWritingDirection {
    case .natural:      lua_pushstring(L, "natural")
    case .leftToRight:  lua_pushstring(L, "leftToRight")
    case .rightToLeft:  lua_pushstring(L, "rightToLeft")
    @unknown default:   lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "baseWritingDirection")

    lua_pushnumber(L, lua_Number(thePS.defaultTabInterval))
    lua_setfield(L, -2, "defaultTabInterval")
    lua_pushnumber(L, lua_Number(thePS.firstLineHeadIndent))
    lua_setfield(L, -2, "firstLineHeadIndent")
    lua_pushnumber(L, lua_Number(thePS.headIndent))
    lua_setfield(L, -2, "headIndent")
    lua_pushnumber(L, lua_Number(thePS.tailIndent))
    lua_setfield(L, -2, "tailIndent")
    lua_pushnumber(L, lua_Number(thePS.maximumLineHeight))
    lua_setfield(L, -2, "maximumLineHeight")
    lua_pushnumber(L, lua_Number(thePS.minimumLineHeight))
    lua_setfield(L, -2, "minimumLineHeight")
    lua_pushnumber(L, lua_Number(thePS.lineSpacing))
    lua_setfield(L, -2, "lineSpacing")
    lua_pushnumber(L, lua_Number(thePS.paragraphSpacing))
    lua_setfield(L, -2, "paragraphSpacing")
    lua_pushnumber(L, lua_Number(thePS.paragraphSpacingBefore))
    lua_setfield(L, -2, "paragraphSpacingBefore")
    lua_pushnumber(L, lua_Number(thePS.lineHeightMultiple))
    lua_setfield(L, -2, "lineHeightMultiple")
    lua_pushnumber(L, lua_Number(thePS.hyphenationFactor))
    lua_setfield(L, -2, "hyphenationFactor")
    lua_pushnumber(L, lua_Number(thePS.tighteningFactorForTruncation))
    lua_setfield(L, -2, "tighteningFactorForTruncation")
    lua_pushboolean(L, thePS.allowsDefaultTighteningForTruncation ? 1 : 0)
    lua_setfield(L, -2, "allowsTighteningForTruncation")

    lua_pushany(L, thePS.tabStops as NSArray?)
    lua_setfield(L, -2, "tabStops")
    lua_pushinteger(L, lua_Integer(thePS.headerLevel))
    lua_setfield(L, -2, "headerLevel")
    lua_pushstring(L, "NSParagraphStyle"); lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func table_toNSParagraphStyle(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let skin = LuaSkin.skin(with: L)
    let thePS = (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)

    if lua_type(L, idx) == LUA_TTABLE {
        if lua_getfield(L, idx, "alignment") == LUA_TSTRING {
            let theString = lua_tovalue(L, at: -1) as! String
            switch theString {
            case "left":      thePS.alignment = .left
            case "right":     thePS.alignment = .right
            case "center":    thePS.alignment = .center
            case "justified": thePS.alignment = .justified
            case "natural":   thePS.alignment = .natural
            default:          os_log(.info, "%{public}s", "invalid alignment specified: \(theString)")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "lineBreak") == LUA_TSTRING {
            let theString = lua_tovalue(L, at: -1) as! String
            switch theString {
            case "charWrap":        thePS.lineBreakMode = .byCharWrapping
            case "clip":            thePS.lineBreakMode = .byClipping
            case "truncateHead":    thePS.lineBreakMode = .byTruncatingHead
            case "truncateTail":    thePS.lineBreakMode = .byTruncatingTail
            case "truncateMiddle":  thePS.lineBreakMode = .byTruncatingMiddle
            case "wordWrap":        thePS.lineBreakMode = .byWordWrapping
            default:                os_log(.info, "%{public}s", "invalid lineBreakMode: \(theString)")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "baseWritingDirection") == LUA_TSTRING {
            let theString = lua_tovalue(L, at: -1) as! String
            switch theString {
            case "leftToRight":  thePS.baseWritingDirection = .leftToRight
            case "rightToLeft":  thePS.baseWritingDirection = .rightToLeft
            case "natural":      thePS.baseWritingDirection = .natural
            default:             os_log(.info, "%{public}s", "invalid baseWritingDirection: \(theString)")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "defaultTabInterval") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.defaultTabInterval = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "defaultTabInterval must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "firstLineHeadIndent") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.firstLineHeadIndent = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "firstLineHeadIndent must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "headIndent") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.headIndent = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "headIndent must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "tailIndent") == LUA_TNUMBER {
            thePS.tailIndent = CGFloat(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "maximumLineHeight") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.maximumLineHeight = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "maximumLineHeight must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "minimumLineHeight") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.minimumLineHeight = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "minimumLineHeight must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "lineSpacing") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.lineSpacing = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "lineSpacing must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "paragraphSpacing") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.paragraphSpacing = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "paragraphSpacing must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "paragraphSpacingBefore") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.paragraphSpacingBefore = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "paragraphSpacingBefore must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "lineHeightMultiple") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 {
                thePS.lineHeightMultiple = CGFloat(theNumber)
            } else {
                os_log(.info, "%{public}s", "lineHeightMultiple must be non-negative")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "hyphenationFactor") == LUA_TNUMBER {
            let theNumber = lua_tonumber(L, -1)
            if theNumber >= 0.0 && theNumber <= 1.0 {
                thePS.hyphenationFactor = Float(theNumber)
            } else {
                os_log(.info, "%{public}s", "hyphenationFactor must be between 0.0 and 1.0 inclusive")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "tighteningFactorForTruncation") == LUA_TNUMBER {
            thePS.tighteningFactorForTruncation = Float(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "allowsTighteningForTruncation") == LUA_TBOOLEAN {
            thePS.allowsDefaultTighteningForTruncation = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "headerLevel") == LUA_TNUMBER {
            let theNumber = lua_tointeger(L, -1)
            if theNumber >= 0 && theNumber <= 6 {
                thePS.headerLevel = Int(theNumber)
            } else {
                os_log(.info, "%{public}s", "headerNumber must be between 0 and 6 inclusive")
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "tabStops") == LUA_TTABLE {
            var theTabStops: [NSTextTab] = []
            var pos: lua_Integer = 1
            while lua_rawgeti(L, -1, pos) != LUA_TNIL {
                if lua_type(L, -1) == LUA_TTABLE {
                    if let tab = skin.luaObject(at:-1, toClass: "NSTextTab") as? NSTextTab {
                        theTabStops.append(tab)
                    }
                    lua_pop(L, 1)
                } else {
                    os_log(.info, "%{public}s", "invalid tapStop at position \(pos): expected table, found \(String(cString: lua_typename(L, lua_type(L, -1))))")
                }
                pos += 1
            }
            lua_pop(L, 1) // loop terminating nil
            thePS.tabStops = theTabStops
        }
        lua_pop(L, 1)
    } else {
        os_log(.info, "%{public}s", "invalid paragraphStyle: expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return thePS
}

private func NSTextTab_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let theTabStop = obj as! NSTextTab
    lua_newtable(L)

    lua_pushnumber(L, lua_Number(theTabStop.location))
    lua_setfield(L, -2, "location")

    switch theTabStop.tabStopType {
    case .leftTabStopType:    lua_pushstring(L, "left")
    case .rightTabStopType:   lua_pushstring(L, "right")
    case .centerTabStopType:  lua_pushstring(L, "center")
    case .decimalTabStopType: lua_pushstring(L, "decimal")
    @unknown default:         lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "tabStopType")
    lua_pushstring(L, "NSTextTab"); lua_setfield(L, -2, "__luaSkinType")

    return 1
}

private func table_toNSTextTab(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let skin = LuaSkin.skin(with: L)
    var tabStopType: NSParagraphStyle.TextTabType = .leftTabStopType
    var tabStopLocation: CGFloat = 0.0

    if lua_type(L, idx) == LUA_TTABLE {
        if lua_getfield(L, idx, "tabStopType") == LUA_TSTRING {
            let theString = lua_tovalue(L, at: -1) as! String
            switch theString {
            case "left":    tabStopType = .leftTabStopType
            case "right":   tabStopType = .rightTabStopType
            case "center":  tabStopType = .centerTabStopType
            case "decimal": tabStopType = .decimalTabStopType
            default:        os_log(.info, "%{public}s", "invalid tabStopType: \(theString)")
            }
        }
        lua_pop(L, 1)
        if lua_getfield(L, idx, "location") == LUA_TNUMBER {
            tabStopLocation = CGFloat(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
    } else {
        os_log(.error, "%{public}s", "invalid type for tabStop: expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return NSTextTab(type: tabStopType, location: tabStopLocation)
}

// MARK: - Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let title = get_objectFromUserdata(L, at: 1).string
    if title.count > 20 {
        let truncated = String(title.prefix(20))
        lua_pushstring(L, "\(USERDATA_TAG): \(truncated)... (\(lua_topointer(L, 1)!))")
    } else {
        lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
    }
    return 1
}

private func userdata_concat(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_type(L, 1) == LUA_TSTRING || lua_type(L, 1) == LUA_TNUMBER {
        let theString1 = String(cString: lua_tostring(L, 1)!)
        let theString2 = get_objectFromUserdata(L, at: 2).string
        let newString = NSMutableString(string: theString1)
        newString.append(theString2)
        lua_pushany(L, newString)
    } else {
        let theString1 = get_objectFromUserdata(L, at: 1)
        let newString = theString1.mutableCopy() as! NSMutableAttributedString
        if lua_type(L, 2) == LUA_TSTRING || lua_type(L, 2) == LUA_TNUMBER {
            let addition = String(cString: lua_tostring(L, 2)!)
            newString.replaceCharacters(in: NSRange(location: newString.length, length: 0), with: addition)
        } else {
            newString.append(get_objectFromUserdata(L, at: 2))
        }
        lua_pushany(L, newString)
    }
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString1 = (lua_type(L, 1) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 1).string :
                                                          String(cString: lua_tostring(L, 1)!)
    let theString2 = (lua_type(L, 2) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 2).string :
                                                          String(cString: lua_tostring(L, 2)!)
    lua_pushboolean(L, theString1 == theString2 ? 1 : 0)
    return 1
}

private func userdata_lt(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString1 = (lua_type(L, 1) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 1).string :
                                                          String(cString: lua_tostring(L, 1)!)
    let theString2 = (lua_type(L, 2) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 2).string :
                                                          String(cString: lua_tostring(L, 2)!)
    lua_pushboolean(L, (theString1 as NSString).compare(theString2) == .orderedAscending ? 1 : 0)
    return 1
}

private func userdata_le(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString1 = (lua_type(L, 1) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 1).string :
                                                          String(cString: lua_tostring(L, 1)!)
    let theString2 = (lua_type(L, 2) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 2).string :
                                                          String(cString: lua_tostring(L, 2)!)
    lua_pushboolean(L, (theString1 as NSString).compare(theString2) != .orderedDescending ? 1 : 0)
    return 1
}

/// hs.styledtext:len() -> integer
/// Method
/// Returns the length of the text of the `hs.styledtext` object.  Mimics the Lua `string.len` function.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an integer which is the length of the text of the `hs.styledtext` object.
private func userdata_len(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theString = get_objectFromUserdata(L, at: 1)
    let theMap = luaByteToObjCharMap(theString.string as NSString)
    lua_pushinteger(L, lua_Integer(theMap.count))
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil {
        let _ = get_objectFromUserdata_transfer(L, at: 1)
        lua_pushnil(L)
        lua_setmetatable(L, 1)
    }
    return 0
}

// MARK: - luaL_Reg tables

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("isIdentical"), func: string_identical),
    luaL_Reg(name: strdup("copy"), func: string_copy),
    luaL_Reg(name: strdup("asTable"), func: string_totable),
    luaL_Reg(name: strdup("getString"), func: string_tostring),
    luaL_Reg(name: strdup("setStyle"), func: string_setStyleForRange),
    luaL_Reg(name: strdup("removeStyle"), func: string_removeStyleForRange),
    luaL_Reg(name: strdup("setString"), func: string_replaceSubstringForRange),
    luaL_Reg(name: strdup("convert"), func: string_convert),

    luaL_Reg(name: strdup("len"), func: userdata_len),
    luaL_Reg(name: strdup("upper"), func: string_upper),
    luaL_Reg(name: strdup("lower"), func: string_lower),
    luaL_Reg(name: strdup("sub"), func: string_sub),

    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__concat"), func: userdata_concat),
    luaL_Reg(name: strdup("__len"), func: userdata_len),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__lt"), func: userdata_lt),
    luaL_Reg(name: strdup("__le"), func: userdata_le),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil)
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: string_new),
    luaL_Reg(name: strdup("getStyledTextFromFile"), func: getStyledTextFromFile),
    luaL_Reg(name: strdup("getStyledTextFromData"), func: getStyledTextFromData),
    luaL_Reg(name: strdup("luaToObjCMap"), func: luaToObjCMap),

    luaL_Reg(name: strdup("loadFont"), func: registerFontByPath),
    luaL_Reg(name: strdup("convertFont"), func: font_convertFont),
    luaL_Reg(name: strdup("validFont"), func: validFont),
    luaL_Reg(name: strdup("_fontInfo"), func: fontInformation),
    luaL_Reg(name: strdup("_fontNames"), func: fontNames),
    luaL_Reg(name: strdup("_fontFamilies"), func: fontFamilies),
    luaL_Reg(name: strdup("_fontsForFamily"), func: fontsForFamily),
    luaL_Reg(name: strdup("_fontNamesWithTraits"), func: fontNamesWithTraits),
    luaL_Reg(name: strdup("fontPath"), func: fontPath),

    luaL_Reg(name: strdup("_defaultFonts"), func: defineDefaultFonts),

    luaL_Reg(name: nil, func: nil)
]

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libstyledtext")
public func luaopen_hs_libstyledtext(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    fontTraits(L)
    lua_setfield(L, -2, "fontTraits")

    defineLinePatterns(L)
    lua_setfield(L, -2, "linePatterns")
    defineLineStyles(L)
    lua_setfield(L, -2, "lineStyles")
    defineLineAppliesTo(L)
    lua_setfield(L, -2, "lineAppliesTo")

    return 1
}

