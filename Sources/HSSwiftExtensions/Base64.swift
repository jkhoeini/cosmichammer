import Cocoa
import LuaSkin

private func transformDataWithFunction(
    _ inputData: NSData,
    _ function: (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> SecTransform?
) -> NSData {
    let transformRef = function(kSecBase64Encoding, nil)!
    SecTransformSetAttribute(transformRef, kSecTransformInputAttributeName, inputData as CFTypeRef, nil)
    let outputDataRef = SecTransformExecute(transformRef, nil) as! CFData
    return NSData(data: outputDataRef as Data)
}

private func base64_encode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let t = lua_type(L, 1)
    guard t == LUA_TNUMBER || t == LUA_TSTRING else {
        return luaL_error(L, "expected string or number for argument 1")
    }
    var sz: Int = 0
    let data = luaL_tolstring(L, 1, &sz)!
    let decodedStr = NSData(bytes: data, length: sz)
    lua_pop(L, 1)

    let encodedStr = transformDataWithFunction(decodedStr, SecEncodeTransformCreate)
    lua_pushlstring(L, encodedStr.bytes.assumingMemoryBound(to: CChar.self), encodedStr.length)
    return 1
}

private func base64_decode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let t = lua_type(L, 1)
    guard t == LUA_TNUMBER || t == LUA_TSTRING else {
        return luaL_error(L, "expected string or number for argument 1")
    }
    var sz: Int = 0
    let data = luaL_tolstring(L, 1, &sz)!
    let encodedStr = NSData(bytes: data, length: sz)
    lua_pop(L, 1)

    let decodedStr = transformDataWithFunction(encodedStr, SecDecodeTransformCreate)
    lua_pushlstring(L, decodedStr.bytes.assumingMemoryBound(to: CChar.self), decodedStr.length)
    return 1
}

private var base64_lib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_encode"), func: base64_encode),
    luaL_Reg(name: strdup("_decode"), func: base64_decode),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libbase64")
public func luaopen_hs_libbase64(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_createtable(L, 0, Int32(base64_lib.count - 1))
    luaL_setfuncs(L, &base64_lib, 0)
    return 1
}
