import Foundation
import OSAKit
import LuaSkin

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
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)

    let source = skin.toNSObject(atIndex: 1) as! String
    let language = skin.toNSObject(atIndex: 2) as! String

    let osa = OSAScript(source: source, language: OSALanguage(forName: language))
    var compileError: NSDictionary?
    osa.compileAndReturnError(&compileError)

    if let compileError = compileError {
        lua_pushboolean(skin.L, 0)
        lua_pushnil(skin.L)
        skin.pushNSObject(NSString(format: "%@", compileError))
        skin.logError(NSString(format: "Unable to initialize script: %@", compileError))
        return 3
    }

    var error: NSDictionary?
    let result = osa.executeAndReturnError(&error)
    let didSucceed = (result != nil)

    lua_pushboolean(skin.L, didSucceed ? 1 : 0)
    if didSucceed {
        skin.pushNSObject(result!.objectValue)
    } else {
        skin.pushNSObject(NSNull())
    }
    skin.pushNSObject(NSString(format: "%@", didSucceed ? result! : error!))
    return 3
}

private var scriptlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_osascript"), func: runosascript),
    luaL_Reg(name: nil,                  func: nil),
]

@_cdecl("luaopen_hs_libosascript")
public func luaopen_hs_libosascript(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.registerLibrary("hs.osascript", functions: &scriptlib, metaFunctions: nil)

    return 1
}
