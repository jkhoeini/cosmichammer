import Testing
import CLua
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_liblocation")
private func luaopen_hs_liblocation(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class LocationConversionTests {
        @Test func testDistanceAcceptsMinimalLocationTables() throws {
            try withModuleLoaded(luaopen_hs_liblocation) { L in
                let meters = luaEvalNumber(L, """
                return mod.distance(
                    { latitude = 0, longitude = 0 },
                    { latitude = 0, longitude = 1 }
                )
                """)

                let value = try #require(meters)
                #expect(value > 110_000)
                #expect(value < 112_000)
            }
        }

        @Test func testDistanceRejectsMalformedLocationTable() throws {
            try withModuleLoaded(luaopen_hs_liblocation) { L in
                let message = try #require(luaErrorMsg(L, """
                return mod.distance(
                    { latitude = 0 },
                    { latitude = 0, longitude = 1 }
                )
                """))

                #expect(message.contains("expected locationTable"))
            }
        }

        @Test func testSunriseRejectsMalformedLocationTable() throws {
            try withModuleLoaded(luaopen_hs_liblocation) { L in
                let message = try #require(luaErrorMsg(L, """
                return mod.sunrise({ latitude = 0 }, 0)
                """))

                #expect(message.contains("expected locationTable"))
            }
        }
    }
}
