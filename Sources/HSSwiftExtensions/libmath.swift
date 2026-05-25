import Cocoa
import LuaSkin

/// hs.math.randomFloat() -> number
/// Function
/// Returns a random floating point number between 0 and 1
///
/// Parameters:
///  * None
///
/// Returns:
///  * A random number between 0 and 1
private func math_randomFloat(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let rand = arc4random()
    let val = Double(rand) / Double(UInt32.max)

    lua_pushnumber(L, val)
    return 1
}

/// hs.math.randomFromRange(start, end) -> integer
/// Function
/// Returns a random integer between the start and end parameters
///
/// Parameters:
///  * start - A number to start the range, must be greater than or equal to zero
///  * end - A number to end the range, must be greater than zero and greater than `start`
///
/// Returns:
///  * A randomly chosen integer between `start` and `end`
private func math_randomFromRange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TNUMBER, LS_TNUMBER, LS_TBREAK)

    let start = Int32(lua_tointeger(L, 1))
    let end = Int32(lua_tointeger(L, 2))

    if start < 0 || end <= 0 || end <= start {
        skin.logError("Please check the docs for hs.math.randomForRange() - your range is not acceptable (\(start) -> \(end))")
        lua_pushnil(L)
        return 1
    }

    let result = Int(arc4random_uniform(UInt32(end - start + 1))) + Int(start)

    lua_pushinteger(L, lua_Integer(result))
    return 1
}

// Functions for returned object when module loads
private var mathLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("randomFloat"),     func: math_randomFloat),
    luaL_Reg(name: strdup("randomFromRange"), func: math_randomFromRange),
    luaL_Reg(name: nil,                       func: nil),
]

@_cdecl("luaopen_hs_libmath")
func luaopen_hs_libmath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.math", functions: &mathLib, metaFunctions: nil)
    return 1
}
