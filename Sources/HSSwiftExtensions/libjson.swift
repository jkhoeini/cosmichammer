import Cocoa
import LuaSkin

// MARK: - HSjson Helper Class

class HSjson {
    func encode(_ obj: Any, prettyPrint: Bool, withState L: UnsafeMutablePointer<lua_State>!) -> String? {
        let skin = LuaSkin.skin(with: L)
        var opts: JSONSerialization.WritingOptions = []
        if prettyPrint {
            opts = .prettyPrinted
        }

        guard JSONSerialization.isValidJSONObject(obj) else {
            skin.logError("Object cannot be serialised as JSON")
            return nil
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: opts)
            return String(data: data, encoding: .utf8)
        } catch {
            skin.logError("Unable to serialise JSON: \(error.localizedDescription)")
            return nil
        }
    }

    func decode(_ data: Data?, withState L: UnsafeMutablePointer<lua_State>!) -> Any? {
        let skin = LuaSkin.skin(with: L)
        guard let data = data else {
            skin.logError("Unable to convert JSON to NSData object")
            return nil
        }

        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            return obj
        } catch {
            skin.logError("Error deserialising JSON: \(error.localizedDescription)")
            return nil
        }
    }

    func encodeToFile(_ obj: Any, filePath path: String, replace: Bool, prettyPrint: Bool, withState L: UnsafeMutablePointer<lua_State>!) -> Bool {
        let skin = LuaSkin.skin(with: L)
        guard let json = encode(obj, prettyPrint: prettyPrint, withState: L) else {
            skin.logError("Failed to write object to JSON file")
            return false
        }

        guard let data = json.data(using: .utf8) else {
            skin.logError("Unable to convert JSON to NSData object")
            return false
        }

        // Note to future optimisers: We can't use NSString's file writing method
        //  because it unconditionally overwrites files.
        do {
            let options: NSData.WritingOptions = replace ? .atomic : .withoutOverwriting
            try data.write(to: URL(fileURLWithPath: path), options: options)
            return true
        } catch {
            skin.logError("Error writing JSON to file: \(error.localizedDescription)")
            return false
        }
    }

    func decodeFromFile(_ path: String, withState L: UnsafeMutablePointer<lua_State>!) -> Any? {
        let skin = LuaSkin.skin(with: L)
        do {
            let json = try Data(contentsOf: URL(fileURLWithPath: path))
            return decode(json, withState: L)
        } catch {
            skin.logError("Error reading JSON from file: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Module Functions

/// hs.json.encode(val[, prettyprint]) -> string
/// Function
/// Encodes a table as JSON
///
/// Parameters:
///  * val - A table containing data to be encoded as JSON
///  * prettyprint - An optional boolean, true to format the JSON for human readability, false to format the JSON for size efficiency. Defaults to false
///
/// Returns:
///  * A string containing a JSON representation of the supplied table
///
/// Notes:
///  * This is useful for storing some of the more complex lua table structures as a persistent setting (see `hs.settings`)
private func json_encode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let jsonManager = HSjson()

    let table = skin.toNSObject(atIndex: 1)!
    let prettyPrint = lua_toboolean(L, 2) != 0

    let json = jsonManager.encode(table, prettyPrint: prettyPrint, withState: L)
    skin.pushNSObject(json as NSString?)
    return 1
}

/// hs.json.decode(jsonString) -> table
/// Function
/// Decodes JSON into a table
///
/// Parameters:
///  * jsonString - A string containing some JSON data
///
/// Returns:
///  * A table representing the supplied JSON data
///
/// Notes:
///  * This is useful for retrieving some of the more complex lua table structures as a persistent setting (see `hs.settings`)
private func json_decode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let jsonManager = HSjson()

    let data = skin.toNSObject(atIndex: 1, withOptions: .nsLuaStringAsDataOnly) as? Data

    let table = jsonManager.decode(data, withState: L)
    skin.pushNSObject(table as? NSObject)
    return 1
}

/// hs.json.write(data, path, [prettyprint], [replace]) -> boolean
/// Function
/// Encodes a table as JSON to a file
///
/// Parameters:
///  * data - A table containing data to be encoded as JSON
///  * path - The path and filename of the JSON file to write to
///  * prettyprint - An optional boolean, `true` to format the JSON for human readability, `false` to format the JSON for size efficiency. Defaults to `false`
///  * replace - An optional boolean, `true` to replace an existing file at the same path if one exists. Defaults to `false`
///
/// Returns:
///  * `true` if successful otherwise `false` if an error has occurred
private func json_write(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TSTRING, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let jsonManager = HSjson()

    let table = skin.toNSObject(atIndex: 1)!
    let filePath = (skin.toNSObject(atIndex: 2) as! NSString).expandingTildeInPath
    let prettyPrint = lua_toboolean(L, 3) != 0
    let replace = lua_toboolean(L, 4) != 0

    let result = jsonManager.encodeToFile(table, filePath: filePath, replace: replace, prettyPrint: prettyPrint, withState: L)

    lua_pushboolean(L, result ? 1 : 0)
    return 1
}

/// hs.json.read(path) -> table | nil
/// Function
/// Decodes JSON file into a table.
///
/// Parameters:
///  * path - The path and filename of the JSON file to read.
///
/// Returns:
///  * A table representing the supplied JSON data, or `nil` if an error occurs.
private func json_read(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let jsonManager = HSjson()

    let filePath = (skin.toNSObject(atIndex: 1) as! NSString).expandingTildeInPath

    let table = jsonManager.decodeFromFile(filePath, withState: L)
    skin.pushNSObject(table as? NSObject)
    return 1
}

// MARK: - Module Registration

// C-callable wrappers for luaL_Reg
private let json_encode_wrapper: lua_CFunction = { L in json_encode(L) }
private let json_decode_wrapper: lua_CFunction = { L in json_decode(L) }
private let json_read_wrapper: lua_CFunction = { L in json_read(L) }
private let json_write_wrapper: lua_CFunction = { L in json_write(L) }

// Functions for returned object when module loads
private var jsonLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("encode"), func: json_encode_wrapper),
    luaL_Reg(name: strdup("decode"), func: json_decode_wrapper),
    luaL_Reg(name: strdup("read"), func: json_read_wrapper),
    luaL_Reg(name: strdup("write"), func: json_write_wrapper),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libjson")
public func luaopen_hs_libjson(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.json", functions: &jsonLib, metaFunctions: nil)

    return 1
}
