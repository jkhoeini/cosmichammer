import Cocoa
import CommonCrypto
import LuaSkin

// When adding a new hash type, you should only need to update a couple of areas...
// they are labeled with ADD_NEW_HASH_HERE

// uncomment to include deprecated/less-common hash types (see hashLookupTable below)
// let INCLUDE_HISTORICAL = true

private let USERDATA_TAG = "hs.hash"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions and Classes

typealias HashInitFn   = @convention(c) (NSData?) -> UnsafeMutableRawPointer
typealias HashAppendFn = @convention(c) (UnsafeMutableRawPointer, NSData) -> Void
typealias HashFinishFn = @convention(c) (UnsafeMutableRawPointer) -> NSData

struct HashEntry {
    let hashName: String
    let initFn: HashInitFn
    let appendFn: HashAppendFn
    let finishFn: HashFinishFn
}

// ADD_NEW_HASH_HERE -- assuming new hash code is in its own .swift and .h files

private let hashLookupTable: [HashEntry] = {
    var table: [HashEntry] = []
    // #ifdef INCLUDE_HISTORICAL equivalent — uncomment the INCLUDE_HISTORICAL let above to enable
    #if false
    table.append(HashEntry(hashName: "MD2",        initFn: init_MD2,        appendFn: append_MD2,        finishFn: finish_MD2))
    table.append(HashEntry(hashName: "MD4",        initFn: init_MD4,        appendFn: append_MD4,        finishFn: finish_MD4))
    table.append(HashEntry(hashName: "SHA224",     initFn: init_SHA224,     appendFn: append_SHA224,     finishFn: finish_SHA224))
    table.append(HashEntry(hashName: "SHA384",     initFn: init_SHA384,     appendFn: append_SHA384,     finishFn: finish_SHA384))
    table.append(HashEntry(hashName: "hmacSHA224", initFn: init_hmacSHA224, appendFn: append_hmac,       finishFn: finish_hmacSHA224))
    table.append(HashEntry(hashName: "hmacSHA384", initFn: init_hmacSHA384, appendFn: append_hmac,       finishFn: finish_hmacSHA384))
    #endif

    table.append(HashEntry(hashName: "CRC32",      initFn: init_CRC32,      appendFn: append_CRC32,      finishFn: finish_CRC32))
    table.append(HashEntry(hashName: "MD5",        initFn: init_MD5,        appendFn: append_MD5,        finishFn: finish_MD5))
    table.append(HashEntry(hashName: "SHA1",       initFn: init_SHA1,       appendFn: append_SHA1,       finishFn: finish_SHA1))
    table.append(HashEntry(hashName: "SHA256",     initFn: init_SHA256,     appendFn: append_SHA256,     finishFn: finish_SHA256))
    table.append(HashEntry(hashName: "SHA512",     initFn: init_SHA512,     appendFn: append_SHA512,     finishFn: finish_SHA512))
    table.append(HashEntry(hashName: "hmacMD5",    initFn: init_hmacMD5,    appendFn: append_hmac,       finishFn: finish_hmacMD5))
    table.append(HashEntry(hashName: "hmacSHA1",   initFn: init_hmacSHA1,   appendFn: append_hmac,       finishFn: finish_hmacSHA1))
    table.append(HashEntry(hashName: "hmacSHA256", initFn: init_hmacSHA256, appendFn: append_hmac,       finishFn: finish_hmacSHA256))
    table.append(HashEntry(hashName: "hmacSHA512", initFn: init_hmacSHA512, appendFn: append_hmac,       finishFn: finish_hmacSHA512))

    table.append(HashEntry(hashName: "SHA3_224",   initFn: init_SHA3_224,   appendFn: append_SHA3,       finishFn: finish_SHA3_224))
    table.append(HashEntry(hashName: "SHA3_256",   initFn: init_SHA3_256,   appendFn: append_SHA3,       finishFn: finish_SHA3_256))
    table.append(HashEntry(hashName: "SHA3_384",   initFn: init_SHA3_384,   appendFn: append_SHA3,       finishFn: finish_SHA3_384))
    table.append(HashEntry(hashName: "SHA3_512",   initFn: init_SHA3_512,   appendFn: append_SHA3,       finishFn: finish_SHA3_512))
    // ADD_NEW_HASH_HERE -- label(s) for Hammerspoon and functions for initializing, appending to, and finishing
    return table
}()

class HSHashObject: NSObject {
    var selfRefCount: Int = 0
    let hashType: Int
    let secret: NSData?
    var context: UnsafeMutableRawPointer?
    var value: NSData?

    init(hashType: Int, secret: NSData?) {
        self.hashType = hashType
        self.secret = secret
        self.context = hashLookupTable[hashType].initFn(secret)
        self.value = nil
        super.init()
    }

    func append(_ data: NSData) {
        hashLookupTable[hashType].appendFn(context!, data)
    }

    func finish() {
        value = hashLookupTable[hashType].finishFn(context!)
        context = nil // it was freed in the finish function
    }
}

// MARK: - Module Functions

/// hs.hash.new(hash, [secret]) -> hashObject
/// Constructor
/// Creates a new context for the specified hash function.
///
/// Parameters:
///  * `hash`    - a string specifying the name of the hash function to use. This must be one of the string values found in the [hs.hash.types](#types) constant.
///  * `secret`  - an optional string specifying the shared secret to prepare the hmac hash function with. For all other hash types this field is ignored. Leaving this parameter off when specifying an hmac hash function is equivalent to specifying an empty secret or a secret composed solely of null values.
///
/// Returns:
///  * the new hash object
private func hash_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let hashName = skin.toNSObject(atIndex: 1) as! String
    var secret: NSData? = nil
    if lua_gettop(L) == 2 {
        secret = skin.toNSObject(atIndex: 2, withOptions: LS_NSLuaStringAsDataOnly) as? NSData
    }

    var hashType = 0
    var hashFound = false

    for i in 0..<hashLookupTable.count {
        let label = hashLookupTable[i].hashName
        if hashName.caseInsensitiveCompare(label) == .orderedSame {
            hashFound = true
            hashType = i
            break
        }
    }

    if hashFound {
        let object = HSHashObject(hashType: hashType, secret: secret)
        skin.pushNSObject(object)
    } else {
        return luaL_argerror(L, 1, "unrecognized hash type")
    }
    return 1
}

// MARK: - Module Methods

/// hs.hash:append(data) -> hashObject | nil, error
/// Method
/// Adds the provided data to the input of the hash function currently in progress for the hashObject.
///
/// Parameters:
///  * `data` - a string containing the data to add to the hash functions input.
///
/// Returns:
///  * the hash object, or if the hash has already been calculated (finished), nil and an error string
private func hash_append(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObject
    let data = skin.toNSObject(atIndex: 2, withOptions: LS_NSLuaStringAsDataOnly) as! NSData

    if object.value == nil {
        object.append(data)
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "hash calculation completed")
        return 2
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.hash:appendFile(path) -> hashObject | nil, error
/// Method
/// Adds the contents of the file at the specified path to the input of the hash function currently in progress for the hashObject.
///
/// Parameters:
///  * `path` - a string containing the path of the file to add to the hash functions input.
///
/// Returns:
///  * the hash object
private func hash_appendFile(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObject
    var path = skin.toNSObject(atIndex: 2) as! String

    if object.value == nil {
        path = (path as NSString).expandingTildeInPath
        path = (path as NSString).resolvingSymlinksInPath
        do {
            let data = try NSData(contentsOfFile: path, options: .uncached)
            object.append(data)
        } catch {
            lua_pushnil(L)
            lua_pushfstring(L, "error reading contents of %s: %s",
                            (path as NSString).utf8String!,
                            (error.localizedDescription as NSString).utf8String!)
            return 2
        }
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "hash calculation completed")
        return 2
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.hash:finish() -> hashObject
/// Method
/// Finalizes the hash and computes the resulting value.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the hash object
///
/// Notes:
///  * a hash that has been finished can no longer have data appended to it.
private func hash_finish(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObject

    if object.value == nil { object.finish() }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.hash:value([binary]) -> string | nil
/// Method
/// Returns the value of a completed hash, or nil if it is still in progress.
///
/// Parameters:
///  * `binary` - an optional boolean, default false, specifying whether or not the value should be provided as raw binary bytes (true) or as a string of hexadecimal numbers (false).
///
/// Returns:
///  * a string containing the hash value or nil if the hash has not been finished.
private func hash_value(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObject
    let inBinary = (lua_gettop(L) == 2) ? (lua_toboolean(L, 2) != 0) : false

    if let val = object.value {
        if inBinary {
            skin.pushNSObject(val)
        } else {
            let bytes = val.bytes.assumingMemoryBound(to: UInt8.self)
            var hex = ""
            hex.reserveCapacity(val.length * 2)
            for i in 0..<val.length {
                hex += String(format: "%02x", bytes[i])
            }
            skin.pushNSObject(hex as NSString)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.hash:type() -> string
/// Method
/// Returns the name of the hash type the object refers to
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the hash type name.
private func hash_type(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObject
    lua_pushstring(L, hashLookupTable[object.hashType].hashName)
    return 1
}

// MARK: - Module Constants

// documented in hash.lua
private func hash_types(_ L: OpaquePointer!) -> Int32 {
    lua_newtable(L)
    for i in 0..<hashLookupTable.count {
        lua_pushstring(L, hashLookupTable[i].hashName)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

private func pushHSHashObject(_ L: OpaquePointer!, obj: AnyObject) -> Int32 {
    let value = obj as! HSHashObject
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    valuePtr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee =
        Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSHashObjectFromLua(_ L: OpaquePointer!, idx: Int32) -> AnyObject? {
    let skin = LuaSkin.shared(withState: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        let opaquePtr = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
        let value = Unmanaged<HSHashObject>.fromOpaque(opaquePtr).takeUnretainedValue()
        return value
    } else {
        skin.logError("\(USERDATA_TAG) expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let obj = skin.luaObject(atIndex: 1, toClass: "HSHashObject") as! HSHashObject
    var title = hashLookupTable[obj.hashType].hashName
    if obj.value == nil {
        title = "\(title) <in-progress>"
    }
    skin.pushNSObject(NSString(format: "%@: %@ (%p)", USERDATA_TAG, title, lua_topointer(L, 1)))
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)
        let obj1 = skin.luaObject(atIndex: 1, toClass: "HSHashObject") as! HSHashObject
        let obj2 = skin.luaObject(atIndex: 2, toClass: "HSHashObject") as! HSHashObject
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let opaquePtr = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    let obj = Unmanaged<HSHashObject>.fromOpaque(opaquePtr).takeRetainedValue()
    obj.selfRefCount -= 1
    if obj.selfRefCount == 0 {
        if obj.context != nil { obj.finish() }
    }
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: ("append"     as NSString).utf8String, func: hash_append),
    luaL_Reg(name: ("appendFile" as NSString).utf8String, func: hash_appendFile),
    luaL_Reg(name: ("finish"     as NSString).utf8String, func: hash_finish),
    luaL_Reg(name: ("value"      as NSString).utf8String, func: hash_value),
    luaL_Reg(name: ("type"       as NSString).utf8String, func: hash_type),

    luaL_Reg(name: ("__tostring" as NSString).utf8String, func: userdata_tostring),
    luaL_Reg(name: ("__eq"       as NSString).utf8String, func: userdata_eq),
    luaL_Reg(name: ("__gc"       as NSString).utf8String, func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: ("new" as NSString).utf8String, func: hash_new),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhash")
func luaopen_hs_libhash(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    _ = hash_types(L); lua_setfield(L, -2, "types")

    skin.registerPushNSHelper(pushHSHashObject, forClass: "HSHashObject")
    skin.registerLuaObjectHelper(toHSHashObjectFromLua, forClass: "HSHashObject",
                                 withUserdataMapping: USERDATA_TAG)

    return 1
}
