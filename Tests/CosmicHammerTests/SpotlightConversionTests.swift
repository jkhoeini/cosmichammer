#if DEBUG
import Foundation
import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class SpotlightConversionTests {
        @Test func testAttributeValueTupleValueUsesSpotlightSpecificConversion() {
            withLuaState { L in
                let descriptor = NSSortDescriptor(key: "kMDItemDisplayName", ascending: false)

                pushSpotlightAttributeValueTupleFieldsForTesting(
                    L,
                    attribute: "kMDItemDisplayName",
                    count: 1,
                    value: descriptor
                )

                lua_getfield(L, -1, "value")
                guard lua_type(L, -1) == LUA_TTABLE else {
                    Issue.record("tuple value should be converted as a Spotlight table")
                    return
                }

                lua_getfield(L, -1, "key")
                #expect(lua_tostringValue(L, at: -1) == "kMDItemDisplayName")
                lua_pop(L, 1)

                lua_getfield(L, -1, "ascending")
                #expect(lua_toboolean(L, -1) == 0)
                lua_pop(L, 1)

                lua_getfield(L, -1, "__luaSkinType")
                #expect(lua_tostringValue(L, at: -1) == "NSSortDescriptor")
                lua_pop(L, 2)
            }
        }
    }
}
#endif
