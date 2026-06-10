import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class Base64FunctionalTests {
        @Test func testEncodeString() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._encode('hello')"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "aGVsbG8=")
            }
        }

        @Test func testDecodeString() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._decode('aGVsbG8=')"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "hello")
            }
        }

        @Test func testRoundTrip() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._decode(mod._encode('Cosmic Hammer!'))"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "Cosmic Hammer!")
            }
        }

        @Test func testEncodeEmptyString() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                #expect(luaEval(L, "result = mod._encode('')"))
                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "")
            }
        }

        @Test func testEncodeBinaryData() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // Encode a string with null bytes and high bytes
                #expect(luaEval(L, "result = mod._encode('\\x00\\x01\\xff')"))
                lua_getglobal(L, "result")
                let encoded = String(cString: lua_tostring(L, -1))
                // Verify round-trip: decode it and check length is 3
                #expect(luaEval(L, "decoded = mod._decode(result)"))
                lua_getglobal(L, "decoded")
                var len: Int = 0
                _ = lua_tolstring(L, -1, &len)
                #expect(len == 3)
                // Also verify the base64 encoding is non-empty
                #expect(!encoded.isEmpty)
            }
        }

        // MARK: - Binary safety proof tests (WP1)

        @Test func testEmbeddedNUL() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // Push a 3-byte string: 'a', NUL, 'b'
                let input: [UInt8] = [0x61, 0x00, 0x62]
                lua_pushlstring(L, input.map { CChar(bitPattern: $0) }, input.count)
                lua_setglobal(L, "input")

                #expect(luaEval(L, "encoded = mod._encode(input)"))
                lua_getglobal(L, "encoded")
                var encLen: Int = 0
                let encPtr = lua_tolstring(L, -1, &encLen)!
                let encBytes = Array(UnsafeBufferPointer(start: encPtr, count: encLen))
                    .map { UInt8(bitPattern: $0) }
                // "YQBi" is base64 for [0x61, 0x00, 0x62]
                #expect(String(bytes: encBytes, encoding: .ascii) == "YQBi")
                lua_pop(L, 1)

                // Decode back and verify exact bytes
                #expect(luaEval(L, "decoded = mod._decode(encoded)"))
                lua_getglobal(L, "decoded")
                var decLen: Int = 0
                let decPtr = lua_tolstring(L, -1, &decLen)!
                let decBytes = Array(UnsafeBufferPointer(start: decPtr, count: decLen))
                    .map { UInt8(bitPattern: $0) }
                #expect(decLen == 3, "Expected 3 bytes, got \(decLen)")
                #expect(decBytes == input, "Round-trip bytes mismatch")
            }
        }

        @Test func testFullByteRange() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // Build a 256-byte input with every byte value 0x00..0xFF
                var input = [UInt8](repeating: 0, count: 256)
                for i in 0..<256 { input[i] = UInt8(i) }
                lua_pushlstring(L, input.map { CChar(bitPattern: $0) }, input.count)
                lua_setglobal(L, "input")

                #expect(luaEval(L, "encoded = mod._encode(input)"))
                #expect(luaEval(L, "decoded = mod._decode(encoded)"))

                lua_getglobal(L, "decoded")
                var decLen: Int = 0
                let decPtr = lua_tolstring(L, -1, &decLen)!
                let decBytes = Array(UnsafeBufferPointer(start: decPtr, count: decLen))
                    .map { UInt8(bitPattern: $0) }

                #expect(decLen == 256, "Expected 256 bytes, got \(decLen)")
                #expect(decBytes == input, "Full byte-range round-trip mismatch")
            }
        }

        @Test func testInvalidUTF8() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // Invalid UTF-8 sequence: 0xC3 followed by 0x28
                let input: [UInt8] = [0xC3, 0x28]
                lua_pushlstring(L, input.map { CChar(bitPattern: $0) }, input.count)
                lua_setglobal(L, "input")

                #expect(luaEval(L, "encoded = mod._encode(input)"))
                #expect(luaEval(L, "decoded = mod._decode(encoded)"))

                lua_getglobal(L, "decoded")
                var decLen: Int = 0
                let decPtr = lua_tolstring(L, -1, &decLen)!
                let decBytes = Array(UnsafeBufferPointer(start: decPtr, count: decLen))
                    .map { UInt8(bitPattern: $0) }

                #expect(decLen == 2, "Expected 2 bytes, got \(decLen)")
                #expect(decBytes == input, "Invalid UTF-8 round-trip mismatch")
            }
        }

        @Test func testLargeInput() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // 100KB of pseudo-random bytes (deterministic seed via index)
                let size = 100 * 1024
                var input = [UInt8](repeating: 0, count: size)
                for i in 0..<size { input[i] = UInt8(truncatingIfNeeded: i &* 37 &+ 13) }
                lua_pushlstring(L, input.map { CChar(bitPattern: $0) }, input.count)
                lua_setglobal(L, "input")

                #expect(luaEval(L, "encoded = mod._encode(input)"))
                #expect(luaEval(L, "decoded = mod._decode(encoded)"))

                lua_getglobal(L, "decoded")
                var decLen: Int = 0
                let decPtr = lua_tolstring(L, -1, &decLen)!
                let decBytes = Array(UnsafeBufferPointer(start: decPtr, count: decLen))
                    .map { UInt8(bitPattern: $0) }

                #expect(decLen == size, "Expected \(size) bytes, got \(decLen)")
                #expect(decBytes == input, "Large input round-trip mismatch")
            }
        }

        @Test func testSecTransformFailure() {
            withModuleLoaded(luaopen_hs_libbase64) { L in
                // Decoding an invalid base64 string — SecTransform may fail
                // gracefully. We just verify no crash; either an error or empty
                // result is acceptable.
                let result = luaEval(L, "ok, err = pcall(mod._decode, '!@#$%')")
                #expect(result, "pcall itself should not error")
                // If decode succeeded, ok is true and result is on stack.
                // If it failed, ok is false and err is the error message.
                // Either way, we survived without crashing.
            }
        }
    }
}
