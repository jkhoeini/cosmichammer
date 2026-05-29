import Foundation
import CLua
import OSAKit

/// hs.osascript._osascript(source, language) -> bool, object, descriptor
/// Function
/// Runs osascript code
///
/// Parameters:
///  * source - Some osascript code to execute
///  * language - A string containing the OSA language, either 'AppleScript' or 'JavaScript'. Defaults to AppleScript if invalid language
///
/// Returns:
///  * A boolean value indicating whether the code succeeded or not
///  * An object containing the parsed output that can be any type, or nil if unsuccessful
///  * A string containing the raw output of the code and/or its errors
private let runosascript: lua_CFunction = { L in
    let source = String(cString: luaL_checkstring(L, 1))
    let language = String(cString: luaL_checkstring(L, 2))

    let osa = OSAScript(source: source, language: OSALanguage(forName: language))
    var compileError: NSDictionary?
    osa.compileAndReturnError(&compileError)

    if let compileError = compileError {
        lua_pushboolean(L, 0)
        lua_pushnil(L)
        lua_pushstring(L, NSString(format: "%@", compileError) as String)
        return 3
    }

    var error: NSDictionary?
    let result = osa.executeAndReturnError(&error)
    let didSucceed = (result != nil)

    lua_pushboolean(L, didSucceed ? 1 : 0)
    if didSucceed {
        lua_pushany(L, result!.objectValue)
    } else {
        lua_pushnil(L)
    }
    lua_pushstring(L, NSString(format: "%@", didSucceed ? result! : error!) as String)
    return 3
}

private var scriptlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_osascript"), func: runosascript),
    luaL_Reg(name: nil,                  func: nil),
]

@_cdecl("luaopen_hs_libosascript")
public func luaopen_hs_libosascript(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_createtable(L, 0, Int32(scriptlib.count - 1))
    luaL_setfuncs(L, &scriptlib, 0)

    return 1
}
