import Cocoa
import CLua
import os.log

private let USERDATA_TAG = "hs.canvas.matrix"
private var refTable: Int32 = LUA_NOREF

// MARK: - Module Functions

/// hs.canvas.matrix.identity() -> matrixObject
/// Constructor
/// Specifies the identity matrix.  Resets all existing transformations when applied as a method to an existing matrixObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the identity matrix.
///
/// Notes:
///  * The identity matrix can be thought of as "apply no transformations at all" or "render as specified".
///  * Mathematically this is represented as:
/// ~~~
/// [ 1,  0,  0 ]
/// [ 0,  1,  0 ]
/// [ 0,  0,  1 ]
/// ~~~
private func matrix_identity(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return pushNSAffineTransform(L, obj: NSAffineTransform())
}

// MARK: - Module Methods

/// hs.canvas.matrix:invert() -> matrixObject
/// Method
/// Generates the mathematical inverse of the matrix.  This method cannot be used as a constructor.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the inverted matrix.
///
/// Notes:
///  * Inverting a matrix which represents a series of transformations has the effect of reversing or undoing the original transformations.
///  * This is useful when used with [hs.canvas.matrix.append](#append) to undo a previously applied transformation without actually replacing all of the transformations which may have been applied to a canvas element.
private func matrix_invert(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let transform = toNSAffineTransformFromLua(L, idx: 1)
    transform.invert()
    return pushNSAffineTransform(L, obj: transform)
}

/// hs.canvas.matrix:append(matrix) -> matrixObject
/// Method
/// Appends the specified matrix transformations to the matrix and returns the new matrix.  This method cannot be used as a constructor.
///
/// Parameters:
///  * `matrix` - the table to append to the current matrix.
///
/// Returns:
///  * the new matrix
///
/// Notes:
///  * Mathematically this method multiples the original matrix by the new one and returns the result of the multiplication.
///  * You can use this method to "stack" additional transformations on top of existing transformations, without having to know what the existing transformations in effect for the canvas element are.
private func matrix_append(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let transform1 = toNSAffineTransformFromLua(L, idx: 1)
    let transform2 = toNSAffineTransformFromLua(L, idx: 2)
    transform1.append(transform2 as AffineTransform)
    return pushNSAffineTransform(L, obj: transform1)
}

/// hs.canvas.matrix:prepend(matrix) -> matrixObject
/// Method
/// Prepends the specified matrix transformations to the matrix and returns the new matrix.  This method cannot be used as a constructor.
///
/// Parameters:
///  * `matrix` - the table to append to the current matrix.
///
/// Returns:
///  * the new matrix
///
/// Notes:
///  * Mathematically this method multiples the new matrix by the original one and returns the result of the multiplication.
///  * You can use this method to apply a transformation *before* the currently applied transformations, without having to know what the existing transformations in effect for the canvas element are.
private func matrix_prepend(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let transform1 = toNSAffineTransformFromLua(L, idx: 1)
    let transform2 = toNSAffineTransformFromLua(L, idx: 2)
    transform1.prepend(transform2 as AffineTransform)
    return pushNSAffineTransform(L, obj: transform1)
}

/// hs.canvas.matrix:rotate(angle) -> matrixObject
/// Method
/// Applies a rotation of the specified number of degrees to the transformation matrix.  This method can be used as a constructor or a method.
///
/// Parameters:
///  * `angle` - the number of degrees to rotate in a clockwise direction.
///
/// Returns:
///  * the new matrix
///
/// Notes:
///  * The rotation of an element this matrix is applied to will be rotated about the origin (zero point).  To rotate an object about another point (its center for example), prepend a translation to the point to rotate about, and append a translation reversing the initial translation.
///    * e.g. `hs.canvas.matrix.translate(x, y):rotate(angle):translate(-x, -y)`
private func matrix_rotate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var transform = NSAffineTransform()
    var argsAt: Int32 = 2
    if lua_type(L, 1) == LUA_TNUMBER {
        argsAt = 1
    } else {
        transform = toNSAffineTransformFromLua(L, idx: 1)
    }
    transform.rotate(byDegrees: CGFloat(lua_tonumber(L, argsAt)))
    return pushNSAffineTransform(L, obj: transform)
}

/// hs.canvas.matrix:scale(xFactor, [yFactor]) -> matrixObject
/// Method
/// Applies a scaling transformation to the matrix.  This method can be used as a constructor or a method.
///
/// Parameters:
///  * `xFactor` - the scaling factor to apply to the object in the horizontal orientation.
///  * `yFactor` - an optional argument specifying a different scaling factor in the vertical orientation.  If this argument is not provided, the `xFactor` argument will be used for both orientations.
///
/// Returns:
///  * the new matrix
private func matrix_scale(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var transform = NSAffineTransform()
    var argsAt: Int32 = 2
    if lua_type(L, 1) == LUA_TNUMBER {
        argsAt = 1
    } else {
        transform = toNSAffineTransformFromLua(L, idx: 1)
    }
    let scaleX = CGFloat(lua_tonumber(L, argsAt))
    let scaleY = (lua_gettop(L) == (argsAt + 1)) ? CGFloat(lua_tonumber(L, argsAt + 1)) : scaleX
    transform.scaleX(by: scaleX, yBy: scaleY)
    return pushNSAffineTransform(L, obj: transform)
}

/// hs.canvas.matrix:shear(xFactor, [yFactor]) -> matrixObject
/// Method
/// Applies a shearing transformation to the matrix.  This method can be used as a constructor or a method.
///
/// Parameters:
///  * `xFactor` - the shearing factor to apply to the object in the horizontal orientation.
///  * `yFactor` - an optional argument specifying a different shearing factor in the vertical orientation.  If this argument is not provided, the `xFactor` argument will be used for both orientations.
///
/// Returns:
///  * the new matrix
private func matrix_shear(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var transform = NSAffineTransform()
    var argsAt: Int32 = 2
    if lua_type(L, 1) == LUA_TNUMBER {
        argsAt = 1
    } else {
        transform = toNSAffineTransformFromLua(L, idx: 1)
    }
    let shearX = CGFloat(lua_tonumber(L, argsAt))
    let shearY = (lua_gettop(L) == (argsAt + 1)) ? CGFloat(lua_tonumber(L, argsAt + 1)) : shearX

    let operation = NSAffineTransform()
    var opStruct = operation.transformStruct
    opStruct.m12 = shearX
    opStruct.m21 = shearY
    operation.transformStruct = opStruct
    transform.append(operation as AffineTransform)
    return pushNSAffineTransform(L, obj: transform)
}

/// hs.canvas.matrix:translate(x, y) -> matrixObject
/// Method
/// Applies a translation transformation to the matrix.  This method can be used as a constructor or a method.
///
/// Parameters:
///  * `x` - the distance to translate the object in the horizontal direction.
///  * `y` - the distance to translate the object in the vertical direction.
///
/// Returns:
///  * the new matrix
private func matrix_translate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var transform = NSAffineTransform()
    var argsAt: Int32 = 2
    if lua_type(L, 1) == LUA_TNUMBER {
        argsAt = 1
    } else {
        transform = toNSAffineTransformFromLua(L, idx: 1)
    }
    let translateX = CGFloat(lua_tonumber(L, argsAt))
    let translateY = (lua_gettop(L) == (argsAt + 1)) ? CGFloat(lua_tonumber(L, argsAt + 1)) : translateX
    transform.translateX(by: translateX, yBy: translateY)
    return pushNSAffineTransform(L, obj: transform)
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushNSAffineTransform(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    guard let transform = obj as? NSAffineTransform else {
        os_log(.error, "%{public}s", "expected NSAffineTransform, found \(type(of: obj!))")
        lua_pushnil(L)
        return 1
    }

    let structure = transform.transformStruct
    lua_newtable(L)
    lua_pushnumber(L, lua_Number(structure.m11)); lua_setfield(L, -2, "m11")
    lua_pushnumber(L, lua_Number(structure.m12)); lua_setfield(L, -2, "m12")
    lua_pushnumber(L, lua_Number(structure.m21)); lua_setfield(L, -2, "m21")
    lua_pushnumber(L, lua_Number(structure.m22)); lua_setfield(L, -2, "m22")
    lua_pushnumber(L, lua_Number(structure.tX));  lua_setfield(L, -2, "tX")
    lua_pushnumber(L, lua_Number(structure.tY));  lua_setfield(L, -2, "tY")
    lua_pushstring(L, "NSAffineTransform"); lua_setfield(L, -2, "__luaSkinType")

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

private func toNSAffineTransformFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> NSAffineTransform {
    let value = NSAffineTransform()
    var structure = value.transformStruct

    if lua_type(L, idx) == LUA_TTABLE {
        let absIdx = lua_absindex(L, idx)
        if lua_getfield(L, absIdx, "m11") == LUA_TNUMBER {
            structure.m11 = CGFloat(lua_tonumber(L, -1))
        } else {
            os_log(.error, "%{public}s", "NSAffineTransform field m11 is not a number")
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "m12") == LUA_TNUMBER {
            structure.m12 = CGFloat(lua_tonumber(L, -1))
        } else {
            os_log(.error, "%{public}s", "NSAffineTransform field m12 is not a number")
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "m21") == LUA_TNUMBER {
            structure.m21 = CGFloat(lua_tonumber(L, -1))
        } else {
            os_log(.error, "%{public}s", "NSAffineTransform field m21 is not a number")
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "m22") == LUA_TNUMBER {
            structure.m22 = CGFloat(lua_tonumber(L, -1))
        } else {
            os_log(.error, "%{public}s", "NSAffineTransform field m22 is not a number")
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "tX") == LUA_TNUMBER {
            structure.tX = CGFloat(lua_tonumber(L, -1))
        } else {
            os_log(.error, "%{public}s", "NSAffineTransform field tX is not a number")
        }
        lua_pop(L, 1)
        if lua_getfield(L, absIdx, "tY") == LUA_TNUMBER {
            structure.tY = CGFloat(lua_tonumber(L, -1))
        } else {
            os_log(.error, "%{public}s", "NSAffineTransform field tY is not a number")
        }
        lua_pop(L, 1)
    } else {
        os_log(.error, "%{public}s", "expected NSAffineTransform table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }

    value.transformStruct = structure
    return value
}

// MARK: - Cosmic Hammer/Lua Infrastructure

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("identity"),  func: matrix_identity),
    luaL_Reg(name: strdup("rotate"),    func: matrix_rotate),
    luaL_Reg(name: strdup("translate"), func: matrix_translate),
    luaL_Reg(name: strdup("scale"),     func: matrix_scale),
    luaL_Reg(name: strdup("shear"),     func: matrix_shear),
    luaL_Reg(name: strdup("append"),    func: matrix_append),
    luaL_Reg(name: strdup("prepend"),   func: matrix_prepend),
    luaL_Reg(name: strdup("invert"),    func: matrix_invert),
    luaL_Reg(name: nil, func: nil),
]

private var userdataMetaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("rotate"),    func: matrix_rotate),
    luaL_Reg(name: strdup("translate"), func: matrix_translate),
    luaL_Reg(name: strdup("scale"),     func: matrix_scale),
    luaL_Reg(name: strdup("shear"),     func: matrix_shear),
    luaL_Reg(name: strdup("append"),    func: matrix_append),
    luaL_Reg(name: strdup("prepend"),   func: matrix_prepend),
    luaL_Reg(name: strdup("invert"),    func: matrix_invert),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libcanvasmatrix")
public func luaopen_hs_libcanvasmatrix(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    luaL_setfuncs(L, &userdataMetaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    return 1
}
