import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class MathFunctionalTests {
        @Test func testRandomFloat() {
            withModuleLoaded(luaopen_hs_libmath) { L in
                // Call randomFloat 10 times, verify each is in [0, 1]
                for _ in 0..<10 {
                    #expect(luaEval(L, "return mod.randomFloat()"))
                    let val = lua_tonumber(L, -1)
                    #expect(val >= 0.0 && val <= 1.0, "randomFloat returned \(val), expected [0, 1]")
                    lua_pop(L, 1)
                }
            }
        }

        @Test func testRandomFromRange() {
            withModuleLoaded(luaopen_hs_libmath) { L in
                // Call randomFromRange(5, 10) 20 times, verify each is in [5, 10]
                for _ in 0..<20 {
                    #expect(luaEval(L, "return mod.randomFromRange(5, 10)"))
                    let val = lua_tointeger(L, -1)
                    #expect(val >= 5 && val <= 10, "randomFromRange returned \(val), expected [5, 10]")
                    lua_pop(L, 1)
                }
            }
        }
    }
}
