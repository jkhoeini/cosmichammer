import Cocoa
import LuaSkin

// Source: https://gist.github.com/shpakovski/1902994

private func transformDataWithFunction(
    _ inputData: NSData,
    _ function: (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> SecTransform?
) -> NSData {
    let transformRef = function(kSecBase64Encoding, nil)!
    SecTransformSetAttribute(transformRef, kSecTransformInputAttributeName, inputData as CFTypeRef, nil)
    let outputDataRef = SecTransformExecute(transformRef, nil) as! CFData
    return NSData(data: outputDataRef as Data)
}

// hs.base64.encode(val) -> str
// Function
// Returns the base64 encoding of the string provided.
private func base64_encode(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L).checkArgs(LS_TNUMBER | LS_TSTRING, LS_TBREAK)
    var sz: Int = 0
    let data = luaL_tolstring(L, 1, &sz)!
    let decodedStr = NSData(bytes: data, length: sz)

    let encodedStr = transformDataWithFunction(decodedStr, SecEncodeTransformCreate)
    lua_pushlstring(L, encodedStr.bytes.assumingMemoryBound(to: CChar.self), encodedStr.length)
    return 1
}

//  hs.base64.decode(str) -> val
// Function
// Returns a Lua string representing the given base64 string.
private func base64_decode(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L).checkArgs(LS_TNUMBER | LS_TSTRING, LS_TBREAK)
    var sz: Int = 0
    let data = luaL_tolstring(L, 1, &sz)!
    let encodedStr = NSData(bytes: data, length: sz)

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
public func luaopen_hs_libbase64(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.registerLibrary("hs.base64", functions: &base64_lib, metaFunctions: nil)
    return 1
}
