import Cocoa
import CLua
import Lua
import os.log

private let kMaxPasteboardRecursionDepth = 50

// MARK: - Support Functions

private func lua_to_pasteboard(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSPasteboard {
    precondition(L != nil, "lua_State must not be nil")
    if !lua_isnoneornil(L, idx) {
        _ = luaL_checkstring(L, idx) // force number to string
        let name = NSPasteboard.Name(lua_tostringValue(L, at: idx) ?? "")
        return NSPasteboard(name: name)
    } else {
        return NSPasteboard.general
    }
}

private func lua_tableHasAnyField(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ fields: [String]) -> Bool {
    precondition(L != nil, "lua_State must not be nil")
    precondition(!fields.isEmpty, "fields array must not be empty")
    let absIdx = lua_absindex(L, idx)
    for field in fields {
        let hasField = lua_getfield(L, absIdx, field) != LUA_TNIL
        lua_pop(L, 1)
        if hasField { return true }
    }
    return false
}

private func lua_toArchivableObject(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> Any? {
    let absIdx = lua_absindex(L, idx)
    if let image = toNSImage(L, at: absIdx) { return image }
    if let styledText = toNSAttributedString(L, at: absIdx) { return styledText }
    if lua_type(L, absIdx) == LUA_TTABLE &&
        lua_tableHasAnyField(L, absIdx, ["red", "green", "blue", "hue", "saturation", "brightness", "white", "alpha", "hex", "list", "name", "image"]) {
        return table_toNSColor(L, absIdx)
    }
    return lua_tovalue(L, at: absIdx)
}

private func pushPasteboardValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?, depth: Int = 0) {
    precondition(L != nil, "lua_State must not be nil")
    let topBefore = lua_gettop(L)
    defer {
        assert(lua_gettop(L) == topBefore + 1, "pushPasteboardValue must push exactly one value onto the stack")
    }

    if depth >= kMaxPasteboardRecursionDepth {
        os_log(.error, "pushPasteboardValue: recursion depth limit (%d) reached, pushing nil", kMaxPasteboardRecursionDepth)
        lua_pushnil(L)
        return
    }

    guard let value = value else {
        lua_pushnil(L)
        return
    }

    switch value {
    case let image as NSImage:
        // NSImage_tolua pushes either one userdata value or nothing.
        if NSImage_tolua(L, image) == 0 { lua_pushnil(L) }
    case let color as NSColor:
        let top = lua_gettop(L)
        NSColor_tolua(L, color)
        if lua_gettop(L) == top { lua_pushnil(L) }
    case let styledText as NSAttributedString:
        let top = lua_gettop(L)
        NSAttributedString_toLua(L, obj: styledText)
        if lua_gettop(L) == top { lua_pushnil(L) }
    case let array as NSArray:
        lua_createtable(L, Int32(array.count), 0)
        for (index, item) in array.enumerated() {
            pushPasteboardValue(L, item, depth: depth + 1)
            lua_rawseti(L, -2, lua_Integer(index + 1))
        }
    case let dict as NSDictionary:
        lua_createtable(L, 0, Int32(dict.count))
        for (key, val) in dict {
            lua_pushany(L, key)
            pushPasteboardValue(L, val, depth: depth + 1)
            lua_settable(L, -3)
        }
    default:
        let top = lua_gettop(L)
        lua_pushany(L, value)
        if lua_gettop(L) == top {
            lua_pushnil(L)
        }
    }
}

// MARK: - Module Functions

/// hs.pasteboard.getContents([name]) -> string or nil
/// Function
/// Gets the contents of the pasteboard
///
/// Parameters:
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard
///
/// Returns:
///  * A string containing the contents of the pasteboard, or nil if an error occurred
private func pasteboard_getContents(_ L: LuaState) throws -> CInt {
    let str = lua_to_pasteboard(L, 1).string(forType: .string)
    if let str = str {
        L.push(str)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.setContents(contents[, name]) -> boolean
/// Function
/// Sets the contents of the pasteboard
///
/// Parameters:
///  * contents - A string to be placed in the pasteboard
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard
///
/// Returns:
///  * True if the operation succeeded, otherwise false
private func pasteboard_setContents(_ L: LuaState) throws -> CInt {
    let thePasteboard = lua_to_pasteboard(L, 2)

    luaL_tolstring(L, 1, nil)
    var len: Int = 0
    let ptr = lua_tolstring(L, -1, &len)
    thePasteboard.clearContents()
    var result = false
    if let ptr = ptr, len > 0 {
        let data = Data(bytes: ptr, count: len)
        if let str = String(data: data, encoding: .utf8) {
            result = thePasteboard.setString(str, forType: .string)
        } else {
            result = thePasteboard.setData(data, forType: .string)
        }
    }

    L.push(result)
    return 1
}

/// hs.pasteboard.clearContents([name])
/// Function
/// Clear the contents of the pasteboard
///
/// Parameters:
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard
///
/// Returns:
///  * None
private func pasteboard_clearContents(_ L: LuaState) throws -> CInt {
    let thePasteboard = lua_to_pasteboard(L, 1)
    thePasteboard.clearContents()
    return 0
}

/// hs.pasteboard.pasteboardTypes([name]) -> table
/// Function
/// Return the pasteboard type identifier strings for the specified pasteboard.
///
/// Parameters:
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard
///
/// Returns:
///  * a table containing the pasteboard type identifier strings
private func pasteboard_pasteboardTypes(_ L: LuaState) throws -> CInt {
    let thePasteboard = lua_to_pasteboard(L, 1)

    lua_newtable(L)
    if let types = thePasteboard.types {
        for type in types {
            L.push(type.rawValue)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }

    return 1
}

/// hs.pasteboard.contentTypes([name]) -> table
/// Function
/// Return the UTI strings of the data types for the first pasteboard item on the specified pasteboard.
///
/// Parameters:
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard
///
/// Returns:
///  * a table containing the UTI strings of the data types for the first pasteboard item.
private func pasteboard_pasteboardItemTypes(_ L: LuaState) throws -> CInt {
    let thePasteboard = lua_to_pasteboard(L, 1)

    lua_newtable(L)
    // make sure there is something on the pasteboard...
    if let items = thePasteboard.pasteboardItems, items.count > 0 {
        let item = items[0]
        for type in item.types {
            L.push(type.rawValue)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    return 1
}

/// hs.pasteboard.changeCount([name]) -> number
/// Function
/// Gets the number of times the pasteboard owner has changed
///
/// Parameters:
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard
///
/// Returns:
///  * A number containing a count of the times the pasteboard owner has changed
///
/// Notes:
///  * This is useful for seeing if the pasteboard has been updated by another process
private func pasteboard_changeCount(_ L: LuaState) throws -> CInt {
    L.push(lua_Integer(lua_to_pasteboard(L, 1).changeCount))
    return 1
}

/// hs.pasteboard.deletePasteboard(name)
/// Function
/// Deletes a custom pasteboard
///
/// Parameters:
///  * name - A string containing the name of the pasteboard
///
/// Returns:
///  * None
///
/// Notes:
///  * You can not delete the system pasteboard, this function should only be called on custom pasteboards you have created
private func pasteboard_delete(_ L: LuaState) throws -> CInt {
// prevents nil from being specified
    _ = luaL_checkstring(L, 1) // coerce number to string
    let pbName = lua_tostringValue(L, at: 1) ?? ""
    let systemNames: [NSPasteboard.Name] = [.general, .font, .ruler, .find, .drag]
    for sysName in systemNames {
        if pbName == sysName.rawValue {
            throw LuaCallError("cannot delete a system pasteboard")
        }
    }

    let thePasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: pbName))
    thePasteboard.releaseGlobally()
    return 0
}

// MARK: - Experimental and WhatFors

/// hs.pasteboard.allContentTypes([name]) -> table
/// Function
/// An array whose elements are a table containing the content types for each element on the clipboard.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///
/// Returns:
///  * an array with each index representing an object on the pasteboard.  If the pasteboard contains only one element, this is equivalent to `{ hs.pasteboard.contentTypes(name) }`.
private func allPBItemTypes(_ L: LuaState) throws -> CInt {
    let thePasteboard = lua_to_pasteboard(L, 1)
    lua_newtable(L)
    if let items = thePasteboard.pasteboardItems {
        for item in items {
            lua_newtable(L)
            for type in item.types {
                lua_pushany(L, type.rawValue as NSString)
                lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            }
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    return 1
}

/// hs.pasteboard.readString([name], [all]) -> string or array of strings
/// Function
/// Returns one or more strings from the clipboard, or nil if no compatible objects are present.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * all  - an optional boolean indicating whether or not all (true) of the urls on the clipboard should be returned, or just the first (false).  Defaults to false.
///
/// Returns:
///  * By default the first string on the clipboard, or a table of all strings on the clipboard if the `all` parameter is provided and set to true.  Returns nil if no strings are present.
///
/// Notes:
///  * almost all string and styledText objects are internally convertible and will be available with this method as well as [hs.pasteboard.readStyledText](#readStyledText). If the item is actually an `hs.styledtext` object, the string will be just the text of the object.
private func readStringObjects(_ L: LuaState) throws -> CInt {

    var pb: NSPasteboard
    var getAll = false

    if lua_gettop(L) >= 1 && lua_isboolean(L, -1) {
        getAll = lua_toboolean(L, -1) != 0
        lua_pop(L, 1)
    }
    if lua_gettop(L) >= 1 {
        if lua_isboolean(L, 1) {
            throw LuaCallError("bad argument #1 (string or nil expected)")
        }
        pb = lua_to_pasteboard(L, 1)
    } else {
        pb = NSPasteboard.general
    }

    let results = pb.readObjects(forClasses: [NSString.self], options: [:])
    if let results = results, !results.isEmpty {
        if getAll {
            lua_pushany(L, results as NSArray)
        } else {
            lua_pushany(L, results.first as? NSObject)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readDataForUTI([name], uti) -> string
/// Function
/// Returns the first item on the pasteboard with the specified UTI as raw data
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * uti  - a string specifying the UTI of the pasteboard item to retrieve.
///
/// Returns:
///  * a lua string containing the raw data of the specified pasteboard item
///
/// Notes:
///  * The UTI's of the items on the pasteboard can be determined with the [hs.pasteboard.allContentTypes](#allContentTypes) and [hs.pasteboard.contentTypes](#contentTypes) functions.
private func readItemForType(_ L: LuaState) throws -> CInt {
    var pb: NSPasteboard
    var type: String
    if lua_gettop(L) == 1 {
        luaL_checktype(L, 1, LUA_TSTRING)
        pb = NSPasteboard.general
        type = lua_tovalue(L, at: 1) as! String
    } else {
        pb = lua_to_pasteboard(L, 1)
        type = lua_tovalue(L, at: 2) as! String
    }
    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
    if let data = pb.data(forType: pasteboardType) {
        lua_pushany(L, data as NSData)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readPListForUTI([name], uti) -> any
/// Function
/// Returns the first item on the pasteboard with the specified UTI as a property list item
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * uti  - a string specifying the UTI of the pasteboard item to retrieve.
///
/// Returns:
///  * a lua item representing the property list value of the pasteboard item specified
///
/// Notes:
///  * The UTI's of the items on the pasteboard can be determined with the [hs.pasteboard.allContentTypes](#allContentTypes) and [hs.pasteboard.contentTypes](#contentTypes) functions.
///  * Property lists consist only of certain types of data: tables, strings, numbers, dates, binary data, and Boolean values.
private func readPropertyListForType(_ L: LuaState) throws -> CInt {
    var pb: NSPasteboard
    var type: String
    if lua_gettop(L) == 1 {
        luaL_checktype(L, 1, LUA_TSTRING)
        pb = NSPasteboard.general
        type = lua_tovalue(L, at: 1) as! String
    } else {
        pb = lua_to_pasteboard(L, 1)
        type = lua_tovalue(L, at: 2) as! String
    }
    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
    if let plist = pb.propertyList(forType: pasteboardType) as? NSObject {
        lua_pushany(L, plist)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readArchiverDataForUTI([name], uti) -> any
/// Function
/// Returns the first item on the pasteboard with the specified UTI. The data on the pasteboard must be encoded as a keyed archive object conforming to NSKeyedArchiver.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * uti  - a string specifying the UTI of the pasteboard item to retrieve.
///
/// Returns:
///  * a lua item representing the archived data if it can be decoded. Generates an error if the data is in the wrong format.
///
/// Notes:
///  * NSKeyedArchiver specifies an architecture-independent format that is often used in OS X applications to store and transmit objects between applications and when storing data to a file. It works by recording information about the object types and key-value pairs which make up the objects being stored.
///  * Only objects which have conversion functions built into Cosmic Hammer can be converted. A string representation describing unrecognized types wil be returned. If you find a common data type that you believe may be of interest to Cosmic Hammer users, feel free to contribute a conversion function or make a request in the Cosmic Hammer Google group or GitHub site.
///  * Some applications may define their own classes which can be archived.  Cosmic Hammer will be unable to recognize these types if the application does not make the object type available in one of its frameworks.  You *may* be able to load the necessary framework with `package.loadlib("/Applications/appname.app/Contents/Frameworks/frameworkname.framework/frameworkname", "*")` before retrieving the data, but a full representation of the data in Cosmic Hammer is probably not possible without support from the Application's developers.
private func readArchivedDataForType(_ L: LuaState) throws -> CInt {
    var pb: NSPasteboard
    var type: String
    if lua_gettop(L) == 1 {
        luaL_checktype(L, 1, LUA_TSTRING)
        pb = NSPasteboard.general
        type = lua_tovalue(L, at: 1) as! String
    } else {
        pb = lua_to_pasteboard(L, 1)
        type = lua_tovalue(L, at: 2) as! String
    }
    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
    guard let holding = pb.data(forType: pasteboardType) else {
        throw LuaCallError("unable to get data for specified type")
    }
    let allowedClasses: [AnyClass] = [
        NSString.self,
        NSAttributedString.self,
        NSNumber.self,
        NSDate.self,
        NSData.self,
        NSArray.self,
        NSDictionary.self,
        NSColor.self,
        NSImage.self,
        NSSound.self,
        NSURL.self,
    ]
    do {
        let realItem = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: allowedClasses,
            from: holding
        )
        pushPasteboardValue(L, realItem)
    } catch {
        throw LuaCallError(error.localizedDescription)
    }
    return 1
}

/// hs.pasteboard.writeArchiverDataForUTI([name], uti, data, [add]) -> boolean
/// Function
/// Sets the pasteboard to the contents of the data and assigns its type to the specified UTI. The data will be encoded as an archive conforming to NSKeyedArchiver.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * uti  - a string specifying the UTI of the pasteboard item to set.
///  * data - any type representable in Lua which will be converted into the appropriate NSObject types and archived with NSKeyedArchiver.  All Lua basic types are supported as well as those NSObject types handled by Cosmic Hammer modules (NSColor, NSStyledText, NSImage, etc.)
///  * add  - an optional boolean value specifying if data with other UTI values should retain.  This value must be strictly either true or false if given, to avoid ambiguity with preceding parameters.
///
/// Returns:
///  * True if the operation succeeded, otherwise false (which most likely means ownership of the pasteboard has changed)
///
/// Notes:
///  * NSKeyedArchiver specifies an architecture-independent format that is often used in OS X applications to store and transmit objects between applications and when storing data to a file. It works by recording information about the object types and key-value pairs which make up the objects being stored.
///  * Only objects which have conversion functions built into Cosmic Hammer can be converted.
///  * A full list of NSObjects supported directly by Cosmic Hammer is planned in a future Wiki article.
private func writeArchivedDataForType(_ L: LuaState) throws -> CInt {
    var pb: NSPasteboard
    var add = false
    var type: String
    var data: Any?

    if lua_gettop(L) >= 3 {
        if lua_isboolean(L, -1) {
            add = lua_toboolean(L, -1) != 0
            lua_settop(L, lua_gettop(L) - 1)
        } else if lua_isnil(L, -1) {
            lua_settop(L, lua_gettop(L) - 1)
        }
    }
    if lua_gettop(L) == 2 {
        pb = NSPasteboard.general
        type = lua_tovalue(L, at: 1) as! String
        data = lua_toArchivableObject(L, at: 2)
    } else {
        pb = lua_to_pasteboard(L, 1)
        type = lua_tovalue(L, at: 2) as! String
        data = lua_toArchivableObject(L, at: 3)
    }
    guard let data = data else {
        throw LuaCallError("unable to evaluate data string")
    }
    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
    do {
        let encoded = try NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: false)
        if !add {
            pb.clearContents()
        }
        L.push(pb.setData(encoded, forType: pasteboardType))
    } catch {
        throw LuaCallError(error.localizedDescription)
    }
    return 1
}

/// hs.pasteboard.writeDataForUTI([name], uti, data, [add]) -> boolean
/// Function
/// Sets the pasteboard to the contents of the data and assigns its type to the specified UTI.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * uti  - a string specifying the UTI of the pasteboard item to set.
///  * data - a string specifying the raw data to assign to the pasteboard.
///  * add  - an optional boolean value specifying if data with other UTI values should retain.  This value must be strictly either true or false if given, to avoid ambiguity with preceding parameters.
///
/// Returns:
///  * True if the operation succeeded, otherwise false (which most likely means ownership of the pasteboard has changed)
///
/// Notes:
///  * The UTI's of the items on the pasteboard can be determined with the [hs.pasteboard.allContentTypes](#allContentTypes) and [hs.pasteboard.contentTypes](#contentTypes) functions.
private func writeItemForType(_ L: LuaState) throws -> CInt {
    var pb: NSPasteboard
    var add = false
    var type: String
    var data: Data?

    if lua_gettop(L) >= 3 {
        if lua_isboolean(L, -1) {
            add = lua_toboolean(L, -1) != 0
            lua_settop(L, lua_gettop(L) - 1)
        } else if lua_isnil(L, -1) {
            lua_settop(L, lua_gettop(L) - 1)
        }
    }
    if lua_gettop(L) == 2 {
        pb = NSPasteboard.general
        type = lua_tovalue(L, at: 1) as! String
        data = lua_todata(L, at: 2)
    } else {
        pb = lua_to_pasteboard(L, 1)
        type = lua_tovalue(L, at: 2) as! String
        data = lua_todata(L, at: 3)
    }
    guard let data = data else {
        throw LuaCallError("unable to evaluate data string")
    }
    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
    if !add {
        pb.clearContents()
    }
    L.push(pb.setData(data, forType: pasteboardType))
    return 1
}

/// hs.pasteboard.writePListForUTI([name], uti, data, [add]) -> boolean
/// Function
/// Sets the pasteboard to the contents of the data and assigns its type to the specified UTI.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * uti  - a string specifying the UTI of the pasteboard item to set.
///  * data - a lua type which can be represented as a property list value.
///  * add  - an optional boolean value specifying if data with other UTI values should retain.  This value must be strictly either true or false if given, to avoid ambiguity with preceding parameters.
///
/// Returns:
///  * True if the operation succeeded, otherwise false (which most likely means ownership of the pasteboard has changed)
///
/// Notes:
///  * The UTI's of the items on the pasteboard can be determined with the [hs.pasteboard.allContentTypes](#allContentTypes) and [hs.pasteboard.contentTypes](#contentTypes) functions.
///  * Property lists consist only of certain types of data: tables, strings, numbers, dates, binary data, and Boolean values.
private func writePropertyListForType(_ L: LuaState) throws -> CInt {
    var pb: NSPasteboard
    var add = false
    var type: String
    var data: Any?

    if lua_gettop(L) >= 3 {
        if lua_isboolean(L, -1) {
            add = lua_toboolean(L, -1) != 0
            lua_settop(L, lua_gettop(L) - 1)
        } else if lua_isnil(L, -1) {
            lua_settop(L, lua_gettop(L) - 1)
        }
    }
    if lua_gettop(L) == 2 {
        pb = NSPasteboard.general
        type = lua_tovalue(L, at: 1) as! String
        data = lua_tovalue(L, at: 2)
    } else {
        pb = lua_to_pasteboard(L, 1)
        type = lua_tovalue(L, at: 2) as! String
        data = lua_tovalue(L, at: 3)
    }
    guard let data = data else {
        throw LuaCallError("unable to evaluate data string")
    }
    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
    if !add {
        pb.clearContents()
    }
    L.push(pb.setPropertyList(data, forType: pasteboardType))
    return 1
}

/// hs.pasteboard.readStyledText([name], [all]) -> hs.styledtext object or array of hs.styledtext objects
/// Function
/// Returns one or more `hs.styledtext` objects from the clipboard, or nil if no compatible objects are present.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * all  - an optional boolean indicating whether or not all (true) of the urls on the clipboard should be returned, or just the first (false).  Defaults to false.
///
/// Returns:
///  * By default the first styledtext object on the clipboard, or a table of all styledtext objects on the clipboard if the `all` parameter is provided and set to true.  Returns nil if no styledtext objects are present.
///
/// Notes:
///  * almost all string and styledText objects are internally convertible and will be available with this method as well as [hs.pasteboard.readString](#readString). If the item on the clipboard is actually just a string, the `hs.styledtext` object representation will have no attributes set
private func readAttributedStringObjects(_ L: LuaState) throws -> CInt {

    var pb: NSPasteboard
    var getAll = false

    if lua_gettop(L) >= 1 && lua_isboolean(L, -1) {
        getAll = lua_toboolean(L, -1) != 0
        lua_pop(L, 1)
    }
    if lua_gettop(L) >= 1 {
        if lua_isboolean(L, 1) {
            throw LuaCallError("bad argument #1 (string or nil expected)")
        }
        pb = lua_to_pasteboard(L, 1)
    } else {
        pb = NSPasteboard.general
    }

    let results = pb.readObjects(forClasses: [NSAttributedString.self], options: [:])
    if let results = results, !results.isEmpty {
        if getAll {
            pushPasteboardValue(L, results as NSArray)
        } else {
            pushPasteboardValue(L, results.first)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readSound([name], [all]) -> hs.sound object or array of hs.sound objects
/// Function
/// Returns one or more `hs.sound` objects from the clipboard, or nil if no compatible objects are present.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * all  - an optional boolean indicating whether or not all (true) of the urls on the clipboard should be returned, or just the first (false).  Defaults to false.
///
/// Returns:
///  * By default the first sound on the clipboard, or a table of all sounds on the clipboard if the `all` parameter is provided and set to true.  Returns nil if no sounds are present.
private func readSoundObjects(_ L: LuaState) throws -> CInt {

    var pb: NSPasteboard
    var getAll = false

    if lua_gettop(L) >= 1 && lua_isboolean(L, -1) {
        getAll = lua_toboolean(L, -1) != 0
        lua_pop(L, 1)
    }
    if lua_gettop(L) >= 1 {
        if lua_isboolean(L, 1) {
            throw LuaCallError("bad argument #1 (string or nil expected)")
        }
        pb = lua_to_pasteboard(L, 1)
    } else {
        pb = NSPasteboard.general
    }

    let results = pb.readObjects(forClasses: [NSSound.self], options: [:])
    if let results = results, !results.isEmpty {
        if getAll {
            lua_pushany(L, results as NSArray)
        } else {
            lua_pushany(L, results.first as? NSObject)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readImage([name], [all]) -> hs.image object or array of hs.image objects
/// Function
/// Returns one or more `hs.image` objects from the clipboard, or nil if no compatible objects are present.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * all  - an optional boolean indicating whether or not all (true) of the urls on the clipboard should be returned, or just the first (false).  Defaults to false.
///
/// Returns:
///  * By default the first image on the clipboard, or a table of all images on the clipboard if the `all` parameter is provided and set to true.  Returns nil if no images are present.
private func readImageObjects(_ L: LuaState) throws -> CInt {

    var pb: NSPasteboard
    var getAll = false

    if lua_gettop(L) >= 1 && lua_isboolean(L, -1) {
        getAll = lua_toboolean(L, -1) != 0
        lua_pop(L, 1)
    }
    if lua_gettop(L) >= 1 {
        if lua_isboolean(L, 1) {
            throw LuaCallError("bad argument #1 (string or nil expected)")
        }
        pb = lua_to_pasteboard(L, 1)
    } else {
        pb = NSPasteboard.general
    }

    let results = pb.readObjects(forClasses: [NSImage.self], options: [:])
    if let results = results, !results.isEmpty {
        if getAll {
            pushPasteboardValue(L, results as NSArray)
        } else {
            pushPasteboardValue(L, results.first)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readURL([name], [all]) -> string or array of strings representing file or resource urls
/// Function
/// Returns one or more strings representing file or resource urls from the clipboard, or nil if no compatible objects are present.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * all  - an optional boolean indicating whether or not all (true) of the urls on the clipboard should be returned, or just the first (false).  Defaults to false.
///
/// Returns:
///  * By default the first url on the clipboard, or a table of all urls on the clipboard if the `all` parameter is provided and set to true.  Returns nil if no urls are present.
private func readURLObjects(_ L: LuaState) throws -> CInt {

    var pb: NSPasteboard
    var getAll = false

    if lua_gettop(L) >= 1 && lua_isboolean(L, -1) {
        getAll = lua_toboolean(L, -1) != 0
        lua_pop(L, 1)
    }
    if lua_gettop(L) >= 1 {
        if lua_isboolean(L, 1) {
            throw LuaCallError("bad argument #1 (string or nil expected)")
        }
        pb = lua_to_pasteboard(L, 1)
    } else {
        pb = NSPasteboard.general
    }

    let results = pb.readObjects(forClasses: [NSURL.self], options: [:])
    if let results = results, !results.isEmpty {
        if getAll {
            lua_pushany(L, results as NSArray)
        } else {
            lua_pushany(L, results.first as? NSObject)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.pasteboard.readColor([name], [all]) -> hs.drawing.color table or array of hs.drawing.color tables
/// Function
/// Returns one or more `hs.drawing.color` tables from the clipboard, or nil if no compatible objects are present.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///  * all  - an optional boolean indicating whether or not all (true) of the colors on the clipboard should be returned, or just the first (false).  Defaults to false.
///
/// Returns:
///  * By default the first color on the clipboard, or a table of all colors on the clipboard if the `all` parameter is provided and set to true.  Returns nil if no colors are present.
private func readColorObjects(_ L: LuaState) throws -> CInt {

    var pb: NSPasteboard
    var getAll = false

    if lua_gettop(L) >= 1 && lua_isboolean(L, -1) {
        getAll = lua_toboolean(L, -1) != 0
        lua_pop(L, 1)
    }
    if lua_gettop(L) >= 1 {
        if lua_isboolean(L, 1) {
            throw LuaCallError("bad argument #1 (string or nil expected)")
        }
        pb = lua_to_pasteboard(L, 1)
    } else {
        pb = NSPasteboard.general
    }

    let results = pb.readObjects(forClasses: [NSColor.self], options: [:])
    if let results = results, !results.isEmpty {
        if getAll {
            pushPasteboardValue(L, results as NSArray)
        } else {
            pushPasteboardValue(L, results.first)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func convertToPasteboardWritableObject(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSPasteboardWriting? {
    precondition(L != nil, "lua_State must not be nil")
    let absIdx = lua_absindex(L, idx)
    assert(absIdx > 0, "absolute index must be positive")
    let luaType = lua_type(L, absIdx)
    if luaType == LUA_TSTRING || luaType == LUA_TNUMBER {
        luaL_tolstring(L, absIdx, nil) // force number to be a string, but don't change value in stack
        let object = lua_tostringValue(L, at: -1).map { $0 as NSString }
        lua_pop(L, 1)
        return object
    } else if luaType == LUA_TTABLE {
        if lua_getfield(L, absIdx, "url") != LUA_TNIL {
            if lua_type(L, -1) == LUA_TSTRING {
                let urlStr = lua_tovalue(L, at: -1) as! String
                lua_pop(L, 1)
                return NSURL(string: urlStr)
            } else {
                lua_pop(L, 1)
                os_log(.error, "%{public}s", "url must be a table containing a url key with a string value")
                return nil
            }
        }
        lua_pop(L, 1) // the nil value from the url key check above
        if lua_tableHasAnyField(L, absIdx, ["red", "green", "blue", "hue", "saturation", "brightness", "white", "alpha", "hex", "list", "name", "image"]) {
            guard let color = table_toNSColor(L, absIdx) as? NSColor else {
                os_log(.error, "%{public}s", "table looks like a color but could not be converted")
                return nil
            }
            return color
        }
        os_log(.error, "%{public}s", "table must be a color table or contain a url key")
        return nil
    } else if let image = toNSImage(L, at: absIdx) {
        return image
    } else if let styledText = toNSAttributedString(L, at: absIdx) {
        return styledText
    } else if luaL_testudata(L, absIdx, "hs.sound") != nil {
        return lua_toAnyObject(L, at: absIdx) as? NSPasteboardWriting
    } else {
        os_log(.error, "%{public}s", "expected string, number, hs.image, hs.sound, hs.styledtext, color table or url table")
        return nil
    }
}

/// hs.pasteboard.writeObjects(object, [name]) -> boolean
/// Function
/// Sets the pasteboard contents to the object or objects specified.
///
/// Parameters:
///  * object - an object or table of objects to set the pasteboard to.  The following objects are recognized:
///    * a lua string, which can be received by most applications that can accept text from the clipboard
///    * `hs.styledtext` object, which can be received by most applications that can accept a raw NSAttributedString (often converted internally to RTF, RTFD, HTML, etc.)
///    * `hs.sound` object, which can be received by most applications that can accept a raw NSSound object
///    * `hs.image` object, which can be received by most applications that can accept a raw NSImage object
///    * a table with the `url` key and value representing a file or resource url, which can be received by most applications that can accept an NSURL object to represent a file or a remote resource
///    * a table with keys as described in `hs.drawing.color` to represent a color, which can be received by most applications that can accept a raw NSColor object
///    * an array of one or more of the above objects, allowing you to place more than one object onto the clipboard.
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///
/// Returns:
///  * true or false indicating whether or not the clipboard contents were updated.
///
/// Notes:
///  * Most applications can only receive the first item on the clipboard.  Multiple items on a clipboard are most often used for intra-application communication where the sender and receiver are specifically written with multiple objects in mind.
private func writeObjects(_ L: LuaState) throws -> CInt {
    var pboard: NSPasteboard
    if lua_gettop(L) == 1 {        pboard = NSPasteboard.general
    } else {
        pboard = lua_to_pasteboard(L, 2)
    }

    var objects: [NSPasteboardWriting] = []
    if lua_type(L, 1) != LUA_TTABLE ||
       (lua_type(L, 1) == LUA_TTABLE && luaL_len(L, 1) == 0) {
        guard let obj = convertToPasteboardWritableObject(L, 1) else {
            throw LuaCallError("writeObjects error")
        }
        objects.append(obj)
    } else {
        let count = luaL_len(L, 1)
        for i in 0..<count {
            lua_rawgeti(L, 1, lua_Integer(i + 1))
            guard let obj = convertToPasteboardWritableObject(L, -1) else {
                lua_pop(L, 1)
                throw LuaCallError("writeObjects error at index \(i + 1)")
            }
            lua_pop(L, 1)
            objects.append(obj)
        }
    }
    // got objects
    pboard.clearContents()
    L.push(pboard.writeObjects(objects))
    return 1
}

/// hs.pasteboard.uniquePasteboard() -> string
/// Function
/// Returns the name of a new pasteboard with a name that is guaranteed to be unique with respect to other pasteboards on the computer.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a unique pasteboard name
///
/// Notes:
///  * to properly manage system resources, you should release the created pasteboard with [hs.pasteboard.deletePasteboard](#deletePasteboard) when you are certain that it is no longer necessary.
private func newUniquePasteboard(_ L: LuaState) throws -> CInt {
    let name = NSPasteboard.withUniqueName().name
    lua_pushany(L, name.rawValue as NSString)
    return 1
}

/// hs.pasteboard.typesAvailable([name]) -> table
/// Function
/// Returns a table indicating what content types are available on the pasteboard.
///
/// Parameters:
///  * name - an optional string indicating the pasteboard name.  If nil or not present, defaults to the system pasteboard.
///
/// Returns:
///  * a table which may contain any of the following keys set to the value true:
///    * string     - at least one element which can be represented as a string is on the pasteboard
///    * styledText - at least one element which can be represented as an `hs.styledtext` object is on the pasteboard
///    * sound      - at least one element which can be represented as an `hs.sound` object is on the pasteboard
///    * image      - at least one element which can be represented as an `hs.image` object is on the pasteboard
///    * URL        - at least one element on the pasteboard represents a URL, either to a local file or a remote resource
///    * color      - at least one element on the pasteboard represents a color, representable as a table as described in `hs.drawing.color`
///
/// Notes:
///  * almost all string and styledText objects are internally convertible and will return true for both keys
///    * if the item on the clipboard is actually just a string, the `hs.styledtext` object representation will have no attributes set
///    * if the item is actually an `hs.styledtext` object, the string representation will be the text without any attributes.
private func typesOnPasteboard(_ L: LuaState) throws -> CInt {
    let pboard = lua_to_pasteboard(L, 1)
    lua_newtable(L)
    if pboard.canReadObject(forClasses: [NSString.self], options: [:]) {
        L.push(true); lua_setfield(L, -2, "string")
    }
    if pboard.canReadObject(forClasses: [NSAttributedString.self], options: [:]) {
        L.push(true); lua_setfield(L, -2, "styledText")
    }
    if pboard.canReadObject(forClasses: [NSSound.self], options: [:]) {
        L.push(true); lua_setfield(L, -2, "sound")
    }
    if pboard.canReadObject(forClasses: [NSImage.self], options: [:]) {
        L.push(true); lua_setfield(L, -2, "image")
    }
    if pboard.canReadObject(forClasses: [NSURL.self], options: [:]) {
        L.push(true); lua_setfield(L, -2, "URL")
    }
    if pboard.canReadObject(forClasses: [NSColor.self], options: [:]) {
        L.push(true); lua_setfield(L, -2, "color")
    }
    return 1
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libpasteboard")
public func luaopen_hs_libpasteboard(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "lua_State must not be nil")
    return runEntryPoint(L) { L in
        lua_createtable(L, 0, 22)
        L.push( pasteboard_changeCount)
        lua_setfield(L, -2, "changeCount")
        L.push( pasteboard_clearContents)
        lua_setfield(L, -2, "clearContents")
        L.push( pasteboard_delete)
        lua_setfield(L, -2, "deletePasteboard")
        L.push( pasteboard_getContents)
        lua_setfield(L, -2, "getContents")
        L.push( pasteboard_setContents)
        lua_setfield(L, -2, "setContents")
        L.push( pasteboard_pasteboardTypes)
        lua_setfield(L, -2, "pasteboardTypes")
        L.push( pasteboard_pasteboardItemTypes)
        lua_setfield(L, -2, "contentTypes")
        L.push( allPBItemTypes)
        lua_setfield(L, -2, "allContentTypes")
        L.push( newUniquePasteboard)
        lua_setfield(L, -2, "uniquePasteboard")
        L.push( typesOnPasteboard)
        lua_setfield(L, -2, "typesAvailable")
        L.push( readStringObjects)
        lua_setfield(L, -2, "readString")
        L.push( readAttributedStringObjects)
        lua_setfield(L, -2, "readStyledText")
        L.push( readSoundObjects)
        lua_setfield(L, -2, "readSound")
        L.push( readImageObjects)
        lua_setfield(L, -2, "readImage")
        L.push( readURLObjects)
        lua_setfield(L, -2, "readURL")
        L.push( readColorObjects)
        lua_setfield(L, -2, "readColor")
        L.push( writeObjects)
        lua_setfield(L, -2, "writeObjects")
        L.push( readItemForType)
        lua_setfield(L, -2, "readDataForUTI")
        L.push( writeItemForType)
        lua_setfield(L, -2, "writeDataForUTI")
        L.push( readPropertyListForType)
        lua_setfield(L, -2, "readPListForUTI")
        L.push( writePropertyListForType)
        lua_setfield(L, -2, "writePListForUTI")
        L.push( readArchivedDataForType)
        lua_setfield(L, -2, "readArchiverDataForUTI")
        L.push( writeArchivedDataForType)
        lua_setfield(L, -2, "writeArchiverDataForUTI")
    }
}
