import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class SettingsFunctionalTests {
        /// Unique key prefix to avoid collisions with real settings
        private let keyPrefix = "hs_functional_test_\(UUID().uuidString)_"

        @Test func testSetAndGet() {
            withModuleLoaded(luaopen_hs_libsettings) { L in
                let key = keyPrefix + "set_get"
                defer { UserDefaults.standard.removeObject(forKey: key) }

                // Set a string value
                #expect(luaEval(L, "mod.set('\(key)', 'hello_world')"))

                // Get it back
                #expect(luaEval(L, "return mod.get('\(key)')"))
                #expect(lua_type(L, -1) == LUA_TSTRING)
                #expect(String(cString: lua_tostring(L, -1)) == "hello_world")
                lua_pop(L, 1)

                // Set a number
                #expect(luaEval(L, "mod.set('\(key)', 42)"))
                #expect(luaEval(L, "return mod.get('\(key)')"))
                #expect(lua_type(L, -1) == LUA_TNUMBER)
                #expect(lua_tonumber(L, -1) == 42.0)
                lua_pop(L, 1)

                // Set a boolean
                #expect(luaEval(L, "mod.set('\(key)', true)"))
                #expect(luaEval(L, "return mod.get('\(key)')"))
                #expect(lua_toboolean(L, -1) != 0)
            }
        }

        @Test func testGetNonexistent() {
            withModuleLoaded(luaopen_hs_libsettings) { L in
                let key = keyPrefix + "nonexistent_key_xyz"
                // Getting a nonexistent key should return nil
                #expect(luaEval(L, "return mod.get('\(key)')"))
                #expect(lua_type(L, -1) == LUA_TNIL)
            }
        }

        @Test func testClear() {
            withModuleLoaded(luaopen_hs_libsettings) { L in
                let key = keyPrefix + "clear"
                defer { UserDefaults.standard.removeObject(forKey: key) }

                // Set a value
                #expect(luaEval(L, "mod.set('\(key)', 'to_be_cleared')"))

                // Verify it exists
                #expect(luaEval(L, "return mod.get('\(key)')"))
                #expect(lua_type(L, -1) == LUA_TSTRING)
                lua_pop(L, 1)

                // Clear it
                #expect(luaEval(L, "return mod.clear('\(key)')"))
                #expect(lua_toboolean(L, -1) != 0, "clear should return true for existing key")
                lua_pop(L, 1)

                // Verify it's gone
                #expect(luaEval(L, "return mod.get('\(key)')"))
                #expect(lua_type(L, -1) == LUA_TNIL)
                lua_pop(L, 1)

                // Clearing again should return false
                #expect(luaEval(L, "return mod.clear('\(key)')"))
                #expect(lua_toboolean(L, -1) == 0, "clear should return false for nonexistent key")
            }
        }
    }
}
