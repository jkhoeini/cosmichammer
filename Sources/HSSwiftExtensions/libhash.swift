import Cocoa
import CommonCrypto
import LuaSkin
import zlib

// MARK: - SHA3 (Keccak) Pure-Swift Implementation

/// Pure-Swift implementation of SHA3 (Keccak) based on the NIST FIPS 202 standard.
/// Ported from the RHash C implementation (sha3.m / sha3.h).

private let kNumberOfRounds = 24

private let keccakRoundConstants: [UInt64] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

private let kRhoOffsets: [Int] = [
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14,
]

private let kPiLane: [Int] = [
    10,  7, 11, 17, 18,
     3,  5, 16,  8, 21,
    24,  4, 15, 23, 19,
    13, 12,  2, 20, 14,
    22,  9,  6,  1,
]

private struct SHA3Context {
    var hash: [UInt64] = Array(repeating: 0, count: 25)  // 1600 bits
    var message: [UInt64] = Array(repeating: 0, count: 24) // 1536-bit buffer
    var rest: UInt32 = 0
    var blockSize: UInt32 = 0
}

private let sha3_224_hash_size = 28
private let sha3_256_hash_size = 32
private let sha3_384_hash_size = 48
private let sha3_512_hash_size = 64

private func rotl64(_ qword: UInt64, _ n: Int) -> UInt64 {
    return (qword << n) ^ (qword >> (64 - n))
}

private func keccakPermutation(_ state: inout [UInt64]) {
    for round in 0..<kNumberOfRounds {
        // theta
        var C = [UInt64](repeating: 0, count: 5)
        for x in 0..<5 {
            C[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
        }
        var D = [UInt64](repeating: 0, count: 5)
        for x in 0..<5 {
            D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 1)
        }
        for x in 0..<5 {
            for y in stride(from: 0, to: 25, by: 5) {
                state[y + x] ^= D[x]
            }
        }

        // rho and pi
        var B = [UInt64](repeating: 0, count: 25)
        for x in 0..<5 {
            for y in 0..<5 {
                let idx = y * 5 + x
                B[x * 5 + ((2 * x + 3 * y) % 5)] = rotl64(state[idx], kRhoOffsets[idx])
            }
        }

        // chi
        for x in 0..<5 {
            for y in 0..<5 {
                let idx = y * 5 + x
                state[idx] = B[idx] ^ (~B[y * 5 + (x + 1) % 5] & B[y * 5 + (x + 2) % 5])
            }
        }

        // iota
        state[0] ^= keccakRoundConstants[round]
    }
}

private func sha3Init(bits: Int) -> SHA3Context {
    let rate = 1600 - bits * 2
    var ctx = SHA3Context()
    ctx.blockSize = UInt32(rate / 8)
    return ctx
}

private let kSHA3Finalized: UInt32 = 0x80000000

private func sha3Update(_ ctx: inout SHA3Context, _ msg: UnsafePointer<UInt8>, _ size: Int) {
    var msgPtr = msg
    var remaining = size
    let blockSize = Int(ctx.blockSize)

    if ctx.rest & kSHA3Finalized != 0 { return }

    var index = Int(ctx.rest)
    ctx.rest = UInt32((Int(ctx.rest) + size) % blockSize)

    // fill partial block
    if index > 0 {
        let left = blockSize - index
        let toCopy = min(remaining, left)
        withUnsafeMutableBytes(of: &ctx.message) { bufPtr in
            let dest = bufPtr.baseAddress!.advanced(by: index)
            dest.copyMemory(from: msgPtr, byteCount: toCopy)
        }
        if remaining < left { return }

        // process partial block
        keccakProcessBlock(&ctx.hash, ctx.message, blockSize)
        msgPtr = msgPtr.advanced(by: left)
        remaining -= left
    }

    while remaining >= blockSize {
        // copy into message buffer for alignment
        withUnsafeMutableBytes(of: &ctx.message) { bufPtr in
            bufPtr.baseAddress!.copyMemory(from: msgPtr, byteCount: blockSize)
        }
        keccakProcessBlock(&ctx.hash, ctx.message, blockSize)
        msgPtr = msgPtr.advanced(by: blockSize)
        remaining -= blockSize
    }

    if remaining > 0 {
        withUnsafeMutableBytes(of: &ctx.message) { bufPtr in
            bufPtr.baseAddress!.copyMemory(from: msgPtr, byteCount: remaining)
        }
    }
}

private func keccakProcessBlock(_ hash: inout [UInt64], _ block: [UInt64], _ blockSize: Int) {
    let count = blockSize / 8
    for i in 0..<count {
        hash[i] ^= block[i].littleEndian  // on LE arch this is identity
    }
    keccakPermutation(&hash)
}

private func sha3Final(_ ctx: inout SHA3Context) -> [UInt8] {
    let digestLength = 100 - Int(ctx.blockSize) / 2
    let blockSize = Int(ctx.blockSize)

    if ctx.rest & kSHA3Finalized == 0 {
        let restIndex = Int(ctx.rest)
        // clear the rest of the data queue
        withUnsafeMutableBytes(of: &ctx.message) { bufPtr in
            let base = bufPtr.baseAddress!
            if blockSize - restIndex > 0 {
                memset(base.advanced(by: restIndex), 0, blockSize - restIndex)
            }
            // SHA3 domain separation byte
            base.advanced(by: restIndex).storeBytes(of: base.load(fromByteOffset: restIndex, as: UInt8.self) | 0x06, as: UInt8.self)
            // final bit
            base.advanced(by: blockSize - 1).storeBytes(of: base.load(fromByteOffset: blockSize - 1, as: UInt8.self) | 0x80, as: UInt8.self)
        }
        keccakProcessBlock(&ctx.hash, ctx.message, blockSize)
        ctx.rest = kSHA3Finalized
    }

    // extract digest bytes (little-endian)
    var result = [UInt8](repeating: 0, count: digestLength)
    withUnsafeBytes(of: &ctx.hash) { srcPtr in
        for i in 0..<digestLength {
            result[i] = srcPtr.load(fromByteOffset: i, as: UInt8.self)
        }
    }
    return result
}

// MARK: - SHA3 Context Wrapper (heap-allocated for use as UnsafeMutableRawPointer)

private final class SHA3ContextBox {
    var ctx: SHA3Context
    init(_ ctx: SHA3Context) { self.ctx = ctx }
}

// MARK: - Hash Algorithm init/append/finish Functions (CRC32, MD5, SHA1, SHA256, SHA512, HMAC variants, SHA3)

private typealias HashInitFn   = (Data?) -> UnsafeMutableRawPointer
private typealias HashAppendFn = (UnsafeMutableRawPointer, Data) -> Void
private typealias HashFinishFn = (UnsafeMutableRawPointer) -> Data

private struct HashEntry {
    let hashName: String
    let initFn: HashInitFn
    let appendFn: HashAppendFn
    let finishFn: HashFinishFn
}

// CRC32

private func crc32Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let ctx = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
    ctx.pointee = UInt(crc32_z(0, nil, 0))
    return UnsafeMutableRawPointer(ctx)
}

private func crc32Append(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let ctx = context.assumingMemoryBound(to: UInt.self)
    data.withUnsafeBytes { bufPtr in
        let ptr = bufPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
        ctx.pointee = UInt(crc32_z(uLong(ctx.pointee), ptr, data.count))
    }
}

private func crc32Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let ctx = context.assumingMemoryBound(to: UInt.self)
    let crc = ctx.pointee
    ctx.deallocate()
    var bytes: [UInt8] = [
        UInt8((crc >> 24) & 0xff),
        UInt8((crc >> 16) & 0xff),
        UInt8((crc >>  8) & 0xff),
        UInt8( crc        & 0xff),
    ]
    return Data(bytes: &bytes, count: 4)
}

// MD5

private func md5Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let ctx = UnsafeMutablePointer<CC_MD5_CTX>.allocate(capacity: 1)
    CC_MD5_Init(ctx)
    return UnsafeMutableRawPointer(ctx)
}

private func md5Append(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let ctx = context.assumingMemoryBound(to: CC_MD5_CTX.self)
    data.withUnsafeBytes { bufPtr in
        CC_MD5_Update(ctx, bufPtr.baseAddress!, CC_LONG(data.count))
    }
}

private func md5Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let ctx = context.assumingMemoryBound(to: CC_MD5_CTX.self)
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    CC_MD5_Final(&digest, ctx)
    ctx.deallocate()
    return Data(digest)
}

// SHA1

private func sha1Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let ctx = UnsafeMutablePointer<CC_SHA1_CTX>.allocate(capacity: 1)
    CC_SHA1_Init(ctx)
    return UnsafeMutableRawPointer(ctx)
}

private func sha1Append(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let ctx = context.assumingMemoryBound(to: CC_SHA1_CTX.self)
    data.withUnsafeBytes { bufPtr in
        CC_SHA1_Update(ctx, bufPtr.baseAddress!, CC_LONG(data.count))
    }
}

private func sha1Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let ctx = context.assumingMemoryBound(to: CC_SHA1_CTX.self)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    CC_SHA1_Final(&digest, ctx)
    ctx.deallocate()
    return Data(digest)
}

// SHA256

private func sha256Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let ctx = UnsafeMutablePointer<CC_SHA256_CTX>.allocate(capacity: 1)
    CC_SHA256_Init(ctx)
    return UnsafeMutableRawPointer(ctx)
}

private func sha256Append(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let ctx = context.assumingMemoryBound(to: CC_SHA256_CTX.self)
    data.withUnsafeBytes { bufPtr in
        CC_SHA256_Update(ctx, bufPtr.baseAddress!, CC_LONG(data.count))
    }
}

private func sha256Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let ctx = context.assumingMemoryBound(to: CC_SHA256_CTX.self)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, ctx)
    ctx.deallocate()
    return Data(digest)
}

// SHA512

private func sha512Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let ctx = UnsafeMutablePointer<CC_SHA512_CTX>.allocate(capacity: 1)
    CC_SHA512_Init(ctx)
    return UnsafeMutableRawPointer(ctx)
}

private func sha512Append(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let ctx = context.assumingMemoryBound(to: CC_SHA512_CTX.self)
    data.withUnsafeBytes { bufPtr in
        CC_SHA512_Update(ctx, bufPtr.baseAddress!, CC_LONG(data.count))
    }
}

private func sha512Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let ctx = context.assumingMemoryBound(to: CC_SHA512_CTX.self)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    CC_SHA512_Final(&digest, ctx)
    ctx.deallocate()
    return Data(digest)
}

// HMAC common append

private func hmacAppend(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let ctx = context.assumingMemoryBound(to: CCHmacContext.self)
    data.withUnsafeBytes { bufPtr in
        CCHmacUpdate(ctx, bufPtr.baseAddress!, data.count)
    }
}

// HMAC helper to create init/finish pairs

private func hmacInit(algorithm: CCHmacAlgorithm, key: Data?) -> UnsafeMutableRawPointer {
    let ctx = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    let k = key ?? Data()
    k.withUnsafeBytes { bufPtr in
        CCHmacInit(ctx, algorithm, bufPtr.baseAddress!, k.count)
    }
    return UnsafeMutableRawPointer(ctx)
}

private func hmacFinish(context: UnsafeMutableRawPointer, digestLength: Int) -> Data {
    let ctx = context.assumingMemoryBound(to: CCHmacContext.self)
    var digest = [UInt8](repeating: 0, count: digestLength)
    CCHmacFinal(ctx, &digest)
    ctx.deallocate()
    return Data(digest)
}

// hmacMD5
private func hmacMD5Init(_ key: Data?) -> UnsafeMutableRawPointer { hmacInit(algorithm: CCHmacAlgorithm(kCCHmacAlgMD5), key: key) }
private func hmacMD5Finish(_ ctx: UnsafeMutableRawPointer) -> Data { hmacFinish(context: ctx, digestLength: Int(CC_MD5_DIGEST_LENGTH)) }

// hmacSHA1
private func hmacSHA1Init(_ key: Data?) -> UnsafeMutableRawPointer { hmacInit(algorithm: CCHmacAlgorithm(kCCHmacAlgSHA1), key: key) }
private func hmacSHA1Finish(_ ctx: UnsafeMutableRawPointer) -> Data { hmacFinish(context: ctx, digestLength: Int(CC_SHA1_DIGEST_LENGTH)) }

// hmacSHA256
private func hmacSHA256Init(_ key: Data?) -> UnsafeMutableRawPointer { hmacInit(algorithm: CCHmacAlgorithm(kCCHmacAlgSHA256), key: key) }
private func hmacSHA256Finish(_ ctx: UnsafeMutableRawPointer) -> Data { hmacFinish(context: ctx, digestLength: Int(CC_SHA256_DIGEST_LENGTH)) }

// hmacSHA512
private func hmacSHA512Init(_ key: Data?) -> UnsafeMutableRawPointer { hmacInit(algorithm: CCHmacAlgorithm(kCCHmacAlgSHA512), key: key) }
private func hmacSHA512Finish(_ ctx: UnsafeMutableRawPointer) -> Data { hmacFinish(context: ctx, digestLength: Int(CC_SHA512_DIGEST_LENGTH)) }

// SHA3 variants

private func sha3_224_Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let box = SHA3ContextBox(sha3Init(bits: 224))
    return Unmanaged.passRetained(box).toOpaque()
}
private func sha3_256_Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let box = SHA3ContextBox(sha3Init(bits: 256))
    return Unmanaged.passRetained(box).toOpaque()
}
private func sha3_384_Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let box = SHA3ContextBox(sha3Init(bits: 384))
    return Unmanaged.passRetained(box).toOpaque()
}
private func sha3_512_Init(_ key: Data?) -> UnsafeMutableRawPointer {
    let box = SHA3ContextBox(sha3Init(bits: 512))
    return Unmanaged.passRetained(box).toOpaque()
}

private func sha3Append(_ context: UnsafeMutableRawPointer, _ data: Data) {
    let box = Unmanaged<SHA3ContextBox>.fromOpaque(context).takeUnretainedValue()
    data.withUnsafeBytes { bufPtr in
        let ptr = bufPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
        sha3Update(&box.ctx, ptr, data.count)
    }
}

private func sha3_224_Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let box = Unmanaged<SHA3ContextBox>.fromOpaque(context).takeRetainedValue()
    let result = sha3Final(&box.ctx)
    return Data(result.prefix(sha3_224_hash_size))
}
private func sha3_256_Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let box = Unmanaged<SHA3ContextBox>.fromOpaque(context).takeRetainedValue()
    let result = sha3Final(&box.ctx)
    return Data(result.prefix(sha3_256_hash_size))
}
private func sha3_384_Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let box = Unmanaged<SHA3ContextBox>.fromOpaque(context).takeRetainedValue()
    let result = sha3Final(&box.ctx)
    return Data(result.prefix(sha3_384_hash_size))
}
private func sha3_512_Finish(_ context: UnsafeMutableRawPointer) -> Data {
    let box = Unmanaged<SHA3ContextBox>.fromOpaque(context).takeRetainedValue()
    let result = sha3Final(&box.ctx)
    return Data(result.prefix(sha3_512_hash_size))
}

// MARK: - Hash Lookup Table

private let hashLookupTable: [HashEntry] = [
    HashEntry(hashName: "CRC32",      initFn: crc32Init,      appendFn: crc32Append,   finishFn: crc32Finish),
    HashEntry(hashName: "MD5",        initFn: md5Init,        appendFn: md5Append,     finishFn: md5Finish),
    HashEntry(hashName: "SHA1",       initFn: sha1Init,       appendFn: sha1Append,    finishFn: sha1Finish),
    HashEntry(hashName: "SHA256",     initFn: sha256Init,     appendFn: sha256Append,  finishFn: sha256Finish),
    HashEntry(hashName: "SHA512",     initFn: sha512Init,     appendFn: sha512Append,  finishFn: sha512Finish),
    HashEntry(hashName: "hmacMD5",    initFn: hmacMD5Init,    appendFn: hmacAppend,    finishFn: hmacMD5Finish),
    HashEntry(hashName: "hmacSHA1",   initFn: hmacSHA1Init,   appendFn: hmacAppend,    finishFn: hmacSHA1Finish),
    HashEntry(hashName: "hmacSHA256", initFn: hmacSHA256Init, appendFn: hmacAppend,    finishFn: hmacSHA256Finish),
    HashEntry(hashName: "hmacSHA512", initFn: hmacSHA512Init, appendFn: hmacAppend,    finishFn: hmacSHA512Finish),
    HashEntry(hashName: "SHA3_224",   initFn: sha3_224_Init,  appendFn: sha3Append,    finishFn: sha3_224_Finish),
    HashEntry(hashName: "SHA3_256",   initFn: sha3_256_Init,  appendFn: sha3Append,    finishFn: sha3_256_Finish),
    HashEntry(hashName: "SHA3_384",   initFn: sha3_384_Init,  appendFn: sha3Append,    finishFn: sha3_384_Finish),
    HashEntry(hashName: "SHA3_512",   initFn: sha3_512_Init,  appendFn: sha3Append,    finishFn: sha3_512_Finish),
]

// MARK: - HSHashObject

private let USERDATA_TAG = "hs.hash"
private var refTable: LSRefTable = LUA_NOREF

private class HSHashObjectNew: NSObject {
    var selfRefCount: Int = 0
    let hashType: Int
    let secret: Data?
    var context: UnsafeMutableRawPointer?
    var value: Data?

    init(hashType: Int, secret: Data?) {
        self.hashType = hashType
        self.secret = secret
        self.context = hashLookupTable[hashType].initFn(secret)
        self.value = nil
        super.init()
    }

    func append(_ data: Data) {
        hashLookupTable[hashType].appendFn(context!, data)
    }

    func finish() {
        value = hashLookupTable[hashType].finishFn(context!)
        context = nil // freed in finish function
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
private func hash_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let hashName = skin.toNSObject(atIndex: 1) as! String
    var secret: Data? = nil
    if lua_gettop(L) == 2 {
        if let nsdata = skin.toNSObject(atIndex: 2, withOptions: .nsLuaStringAsDataOnly) as? NSData {
            secret = nsdata as Data
        }
    }

    var hashType = 0
    var hashFound = false

    for i in 0..<hashLookupTable.count {
        if hashName.caseInsensitiveCompare(hashLookupTable[i].hashName) == .orderedSame {
            hashFound = true
            hashType = i
            break
        }
    }

    if hashFound {
        let object = HSHashObjectNew(hashType: hashType, secret: secret)
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
private func hash_append(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObjectNew
    let nsdata = skin.toNSObject(atIndex: 2, withOptions: .nsLuaStringAsDataOnly) as! NSData
    let data = nsdata as Data

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
private func hash_appendFile(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObjectNew
    var path = skin.toNSObject(atIndex: 2) as! String

    if object.value == nil {
        path = (path as NSString).expandingTildeInPath
        path = (path as NSString).resolvingSymlinksInPath
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .uncached)
            object.append(data)
        } catch {
            lua_pushnil(L)
            lua_pushstring(L, "error reading contents of \(path): \(error.localizedDescription)")
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
private func hash_finish(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObjectNew

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
private func hash_value(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObjectNew
    let inBinary = (lua_gettop(L) == 2) ? (lua_toboolean(L, 2) != 0) : false

    if let val = object.value {
        if inBinary {
            skin.pushNSObject(val as NSData)
        } else {
            var hex = ""
            hex.reserveCapacity(val.count * 2)
            for byte in val {
                hex += String(format: "%02x", byte)
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
private func hash_type(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let object = skin.toNSObject(atIndex: 1) as! HSHashObjectNew
    lua_pushstring(L, hashLookupTable[object.hashType].hashName)
    return 1
}

// MARK: - Module Constants

// documented in hash.lua
private func hash_types(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    for i in 0..<hashLookupTable.count {
        lua_pushstring(L, hashLookupTable[i].hashName)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSHashObjectNew(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    guard let value = obj as? HSHashObjectNew else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSHashObjectNewFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        return Unmanaged<HSHashObjectNew>.fromOpaque(ptr.pointee).takeUnretainedValue()
    } else {
        skin.logError("\(USERDATA_TAG) expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

/// Helper to extract HSHashObjectNew from userdata at a given stack index.
private func getHashObject(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSHashObjectNew? {
    guard luaL_testudata(L, idx, USERDATA_TAG) != nil else { return nil }
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    return Unmanaged<HSHashObjectNew>.fromOpaque(ptr.pointee).takeUnretainedValue()
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let obj = getHashObject(L, at: 1) else { return 0 }
    var title = hashLookupTable[obj.hashType].hashName
    if obj.value == nil {
        title = "\(title) <in-progress>"
    }
    let desc = "\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1))))"
    lua_pushstring(L, desc)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let obj1 = getHashObject(L, at: 1), let obj2 = getHashObject(L, at: 2) {
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let opaquePtr = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    let obj = Unmanaged<HSHashObjectNew>.fromOpaque(opaquePtr).takeRetainedValue()
    obj.selfRefCount -= 1
    if obj.selfRefCount == 0 {
        if obj.context != nil { obj.finish() }
    }
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Lua Registration Tables

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("append"),     func: hash_append),
    luaL_Reg(name: strdup("appendFile"), func: hash_appendFile),
    luaL_Reg(name: strdup("finish"),     func: hash_finish),
    luaL_Reg(name: strdup("value"),      func: hash_value),
    luaL_Reg(name: strdup("type"),       func: hash_type),

    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),       func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),       func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: hash_new),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libhash")
public func luaopen_hs_libhash(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    _ = hash_types(L); lua_setfield(L, -2, "types")

    skin.registerPushNSHelper(pushHSHashObjectNew, forClass: "HSHashObjectNew")
    skin.registerLuaObjectHelper(toHSHashObjectNewFromLua, forClass: "HSHashObjectNew",
                                 withUserdataMapping: USERDATA_TAG)

    return 1
}
