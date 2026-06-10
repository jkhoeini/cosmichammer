import Cocoa
import CLua
import Lua

private func transformDataWithFunction(
    _ inputData: NSData,
    _ function: (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> SecTransform?
) -> NSData? {
    guard let transformRef = function(kSecBase64Encoding, nil) else { return nil }
    SecTransformSetAttribute(transformRef, kSecTransformInputAttributeName, inputData as CFTypeRef, nil)
    let outputDataRef = SecTransformExecute(transformRef, nil)
    return NSData(data: outputDataRef as! CFData as Data)
}

/// Read a binary-safe Lua string (or number coerced to string) from the given
/// stack index. Throws a Lua error for any other type.
private func checkBinaryArg(_ L: LuaState, _ arg: CInt) throws -> [UInt8] {
    let t = lua_type(L, arg)
    switch t {
    case LUA_TSTRING:
        return L.todata(arg)!
    case LUA_TNUMBER:
        // Coerce number to its string representation via Lua, preserving
        // legacy behavior (e.g. 42 -> "42", 3.14 -> "3.14").
        var sz: Int = 0
        let ptr = luaL_tolstring(L, arg, &sz)!
        let bytes: [UInt8] = ptr.withMemoryRebound(to: UInt8.self, capacity: sz) { reboundPtr in
            Array(UnsafeBufferPointer(start: reboundPtr, count: sz))
        }
        lua_pop(L, 1)  // pop the coerced string pushed by luaL_tolstring
        return bytes
    default:
        throw L.error("expected string or number for argument \(arg)")
    }
}

private let base64_encode: LuaClosure = { L in
    let input = try checkBinaryArg(L, 1)
    let inputData = NSData(bytes: input, length: input.count)
    guard let encoded = transformDataWithFunction(inputData, SecEncodeTransformCreate) else {
        throw L.error("base64 encode failed")
    }
    L.push(Array(UnsafeBufferPointer(
        start: encoded.bytes.assumingMemoryBound(to: UInt8.self),
        count: encoded.length)))
    return 1
}

private let base64_decode: LuaClosure = { L in
    let input = try checkBinaryArg(L, 1)
    let inputData = NSData(bytes: input, length: input.count)
    guard let decoded = transformDataWithFunction(inputData, SecDecodeTransformCreate) else {
        throw L.error("base64 decode failed")
    }
    L.push(Array(UnsafeBufferPointer(
        start: decoded.bytes.assumingMemoryBound(to: UInt8.self),
        count: decoded.length)))
    return 1
}

@_cdecl("luaopen_hs_libbase64")
public func luaopen_hs_libbase64(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 2)
        L.push(base64_encode)
        lua_setfield(L, -2, "_encode")
        L.push(base64_decode)
        lua_setfield(L, -2, "_decode")
    }
}
