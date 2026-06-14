import Testing
import CLua
import Foundation
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_liblocation")
private func luaopen_hs_liblocation(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class TigerStyleSystemBTests {

        // MARK: - Location module assertions

        @Test func testLocationDistanceDoesNotFireAssertions() throws {
            try withModuleLoaded(luaopen_hs_liblocation) { L in
                // Exercise the distance function which now has precondition(L != nil)
                // and assert(distance >= 0) -- verify no assertions fire on valid inputs
                let meters = luaEvalNumber(L, """
                return mod.distance(
                    { latitude = 37.7749, longitude = -122.4194 },
                    { latitude = 34.0522, longitude = -118.2437 }
                )
                """)
                let value = try #require(meters)
                #expect(value > 0, "Distance between two distinct points must be positive")
                #expect(value < 1_000_000, "SF-to-LA distance should be less than 1000km")
            }
        }

        @Test func testLocationDistanceZeroForSamePoint() throws {
            try withModuleLoaded(luaopen_hs_liblocation) { L in
                // Distance from a point to itself should be zero -- validates the
                // non-negative assertion holds at the boundary
                let meters = luaEvalNumber(L, """
                return mod.distance(
                    { latitude = 51.5074, longitude = -0.1278 },
                    { latitude = 51.5074, longitude = -0.1278 }
                )
                """)
                let value = try #require(meters)
                #expect(value == 0, "Distance from a point to itself must be zero")
            }
        }

        @Test func testLocationDstOffsetDoesNotFireAssertions() throws {
            try withModuleLoaded(luaopen_hs_liblocation) { L in
                // dstOffset returns a TimeInterval -- just verify it returns a number
                // without firing any assertions
                let offset = luaEvalNumber(L, "return mod.dstOffset()")
                // offset can be 0 or positive depending on timezone; just verify it is a number
                #expect(offset != nil, "dstOffset must return a number")
            }
        }

        // MARK: - Algorithms / hash assertions

        @Test func testCRC32DigestLength() {
            let ctx = init_CRC32(nil)
            let data = "hello".data(using: .utf8)!
            append_CRC32(ctx, data as NSData)
            let result = finish_CRC32(ctx)
            // The finish_CRC32 assertion checks result.length == 4
            #expect(result.length == 4, "CRC32 digest must be 4 bytes")
        }

        @Test func testSHA256DigestLength() {
            let ctx = init_SHA256(nil)
            let data = "test data for sha256".data(using: .utf8)!
            append_SHA256(ctx, data as NSData)
            let result = finish_SHA256(ctx)
            // The finish_SHA256 assertion checks result.length == CC_SHA256_DIGEST_LENGTH (32)
            #expect(result.length == 32, "SHA256 digest must be 32 bytes")
        }
    }
}
