import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.styledtext"

// MARK: - Helpers

private func get_objectFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSAttributedString {
    lua_checkUserdataObject(NSAttributedString.self, L, at: idx, metatableName: USERDATA_TAG)
}

private func get_objectFromUserdata_transfer(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSAttributedString? {
    lua_takeRetainedUserdataObjectIfPresent(NSAttributedString.self, L, at: idx, metatableName: USERDATA_TAG)
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
private func string_new(_ L: LuaState) throws -> CInt {
    guard let sourceString = lua_toNSAttributedString(L, at: 1) as? NSAttributedString else {
        throw LuaCallError("bad argument #1 (expected string, table, or styledtext object)")
    }
    let newString = sourceString.mutableCopy() as! NSMutableAttributedString
    if lua_gettop(L) == 2 {
        if let attributes = table_toAttributesDictionary(L, at: 2) as? [NSAttributedString.Key: Any] {
            let theRange = NSRange(location: 0, length: newString.length)
            newString.addAttributes(attributes, range: theRange)
        }
    }
    NSAttributedString_toLua(L, obj: newString)
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
private func getStyledTextFromData(_ L: LuaState) throws -> CInt {

    var dataType: NSAttributedString.DocumentType = .html
    if lua_type(L, 2) != LUA_TNONE {
        if let requestType = lua_tovalue(L, at: 2) as? String,
           let resolved = documentType(from: requestType) {
            dataType = resolved
        } else {
            throw LuaCallError("bad argument #2 (unrecognized encoding type)")
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
        NSAttributedString_toLua(L, obj: newString)
    } catch {
        throw LuaCallError("setTextFromData: conversion error: \(error.localizedDescription)")
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
private func getStyledTextFromFile(_ L: LuaState) throws -> CInt {

    var dataType: NSAttributedString.DocumentType = .html
    if lua_type(L, 2) != LUA_TNONE {
        if let requestType = lua_tovalue(L, at: 2) as? String,
           let resolved = documentType(from: requestType) {
            dataType = resolved
        } else {
            throw LuaCallError("bad argument #2 (unrecognized encoding type)")
        }
    }

    let path = (lua_tovalue(L, at: 1) as! NSString).expandingTildeInPath
    do {
        let newString = try NSAttributedString(url: URL(fileURLWithPath: path),
                                               options: [.documentType: dataType],
                                               documentAttributes: nil)
        NSAttributedString_toLua(L, obj: newString)
    } catch {
        throw LuaCallError("setTextFromFile: conversion error: \(error.localizedDescription)")
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
private func fontNames(_ L: LuaState) throws -> CInt {

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
private func fontFamilies(_ L: LuaState) throws -> CInt {

    if let families = NSFontManager.shared.availableFontFamilies as NSArray? {
        lua_pushany(L, families.sortedArray(using: #selector(NSString.localizedCaseInsensitiveCompare(_:))) as NSArray)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func fontsForFamily(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    if let fontFamily = lua_tovalue(L, at: 1) as? String {
        let details = NSFontManager.shared.availableMembers(ofFontFamily: fontFamily)
        lua_pushany(L, details as NSArray?)
    } else {
        L.push(false)
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
private func font_convertFont(_ L: LuaState) throws -> CInt {

    guard let theFont = table_toNSFont(L, at: 1) as? NSFont else {
        throw LuaCallError("bad argument #1 (does not specify a font)")
    }
    if lua_type(L, 2) == LUA_TNUMBER {
        NSFont_toLua(L, obj: NSFontManager.shared.convert(theFont, toHaveTrait: NSFontTraitMask(rawValue: UInt(luaL_checkinteger(L, 2)))))
    } else {
        NSFont_toLua(L, obj: NSFontManager.shared.convertWeight(lua_toboolean(L, 2) != 0, of: theFont))
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
private func fontNamesWithTraits(_ L: LuaState) throws -> CInt {

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
        throw LuaCallError("bad argument #1 (expected integer or table)")
    }

    if let names = NSFontManager.shared.availableFontNames(with: theTraits) {
        lua_newtable(L)
        for (indFont, name) in names.enumerated() {
            L.push(name)
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
    L.push(Int(NSFontTraitMask.boldFontMask.rawValue))
    lua_setfield(L, -2, "boldFont")
    L.push(Int(NSFontTraitMask.compressedFontMask.rawValue))
    lua_setfield(L, -2, "compressedFont")
    L.push(Int(NSFontTraitMask.condensedFontMask.rawValue))
    lua_setfield(L, -2, "condensedFont")
    L.push(Int(NSFontTraitMask.expandedFontMask.rawValue))
    lua_setfield(L, -2, "expandedFont")
    L.push(Int(NSFontTraitMask.fixedPitchFontMask.rawValue))
    lua_setfield(L, -2, "fixedPitchFont")
    L.push(Int(NSFontTraitMask.italicFontMask.rawValue))
    lua_setfield(L, -2, "italicFont")
    L.push(Int(NSFontTraitMask.narrowFontMask.rawValue))
    lua_setfield(L, -2, "narrowFont")
    L.push(Int(NSFontTraitMask.posterFontMask.rawValue))
    lua_setfield(L, -2, "posterFont")
    L.push(Int(NSFontTraitMask.smallCapsFontMask.rawValue))
    lua_setfield(L, -2, "smallCapsFont")
    L.push(Int(NSFontTraitMask.nonStandardCharacterSetFontMask.rawValue))
    lua_setfield(L, -2, "nonStandardCharacterSetFont")
    L.push(Int(NSFontTraitMask.unboldFontMask.rawValue))
    lua_setfield(L, -2, "unboldFont")
    L.push(Int(NSFontTraitMask.unitalicFontMask.rawValue))
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
private func validFont(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let fontName = lua_tovalue(L, at: 1) as! String
    let theFont = NSFont(name: fontName, size: 1)
    L.push(theFont != nil)
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
private func fontInformation(_ L: LuaState) throws -> CInt {
    let theFont = tableToNSFont(L, at: -1) ?? NSFont.systemFont(ofSize: 0)

    lua_newtable(L)
    lua_pushany(L, theFont.fontName as NSString)
    lua_setfield(L, -2, "fontName")
    lua_pushany(L, theFont.familyName as NSString?)
    lua_setfield(L, -2, "familyName")
    lua_pushany(L, theFont.displayName as NSString?)
    lua_setfield(L, -2, "displayName")
    L.push(theFont.isFixedPitch)
    lua_setfield(L, -2, "fixedPitch")
    L.push(lua_Number(theFont.ascender))
    lua_setfield(L, -2, "ascender")
    let boundingRect = theFont.boundingRectForFont
    lua_newtable(L)
    L.push(lua_Number(boundingRect.origin.x))
    lua_setfield(L, -2, "x")
    L.push(lua_Number(boundingRect.origin.y))
    lua_setfield(L, -2, "y")
    L.push(lua_Number(boundingRect.size.height))
    lua_setfield(L, -2, "h")
    L.push(lua_Number(boundingRect.size.width))
    lua_setfield(L, -2, "w")
    lua_setfield(L, -2, "boundingRect")
    L.push(lua_Number(theFont.capHeight))
    lua_setfield(L, -2, "capHeight")
    L.push(lua_Number(theFont.descender))
    lua_setfield(L, -2, "descender")
    L.push(lua_Number(theFont.italicAngle))
    lua_setfield(L, -2, "italicAngle")
    L.push(lua_Number(theFont.leading))
    lua_setfield(L, -2, "leading")
    let maxAdvance = theFont.maximumAdvancement
    lua_newtable(L)
    L.push(lua_Number(maxAdvance.height))
    lua_setfield(L, -2, "h")
    L.push(lua_Number(maxAdvance.width))
    lua_setfield(L, -2, "w")
    lua_setfield(L, -2, "maximumAdvancement")
    L.push(Int(theFont.numberOfGlyphs))
    lua_setfield(L, -2, "numberOfGlyphs")
    L.push(lua_Number(theFont.pointSize))
    lua_setfield(L, -2, "pointSize")
    L.push(lua_Number(theFont.underlinePosition))
    lua_setfield(L, -2, "underlinePosition")
    L.push(lua_Number(theFont.underlineThickness))
    lua_setfield(L, -2, "underlineThickness")
    L.push(lua_Number(theFont.xHeight))
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
private func fontPath(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let fontName = lua_tovalue(L, at: 1) as! String
    if NSFont(name: fontName, size: 1) != nil {
        let theFont = tableToNSFont(L, at: -1) ?? NSFont.systemFont(ofSize: 0)
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
    L.push(0) // NSUnderlineStyleNone
    lua_setfield(L, -2, "none")
    L.push(Int(NSUnderlineStyle.single.rawValue))
    lua_setfield(L, -2, "single")
    L.push(Int(NSUnderlineStyle.thick.rawValue))
    lua_setfield(L, -2, "thick")
    L.push(Int(NSUnderlineStyle.double.rawValue))
    lua_setfield(L, -2, "double")
    return 1
}

/// hs.styledtext.linePatterns
/// Constant
/// A table of patterns which apply to the line for underlining or strike-through.
private func defineLinePatterns(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    L.push(0) // NSUnderlineStyle.patternSolid (rawValue 0)
    lua_setfield(L, -2, "solid")
    L.push(Int(NSUnderlineStyle.patternDot.rawValue))
    lua_setfield(L, -2, "dot")
    L.push(Int(NSUnderlineStyle.patternDash.rawValue))
    lua_setfield(L, -2, "dash")
    L.push(Int(NSUnderlineStyle.patternDashDot.rawValue))
    lua_setfield(L, -2, "dashDot")
    L.push(Int(NSUnderlineStyle.patternDashDotDot.rawValue))
    lua_setfield(L, -2, "dashDotDot")
    return 1
}

/// hs.styledtext.lineAppliesTo
/// Constant
/// A table of values indicating how the line for underlining or strike-through are applied to the text.
private func defineLineAppliesTo(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    L.push(0)
    lua_setfield(L, -2, "line")
    L.push(Int(NSUnderlineStyle.byWord.rawValue))
    lua_setfield(L, -2, "word")
    return 1
}

/// hs.styledtext.defaultFonts
/// Constant
/// A table containing the system default fonts and sizes.
private func defineDefaultFonts(_ L: LuaState) throws -> CInt {
    lua_newtable(L)
    NSFont_toLua(L, obj: NSFont.boldSystemFont(ofSize: 0));     lua_setfield(L, -2, "boldSystem")
    NSFont_toLua(L, obj: NSFont.controlContentFont(ofSize: 0)); lua_setfield(L, -2, "controlContent")
    NSFont_toLua(L, obj: NSFont.labelFont(ofSize: 0));          lua_setfield(L, -2, "label")
    NSFont_toLua(L, obj: NSFont.menuFont(ofSize: 0));           lua_setfield(L, -2, "menu")
    NSFont_toLua(L, obj: NSFont.menuBarFont(ofSize: 0));        lua_setfield(L, -2, "menuBar")
    NSFont_toLua(L, obj: NSFont.messageFont(ofSize: 0));        lua_setfield(L, -2, "message")
    NSFont_toLua(L, obj: NSFont.paletteFont(ofSize: 0));        lua_setfield(L, -2, "palette")
    NSFont_toLua(L, obj: NSFont.systemFont(ofSize: 0));         lua_setfield(L, -2, "system")
    NSFont_toLua(L, obj: NSFont.titleBarFont(ofSize: 0));       lua_setfield(L, -2, "titleBar")
    NSFont_toLua(L, obj: NSFont.toolTipsFont(ofSize: 0));       lua_setfield(L, -2, "toolTips")
    NSFont_toLua(L, obj: NSFont.userFont(ofSize: 0));           lua_setfield(L, -2, "user")
    NSFont_toLua(L, obj: NSFont.userFixedPitchFont(ofSize: 0)); lua_setfield(L, -2, "userFixedPitch")
    return 1
}

// MARK: - Lua byte to ObjC char mapping validation

private func luaToObjCMap(_ L: LuaState) throws -> CInt {
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

private func styledtext_attributeValueToLua(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any) {
    switch value {
    case let font as NSFont:
        NSFont_toLua(L, obj: font)
    case let paragraphStyle as NSParagraphStyle:
        NSParagraphStyle_toLua(L, obj: paragraphStyle)
    case let color as NSColor:
        NSColor_tolua(L, color)
    case let shadow as NSShadow:
        NSShadow_toLua(L, obj: shadow)
    case let textTab as NSTextTab:
        NSTextTab_toLua(L, obj: textTab)
    case let array as NSArray:
        lua_createtable(L, Int32(array.count), 0)
        for item in array {
            styledtext_attributeValueToLua(L, item)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    default:
        let top = lua_gettop(L)
        lua_pushany(L, value)
        if lua_gettop(L) == top {
            lua_pushnil(L)
        }
    }
}

/// hs.styledtext:copy(styledText) -> styledText object
/// Method
/// Create a copy of the `hs.styledtext` object.
///
/// Parameters:
///  * styledText - an `hs.styledtext` object
///
/// Returns:
///  * a copy of the styledText object
private func string_copy(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theString = get_objectFromUserdata(L, at: 1)
    NSAttributedString_toLua(L, obj: theString.copy() as! NSAttributedString)
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
private func string_identical(_ L: LuaState) throws -> CInt {
    let theString1 = get_objectFromUserdata(L, at: 1)
    let theString2 = get_objectFromUserdata(L, at: 2)
    L.push(theString1.isEqual(to: theString2))
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
private func string_totable(_ L: LuaState) throws -> CInt {

    let theString = get_objectFromUserdata(L, at: 1)
    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, 2) ? 1 : luaL_checkinteger(L, 2)
    let luaJ = lua_isnoneornil(L, 3) ? len : luaL_checkinteger(L, 3)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)

    lua_newtable(L)
    L.push("NSAttributedString"); lua_setfield(L, -2, "__luaSkinType")

    if resolved.empty {
        L.push("")
        lua_rawseti(L, -2, 1)
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        L.push(theString.attributedSubstring(from: theRange).string)
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

            L.push(Int(pS))
            lua_setfield(L, -2, "starts")
            L.push(Int(pE))
            lua_setfield(L, -2, "ends")

            var containsUnsupportedFields = false
            lua_newtable(L)
            for (key, value) in attributes {
                styledtext_attributeValueToLua(L, value)
                if let luaName = luaNameForAttributeKey(key) {
                    lua_setfield(L, -2, luaName)
                } else {
                    containsUnsupportedFields = true
                    lua_setfield(L, -2, key.rawValue)
                }
            }
            lua_setfield(L, -2, "attributes")
            if containsUnsupportedFields {
                L.push(true)
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
private func string_tostring(_ L: LuaState) throws -> CInt {

    let theString = get_objectFromUserdata(L, at: 1)
    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, 2) ? 1 : luaL_checkinteger(L, 2)
    let luaJ = lua_isnoneornil(L, 3) ? len : luaL_checkinteger(L, 3)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)
    if resolved.empty {
        L.push("")
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        L.push(theString.attributedSubstring(from: theRange).string)
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
private func string_setStyleForRange(_ L: LuaState) throws -> CInt {

    let theString = get_objectFromUserdata(L, at: 1)
    let attributes = table_toAttributesDictionary(L, at: 2) as? [NSAttributedString.Key: Any]
    let replaceAttributes = lua_isboolean(L, lua_gettop(L)) ? (lua_toboolean(L, lua_gettop(L)) != 0) : false

    let theMap = luaByteToObjCharMap(theString.string as NSString)
    let len = lua_Integer(theMap.count)

    let luaI = lua_isnoneornil(L, 3) ? 1 : luaL_checkinteger(L, 3)
    let luaJ = lua_isnoneornil(L, 4) ? len : luaL_checkinteger(L, 4)

    let resolved = luaRangeToObjCRange(theMap, len: len, luaI: luaI, luaJ: luaJ)
    if resolved.empty {
        NSAttributedString_toLua(L, obj: theString.copy() as! NSAttributedString)
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
        NSAttributedString_toLua(L, obj: newString)
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
private func string_removeStyleForRange(_ L: LuaState) throws -> CInt {

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
        NSAttributedString_toLua(L, obj: theString.copy() as! NSAttributedString)
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        let newString = theString.mutableCopy() as! NSMutableAttributedString
        for key in attributeKeys {
            newString.removeAttribute(key, range: theRange)
        }
        NSAttributedString_toLua(L, obj: newString)
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
private func string_replaceSubstringForRange(_ L: LuaState) throws -> CInt {

    let theString = get_objectFromUserdata(L, at: 1)
    var withAttributes = (lua_type(L, 2) == LUA_TSTRING || lua_type(L, 2) == LUA_TNUMBER) ? false : true
    if lua_isboolean(L, lua_gettop(L)) {
        withAttributes = lua_toboolean(L, lua_gettop(L)) != 0
    }

    guard let subString = lua_toNSAttributedString(L, at: 2) as? NSAttributedString else {
        throw LuaCallError("bad argument #2 (expected string, table, or styledtext object)")
    }

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
        throw LuaCallError("bad argument #3 (starts index must be < ends index)")
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
    NSAttributedString_toLua(L, obj: newString)

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
private func string_convert(_ L: LuaState) throws -> CInt {
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
                throw LuaCallError("bad argument #2 (unrecognized encoding type)")
            }
        } else {
            throw LuaCallError("bad argument #2 (unrecognized encoding type)")
        }
    }

    do {
        let theResult = try theString.data(from: NSRange(location: 0, length: theString.length),
                                           documentAttributes: [.documentType: dataType])
        lua_pushany(L, theResult as NSData)
    } catch {
        throw LuaCallError("convert: conversion error: \(error.localizedDescription)")
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
private func registerFontByPath(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let path = (lua_tovalue(L, at: 1) as! NSString).expandingTildeInPath
    var errorRef: Unmanaged<CFError>?
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &errorRef)
    if let errorRef = errorRef {
        let error = errorRef.takeRetainedValue() as Error
        L.push(false)
        L.push((error as NSError).localizedDescription)
        return 2
    }
    L.push(true)
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
private func string_upper(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theString = get_objectFromUserdata(L, at: 1)
    let newString = theString.mutableCopy() as! NSMutableAttributedString
    if newString.length > 0 {
        let stringRange = NSRange(location: 0, length: theString.length)
        newString.replaceCharacters(in: stringRange, with: theString.string.uppercased())
        NSAttributedString_toLua(L, obj: newString)
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
private func string_lower(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theString = get_objectFromUserdata(L, at: 1)
    let newString = theString.mutableCopy() as! NSMutableAttributedString
    if newString.length > 0 {
        let stringRange = NSRange(location: 0, length: theString.length)
        newString.replaceCharacters(in: stringRange, with: theString.string.lowercased())
        NSAttributedString_toLua(L, obj: newString)
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
private func string_sub(_ L: LuaState) throws -> CInt {
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
        NSAttributedString_toLua(L, obj: NSAttributedString(string: ""))
    } else {
        let i = resolved.i
        let j = resolved.j
        let theRange = NSRange(location: Int(i - 1), length: Int(j - (i - 1)))
        NSAttributedString_toLua(L, obj: theString.attributedSubstring(from: theRange))
    }
    return 1
}

// MARK: - LuaSkin conversion helpers

// NSAttributedString from userdata, table, or string/number at the specified index
func lua_toNSAttributedString(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
    let absIdx = lua_absindex(L, idx)
    var theString: NSMutableAttributedString?

    if lua_type(L, absIdx) == LUA_TSTRING || lua_type(L, absIdx) == LUA_TNUMBER {
        luaL_tolstring(L, absIdx, nil)
        theString = NSMutableAttributedString(string: lua_tovalue(L, at: -1) as! String)
        lua_pop(L, 1)
    } else if lua_type(L, absIdx) == LUA_TUSERDATA && luaL_testudata(L, absIdx, USERDATA_TAG) != nil {
        theString = get_objectFromUserdata(L, at: absIdx).mutableCopy() as? NSMutableAttributedString
    } else if lua_type(L, absIdx) == LUA_TTABLE {
        lua_rawgeti(L, absIdx, 1)
        luaL_tolstring(L, -1, nil)
        lua_remove(L, -2) // luaL_tolstring pushes its value onto the stack without removing/touching the original
        theString = NSMutableAttributedString(string: lua_tovalue(L, at: -1) as! String)
        lua_pop(L, 1)

        let theMap = luaByteToObjCharMap(theString!.string as NSString)

        var locInTable: lua_Integer = 2
        while lua_rawgeti(L, absIdx, locInTable) != LUA_TNIL {
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
                if let attrs = table_toAttributesDictionary(L, at: -1) as? [NSAttributedString.Key: Any] {
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
    let absIdx = lua_absindex(L, idx)
    let theAttributes = NSMutableDictionary()

    if lua_type(L, absIdx) == LUA_TTABLE {
        if lua_getfield(L, absIdx, "font") == LUA_TTABLE || lua_type(L, -1) == LUA_TSTRING {
            if let font = table_toNSFont(L, at: -1) as? NSFont {
                theAttributes[NSAttributedString.Key.font] = font
            }
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "paragraphStyle") == LUA_TTABLE {
            if let ps = table_toNSParagraphStyle(L, at: -1) as? NSParagraphStyle {
                theAttributes[NSAttributedString.Key.paragraphStyle] = ps
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, absIdx, "underlineStyle") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.underlineStyle] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "superscript") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.superscript] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "ligature") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.ligature] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "strikethroughStyle") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.strikethroughStyle] = NSNumber(value: lua_tointeger(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "baselineOffset") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.baselineOffset] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "kerning") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.kern] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "strokeWidth") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.strokeWidth] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "obliqueness") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.obliqueness] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "expansion") == LUA_TNUMBER {
            theAttributes[NSAttributedString.Key.expansion] = NSNumber(value: lua_tonumber(L, -1))
        }
        lua_pop(L, 1)

        if lua_getfield(L, absIdx, "color") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.foregroundColor] = table_toNSColor(L, -1)
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "backgroundColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.backgroundColor] = table_toNSColor(L, -1)
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "strokeColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.strokeColor] = table_toNSColor(L, -1)
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "underlineColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.underlineColor] = table_toNSColor(L, -1)
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "strikethroughColor") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.strikethroughColor] = table_toNSColor(L, -1)
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "shadow") == LUA_TTABLE {
            theAttributes[NSAttributedString.Key.shadow] = table_toNSShadow(L, at: -1)
        }
        lua_pop(L, 1)
    } else {
        os_log(.error, "%{public}s", "invalid attributes dictionary: expected table, found \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
    }

    return theAttributes
}

@discardableResult
func NSAttributedString_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    guard let theString = obj as? NSAttributedString else {
        lua_pushnil(L)
        return 1
    }
    if lua_pushretainedUserdata(L, theString, metatableName: USERDATA_TAG) {
        return 1
    }
    lua_pushnil(L)
    return 1
}

@discardableResult
private func NSFont_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    guard let theFont = obj as? NSFont else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    lua_pushany(L, theFont.fontName as NSString)
    lua_setfield(L, -2, "name")
    L.push(lua_Number(theFont.pointSize))
    lua_setfield(L, -2, "size")
    L.push("NSFont"); lua_setfield(L, -2, "__luaSkinType")

    return 1
}

private func table_toNSFont(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
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

@discardableResult
private func NSShadow_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let theShadow = obj as! NSShadow
    let offset = theShadow.shadowOffset

    lua_newtable(L)
    lua_newtable(L)
    L.push(lua_Number(offset.height))
    lua_setfield(L, -2, "h")
    L.push(lua_Number(offset.width))
    lua_setfield(L, -2, "w")
    lua_setfield(L, -2, "offset")
    L.push(lua_Number(theShadow.shadowBlurRadius))
    lua_setfield(L, -2, "blurRadius")
    if let color = theShadow.shadowColor {
        NSColor_tolua(L, color)
        lua_setfield(L, -2, "color")
    }
    L.push("NSShadow"); lua_setfield(L, -2, "__luaSkinType")

    return 1
}

private func table_toNSShadow(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
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
            theShadow.shadowColor = table_toNSColor(L, -1) as? NSColor
        }
        lua_pop(L, 1)
    } else {
        os_log(.info, "%{public}s", "invalid shadow object: expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return theShadow
}

@discardableResult
private func NSParagraphStyle_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let thePS = obj as! NSParagraphStyle

    lua_newtable(L)

    switch thePS.alignment {
    case .left:       L.push("left")
    case .right:      L.push("right")
    case .center:     L.push("center")
    case .justified:  L.push("justified")
    case .natural:    L.push("natural")
    @unknown default: L.push("unknown")
    }
    lua_setfield(L, -2, "alignment")

    switch thePS.lineBreakMode {
    case .byWordWrapping:      L.push("wordWrap")
    case .byCharWrapping:      L.push("charWrap")
    case .byClipping:          L.push("clip")
    case .byTruncatingHead:    L.push("truncateHead")
    case .byTruncatingTail:    L.push("truncateTail")
    case .byTruncatingMiddle:  L.push("truncateMiddle")
    @unknown default:          L.push("unknown")
    }
    lua_setfield(L, -2, "lineBreak")

    switch thePS.baseWritingDirection {
    case .natural:      L.push("natural")
    case .leftToRight:  L.push("leftToRight")
    case .rightToLeft:  L.push("rightToLeft")
    @unknown default:   L.push("unknown")
    }
    lua_setfield(L, -2, "baseWritingDirection")

    L.push(lua_Number(thePS.defaultTabInterval))
    lua_setfield(L, -2, "defaultTabInterval")
    L.push(lua_Number(thePS.firstLineHeadIndent))
    lua_setfield(L, -2, "firstLineHeadIndent")
    L.push(lua_Number(thePS.headIndent))
    lua_setfield(L, -2, "headIndent")
    L.push(lua_Number(thePS.tailIndent))
    lua_setfield(L, -2, "tailIndent")
    L.push(lua_Number(thePS.maximumLineHeight))
    lua_setfield(L, -2, "maximumLineHeight")
    L.push(lua_Number(thePS.minimumLineHeight))
    lua_setfield(L, -2, "minimumLineHeight")
    L.push(lua_Number(thePS.lineSpacing))
    lua_setfield(L, -2, "lineSpacing")
    L.push(lua_Number(thePS.paragraphSpacing))
    lua_setfield(L, -2, "paragraphSpacing")
    L.push(lua_Number(thePS.paragraphSpacingBefore))
    lua_setfield(L, -2, "paragraphSpacingBefore")
    L.push(lua_Number(thePS.lineHeightMultiple))
    lua_setfield(L, -2, "lineHeightMultiple")
    L.push(lua_Number(thePS.hyphenationFactor))
    lua_setfield(L, -2, "hyphenationFactor")
    L.push(lua_Number(thePS.tighteningFactorForTruncation))
    lua_setfield(L, -2, "tighteningFactorForTruncation")
    L.push(thePS.allowsDefaultTighteningForTruncation)
    lua_setfield(L, -2, "allowsTighteningForTruncation")

    lua_createtable(L, Int32(thePS.tabStops.count), 0)
    for tabStop in thePS.tabStops {
        NSTextTab_toLua(L, obj: tabStop)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    lua_setfield(L, -2, "tabStops")
    L.push(Int(thePS.headerLevel))
    lua_setfield(L, -2, "headerLevel")
    L.push("NSParagraphStyle"); lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func table_toNSParagraphStyle(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
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
                    if let tab = table_toNSTextTab(L, at: -1) as? NSTextTab {
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

@discardableResult
private func NSTextTab_toLua(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let theTabStop = obj as! NSTextTab
    lua_newtable(L)

    L.push(lua_Number(theTabStop.location))
    lua_setfield(L, -2, "location")

    switch theTabStop.tabStopType {
    case .leftTabStopType:    L.push("left")
    case .rightTabStopType:   L.push("right")
    case .centerTabStopType:  L.push("center")
    case .decimalTabStopType: L.push("decimal")
    @unknown default:         L.push("unknown")
    }
    lua_setfield(L, -2, "tabStopType")
    L.push("NSTextTab"); lua_setfield(L, -2, "__luaSkinType")

    return 1
}

private func table_toNSTextTab(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> AnyObject! {
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

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let title = get_objectFromUserdata(L, at: 1).string
    if title.count > 20 {
        let truncated = String(title.prefix(20))
        L.push("\(USERDATA_TAG): \(truncated)... (\(lua_topointer(L, 1)!))")
    } else {
        L.push("\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
    }
    return 1
}

private func userdata_concat(_ L: LuaState) throws -> CInt {
    if lua_type(L, 1) == LUA_TSTRING || lua_type(L, 1) == LUA_TNUMBER {
        let theString1 = String(cString: lua_tostring(L, 1)!)
        let newString = NSMutableAttributedString(string: theString1)
        newString.append(get_objectFromUserdata(L, at: 2))
        NSAttributedString_toLua(L, obj: newString)
    } else {
        let theString1 = get_objectFromUserdata(L, at: 1)
        let newString = theString1.mutableCopy() as! NSMutableAttributedString
        if lua_type(L, 2) == LUA_TSTRING || lua_type(L, 2) == LUA_TNUMBER {
            let addition = String(cString: lua_tostring(L, 2)!)
            newString.replaceCharacters(in: NSRange(location: newString.length, length: 0), with: addition)
        } else {
            newString.append(get_objectFromUserdata(L, at: 2))
        }
        NSAttributedString_toLua(L, obj: newString)
    }
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    let theString1 = (lua_type(L, 1) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 1).string :
                                                          String(cString: lua_tostring(L, 1)!)
    let theString2 = (lua_type(L, 2) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 2).string :
                                                          String(cString: lua_tostring(L, 2)!)
    L.push(theString1 == theString2)
    return 1
}

private func userdata_lt(_ L: LuaState) throws -> CInt {
    let theString1 = (lua_type(L, 1) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 1).string :
                                                          String(cString: lua_tostring(L, 1)!)
    let theString2 = (lua_type(L, 2) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 2).string :
                                                          String(cString: lua_tostring(L, 2)!)
    L.push((theString1 as NSString).compare(theString2) == .orderedAscending)
    return 1
}

private func userdata_le(_ L: LuaState) throws -> CInt {
    let theString1 = (lua_type(L, 1) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 1).string :
                                                          String(cString: lua_tostring(L, 1)!)
    let theString2 = (lua_type(L, 2) == LUA_TUSERDATA) ? get_objectFromUserdata(L, at: 2).string :
                                                          String(cString: lua_tostring(L, 2)!)
    L.push((theString1 as NSString).compare(theString2) != .orderedDescending)
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
private func userdata_len(_ L: LuaState) throws -> CInt {
    let theString = get_objectFromUserdata(L, at: 1)
    let theMap = luaByteToObjCharMap(theString.string as NSString)
    L.push(Int(theMap.count))
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil {
        let _ = get_objectFromUserdata_transfer(L, at: 1)
        lua_pushnil(L)
        lua_setmetatable(L, 1)
    }
    return 0
}

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libstyledtext")
public func luaopen_hs_libstyledtext(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(string_identical)
        lua_setfield(L, -2, "isIdentical")
        L.push(string_copy)
        lua_setfield(L, -2, "copy")
        L.push(string_totable)
        lua_setfield(L, -2, "asTable")
        L.push(string_tostring)
        lua_setfield(L, -2, "getString")
        L.push(string_setStyleForRange)
        lua_setfield(L, -2, "setStyle")
        L.push(string_removeStyleForRange)
        lua_setfield(L, -2, "removeStyle")
        L.push(string_replaceSubstringForRange)
        lua_setfield(L, -2, "setString")
        L.push(string_convert)
        lua_setfield(L, -2, "convert")
        L.push(userdata_len)
        lua_setfield(L, -2, "len")
        L.push(string_upper)
        lua_setfield(L, -2, "upper")
        L.push(string_lower)
        lua_setfield(L, -2, "lower")
        L.push(string_sub)
        lua_setfield(L, -2, "sub")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_concat)
        lua_setfield(L, -2, "__concat")
        L.push(userdata_len)
        lua_setfield(L, -2, "__len")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_lt)
        lua_setfield(L, -2, "__lt")
        L.push(userdata_le)
        lua_setfield(L, -2, "__le")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for consistency with idiomatic modules
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 14)
        L.push(string_new)
        lua_setfield(L, -2, "new")
        L.push(getStyledTextFromFile)
        lua_setfield(L, -2, "getStyledTextFromFile")
        L.push(getStyledTextFromData)
        lua_setfield(L, -2, "getStyledTextFromData")
        L.push(luaToObjCMap)
        lua_setfield(L, -2, "luaToObjCMap")
        L.push(registerFontByPath)
        lua_setfield(L, -2, "loadFont")
        L.push(font_convertFont)
        lua_setfield(L, -2, "convertFont")
        L.push(validFont)
        lua_setfield(L, -2, "validFont")
        L.push(fontInformation)
        lua_setfield(L, -2, "_fontInfo")
        L.push(fontNames)
        lua_setfield(L, -2, "_fontNames")
        L.push(fontFamilies)
        lua_setfield(L, -2, "_fontFamilies")
        L.push(fontsForFamily)
        lua_setfield(L, -2, "_fontsForFamily")
        L.push(fontNamesWithTraits)
        lua_setfield(L, -2, "_fontNamesWithTraits")
        L.push(fontPath)
        lua_setfield(L, -2, "fontPath")
        L.push(defineDefaultFonts)
        lua_setfield(L, -2, "_defaultFonts")

        fontTraits(L)
        lua_setfield(L, -2, "fontTraits")

        defineLinePatterns(L)
        lua_setfield(L, -2, "linePatterns")
        defineLineStyles(L)
        lua_setfield(L, -2, "lineStyles")
        defineLineAppliesTo(L)
        lua_setfield(L, -2, "lineAppliesTo")
    }
}
