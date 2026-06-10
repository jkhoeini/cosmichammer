import Foundation
import CLua
import Lua

/// hs.math.randomFloat() -> number
/// Function
/// Returns a random floating point number between 0 and 1
///
/// Parameters:
///  * None
///
/// Returns:
///  * A random number between 0 and 1
private let math_randomFloat: () throws -> Double = {
    Double(arc4random()) / Double(UInt32.max)
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
private let math_randomFromRange: (Int, Int) throws -> Int = { start, end in
    let s = Int32(start)
    let e = Int32(end)

    if s < 0 || e <= 0 || e <= s {
        throw LuaCallError("Please check the docs for hs.math.randomForRange() - your range is not acceptable")
    }

    return Int(arc4random_uniform(UInt32(e - s + 1))) + Int(s)
}

@_cdecl("luaopen_hs_libmath")
func luaopen_hs_libmath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 2)
        L.push(closure: math_randomFloat)
        lua_setfield(L, -2, "randomFloat")
        L.push(closure: math_randomFromRange)
        lua_setfield(L, -2, "randomFromRange")
    }
}
