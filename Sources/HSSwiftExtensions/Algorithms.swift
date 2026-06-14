import Cocoa
import CommonCrypto
import zlib

// MARK: - CRC32

@_cdecl("init_CRC32")
func init_CRC32(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
    context.pointee = UInt(crc32_z(0, nil, 0))
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_CRC32")
func append_CRC32(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    precondition(data.length >= 0, "data length must be non-negative")
    let context = _context.assumingMemoryBound(to: UInt.self)
    context.pointee = UInt(crc32_z(uLong(context.pointee), data.bytes.assumingMemoryBound(to: UInt8.self), data.length))
}

@_cdecl("finish_CRC32")
func finish_CRC32(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: UInt.self)
    let crc = context.pointee

    var asBytes: [UInt8] = [
        UInt8((crc >> 24) & 0xff),
        UInt8((crc >> 16) & 0xff),
        UInt8((crc >>  8) & 0xff),
        UInt8( crc        & 0xff),
    ]

    context.deallocate()
    let result = NSData(bytes: &asBytes, length: 4)
    assert(result.length == 4, "CRC32 digest must be exactly 4 bytes")
    return result
}

// MARK: - MD2

@_cdecl("init_MD2")
func init_MD2(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_MD2_CTX>.allocate(capacity: 1)
    CC_MD2_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_MD2")
func append_MD2(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_MD2_CTX.self)
    CC_MD2_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_MD2")
func finish_MD2(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_MD2_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_MD2_DIGEST_LENGTH))
    CC_MD2_Final(md, context)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_MD2_DIGEST_LENGTH))
}

// MARK: - MD4

@_cdecl("init_MD4")
func init_MD4(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_MD4_CTX>.allocate(capacity: 1)
    CC_MD4_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_MD4")
func append_MD4(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_MD4_CTX.self)
    CC_MD4_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_MD4")
func finish_MD4(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_MD4_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_MD4_DIGEST_LENGTH))
    CC_MD4_Final(md, context)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_MD4_DIGEST_LENGTH))
}

// MARK: - MD5

@_cdecl("init_MD5")
func init_MD5(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_MD5_CTX>.allocate(capacity: 1)
    CC_MD5_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_MD5")
func append_MD5(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_MD5_CTX.self)
    CC_MD5_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_MD5")
func finish_MD5(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_MD5_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_MD5_DIGEST_LENGTH))
    CC_MD5_Final(md, context)
    context.deallocate()
    let result = NSData(bytesNoCopy: md, length: Int(CC_MD5_DIGEST_LENGTH))
    assert(result.length == Int(CC_MD5_DIGEST_LENGTH), "MD5 digest must be exactly \(CC_MD5_DIGEST_LENGTH) bytes")
    return result
}

// MARK: - SHA1

@_cdecl("init_SHA1")
func init_SHA1(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_SHA1_CTX>.allocate(capacity: 1)
    CC_SHA1_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_SHA1")
func append_SHA1(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_SHA1_CTX.self)
    CC_SHA1_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_SHA1")
func finish_SHA1(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_SHA1_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA1_DIGEST_LENGTH))
    CC_SHA1_Final(md, context)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA1_DIGEST_LENGTH))
}

// MARK: - SHA224

@_cdecl("init_SHA224")
func init_SHA224(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_SHA256_CTX>.allocate(capacity: 1)
    CC_SHA224_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_SHA224")
func append_SHA224(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_SHA256_CTX.self)
    CC_SHA224_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_SHA224")
func finish_SHA224(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_SHA256_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA224_DIGEST_LENGTH))
    CC_SHA224_Final(md, context)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA224_DIGEST_LENGTH))
}

// MARK: - SHA256

@_cdecl("init_SHA256")
func init_SHA256(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_SHA256_CTX>.allocate(capacity: 1)
    CC_SHA256_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_SHA256")
func append_SHA256(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_SHA256_CTX.self)
    CC_SHA256_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_SHA256")
func finish_SHA256(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_SHA256_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(md, context)
    context.deallocate()
    let result = NSData(bytesNoCopy: md, length: Int(CC_SHA256_DIGEST_LENGTH))
    assert(result.length == Int(CC_SHA256_DIGEST_LENGTH), "SHA256 digest must be exactly \(CC_SHA256_DIGEST_LENGTH) bytes")
    return result
}

// MARK: - SHA384

@_cdecl("init_SHA384")
func init_SHA384(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_SHA512_CTX>.allocate(capacity: 1)
    CC_SHA384_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_SHA384")
func append_SHA384(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_SHA512_CTX.self)
    CC_SHA384_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_SHA384")
func finish_SHA384(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_SHA512_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA384_DIGEST_LENGTH))
    CC_SHA384_Final(md, context)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA384_DIGEST_LENGTH))
}

// MARK: - SHA512

@_cdecl("init_SHA512")
func init_SHA512(_ key: NSData?) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CC_SHA512_CTX>.allocate(capacity: 1)
    CC_SHA512_Init(context)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("append_SHA512")
func append_SHA512(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CC_SHA512_CTX.self)
    CC_SHA512_Update(context, data.bytes, CC_LONG(data.length))
}

@_cdecl("finish_SHA512")
func finish_SHA512(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CC_SHA512_CTX.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA512_DIGEST_LENGTH))
    CC_SHA512_Final(md, context)
    context.deallocate()
    let result = NSData(bytesNoCopy: md, length: Int(CC_SHA512_DIGEST_LENGTH))
    assert(result.length == Int(CC_SHA512_DIGEST_LENGTH), "SHA512 digest must be exactly \(CC_SHA512_DIGEST_LENGTH) bytes")
    return result
}

// MARK: - hmacMD5

@_cdecl("init_hmacMD5")
func init_hmacMD5(_ key: NSData) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    CCHmacInit(context, CCHmacAlgorithm(kCCHmacAlgMD5), key.bytes, key.length)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("finish_hmacMD5")
func finish_hmacMD5(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_MD5_DIGEST_LENGTH))
    CCHmacFinal(context, md)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_MD5_DIGEST_LENGTH))
}

// MARK: - hmacSHA1

@_cdecl("init_hmacSHA1")
func init_hmacSHA1(_ key: NSData) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    CCHmacInit(context, CCHmacAlgorithm(kCCHmacAlgSHA1), key.bytes, key.length)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("finish_hmacSHA1")
func finish_hmacSHA1(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA1_DIGEST_LENGTH))
    CCHmacFinal(context, md)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA1_DIGEST_LENGTH))
}

// MARK: - hmacSHA224

@_cdecl("init_hmacSHA224")
func init_hmacSHA224(_ key: NSData) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    CCHmacInit(context, CCHmacAlgorithm(kCCHmacAlgSHA224), key.bytes, key.length)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("finish_hmacSHA224")
func finish_hmacSHA224(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA224_DIGEST_LENGTH))
    CCHmacFinal(context, md)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA224_DIGEST_LENGTH))
}

// MARK: - hmacSHA256

@_cdecl("init_hmacSHA256")
func init_hmacSHA256(_ key: NSData) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    CCHmacInit(context, CCHmacAlgorithm(kCCHmacAlgSHA256), key.bytes, key.length)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("finish_hmacSHA256")
func finish_hmacSHA256(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA256_DIGEST_LENGTH))
    CCHmacFinal(context, md)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA256_DIGEST_LENGTH))
}

// MARK: - hmacSHA384

@_cdecl("init_hmacSHA384")
func init_hmacSHA384(_ key: NSData) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    CCHmacInit(context, CCHmacAlgorithm(kCCHmacAlgSHA384), key.bytes, key.length)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("finish_hmacSHA384")
func finish_hmacSHA384(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA384_DIGEST_LENGTH))
    CCHmacFinal(context, md)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA384_DIGEST_LENGTH))
}

// MARK: - hmacSHA512

@_cdecl("init_hmacSHA512")
func init_hmacSHA512(_ key: NSData) -> UnsafeMutableRawPointer {
    let context = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    CCHmacInit(context, CCHmacAlgorithm(kCCHmacAlgSHA512), key.bytes, key.length)
    return UnsafeMutableRawPointer(context)
}

@_cdecl("finish_hmacSHA512")
func finish_hmacSHA512(_ _context: UnsafeMutableRawPointer) -> NSData {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    let md = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(CC_SHA512_DIGEST_LENGTH))
    CCHmacFinal(context, md)
    context.deallocate()
    return NSData(bytesNoCopy: md, length: Int(CC_SHA512_DIGEST_LENGTH))
}

// MARK: - hmac common

@_cdecl("append_hmac")
func append_hmac(_ _context: UnsafeMutableRawPointer, _ data: NSData) {
    let context = _context.assumingMemoryBound(to: CCHmacContext.self)
    CCHmacUpdate(context, data.bytes, data.length)
}
