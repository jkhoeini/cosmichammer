import Cocoa
import LuaSkin

/// hs.plist.read(filepath) -> table
/// Function
/// Loads a Property List file
///
/// Parameters:
///  * filepath - The path and filename of a plist file to read
///
/// Returns:
///  * The contents of the plist as a Lua table
private func plist_read(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let filePath = (skin.toNSObject(atIndex: 1) as! NSString).expandingTildeInPath
    let plist = NSDictionary(contentsOfFile: filePath)
    skin.pushNSObject(plist)

    return 1
}

/// hs.plist.readString(value, [binary]) -> table | nil
/// Function
/// Interprets a property list file within a string into a table.
///
/// Parameters:
///  * value  - The contents of the property list as a string
///  * binary - an optional boolean, specifying whether the value should be treated as raw binary (true) or as an UTF8 encoded string (false). If you do not provide this argument, the function will attempt to auto-detect the type.
///
/// Returns:
///  * The contents of the property list as a Lua table or `nil` if an error occurs
private func plist_readString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let source = skin.toNSObject(atIndex: 1) as! NSString
    let binary: Bool
    if lua_gettop(L) > 1 {
        binary = lua_toboolean(L, 2) != 0
    } else {
        binary = source.hasPrefix("bplist")
    }

    let plistData: Data
    if binary {
        plistData = skin.toNSObject(atIndex: 1, withOptions: LS_NSConversionOptions.nsLuaStringAsDataOnly) as! Data
    } else {
        plistData = (source as String).data(using: .utf8)!
    }

    do {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: .mutableContainersAndLeaves,
            format: &format
        )
        skin.pushNSObject(plist as? NSObject)
    } catch {
        skin.logError("hs.plist.readString(): \(error)")
        lua_pushnil(L)
    }

    return 1
}

/// hs.plist.writeString(data, [binary]) -> string | nil
/// Function
/// Interprets a property list file within a string into a table.
///
/// Parameters:
///  * data - A Lua table containing the data to write into a plist string
///  * binary - an optional boolean, default false, specifying that the resulting string should be encoded as a binary plist.
///
/// Returns:
///  * A string representing the data as a plist or nil if there was a problem with the date or serialization.
private func plist_writeString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let data = skin.toNSObject(atIndex: 1, withOptions: LS_NSConversionOptions.nsPreserveLuaStringExactly)!
    let binary = lua_gettop(L) > 1 ? (lua_toboolean(L, 2) != 0) : false
    let format: PropertyListSerialization.PropertyListFormat = binary ? .binary : .xml

    if !PropertyListSerialization.propertyList(data, isValidFor: format) {
        skin.logError("hs.plist.writeString: data supplied is not in a suitable format to serialize as a plist")
        lua_pushboolean(L, 0)
        return 1
    }

    do {
        let output = try PropertyListSerialization.data(
            fromPropertyList: data,
            format: format,
            options: 0
        )
        skin.pushNSObject(output as NSData)
    } catch {
        skin.logError("hs.plist.writeString: error serializing to plist representation: \(error.localizedDescription)")
        lua_pushnil(L)
    }
    return 1
}

/// hs.plist.write(filepath, data[, binary]) -> boolean
/// Function
/// Writes a Property List file
///
/// Parameters:
///  * filepath - The path and filename of the plist file to write
///  * data - A Lua table containing the data to write into the plist
///  * binary - An optional boolean, if true, the plist will be written as a binary file. Defaults to false
///
/// Returns:
///  * A boolean, true if the plist was written successfully, otherwise false
///
/// Notes:
///  * Only simple types can be converted to plist items:
///   * Strings
///   * Numbers
///   * Booleans
///   * Tables
///  * You should be careful when reading a plist, modifying and writing it - Cosmic Hammer may not be able to preserve all of the datatypes via Lua
private func plist_write(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let filePath = (skin.toNSObject(atIndex: 1) as! NSString).expandingTildeInPath
    let data = skin.toNSObject(atIndex: 2, withOptions: LS_NSConversionOptions.nsPreserveLuaStringExactly)!
    let binary = lua_type(L, 3) == LUA_TBOOLEAN ? (lua_toboolean(L, 3) != 0) : false
    let format: PropertyListSerialization.PropertyListFormat = binary ? .binary : .xml

    if !PropertyListSerialization.propertyList(data, isValidFor: format) {
        skin.logError("hs.plist.write(): Data supplied is not in a suitable format to write to a plist file")
        lua_pushboolean(L, 0)
        return 1
    }

    do {
        let output = try PropertyListSerialization.data(
            fromPropertyList: data,
            format: format,
            options: 0
        )
        try output.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        lua_pushboolean(L, 1)
    } catch {
        NSLog("error writing plist: %@", error.localizedDescription)
        lua_pushboolean(L, 0)
    }

    return 1
}

private let plistlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("read"),        func: { L in plist_read(L) }),
    luaL_Reg(name: strdup("readString"),  func: { L in plist_readString(L) }),
    luaL_Reg(name: strdup("writeString"), func: { L in plist_writeString(L) }),
    luaL_Reg(name: strdup("write"),       func: { L in plist_write(L) }),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libplist")
public func luaopen_hs_libplist(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.plist", functions: plistlib, metaFunctions: nil)
    return 1
}
