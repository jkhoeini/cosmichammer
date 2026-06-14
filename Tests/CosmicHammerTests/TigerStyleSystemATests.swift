import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class TigerStyleSystemATests {

        // MARK: - Application module: entry point loads without assertion failure

        @Test func testApplicationModuleLoads() {
            withModuleLoaded(luaopen_hs_libapplication_new) { L in
                // Module table should be on the stack and accessible as "mod"
                lua_getglobal(L, "mod")
                #expect(lua_type(L, -1) == LUA_TTABLE,
                        "Application module should return a table")
                lua_pop(L, 1)
            }
        }

        // MARK: - FileSystem module: path_to_nsurl produces valid file URLs

        @Test func testFSModuleLoadsAndTempDir() {
            withModuleLoaded(luaopen_hs_libfs) { L in
                // temporaryDirectory should return a non-empty string
                #expect(luaEval(L, "result = mod.temporaryDirectory()"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING,
                        "temporaryDirectory() should return a string")
                let tmpDir = String(cString: lua_tostring(L, -1))
                #expect(!tmpDir.isEmpty, "temporaryDirectory() should not be empty")
                #expect(tmpDir.hasSuffix("/"), "temporaryDirectory() should end with /")
                lua_pop(L, 1)
            }
        }

        // MARK: - FileSystem: pathToAbsolute resolves relative paths

        @Test func testFSPathToAbsolute() {
            withModuleLoaded(luaopen_hs_libfs) { L in
                #expect(luaEval(L, "result = mod.pathToAbsolute('/tmp')"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING,
                        "pathToAbsolute('/tmp') should return a string")
                let resolved = String(cString: lua_tostring(L, -1))
                // /tmp is a symlink to /private/tmp on macOS
                #expect(resolved == "/private/tmp" || resolved == "/tmp",
                        "pathToAbsolute should resolve /tmp correctly, got: \(resolved)")
                lua_pop(L, 1)
            }
        }

        // MARK: - FileSystem: attributes on known directory

        @Test func testFSAttributesOnTmp() {
            withModuleLoaded(luaopen_hs_libfs) { L in
                #expect(luaEval(L, "result = mod.attributes('/tmp', 'mode')"))
                lua_getglobal(L, "result")
                #expect(lua_type(L, -1) == LUA_TSTRING,
                        "attributes('/tmp', 'mode') should return a string")
                let mode = String(cString: lua_tostring(L, -1))
                // /tmp is a symlink, but stat() follows symlinks so mode should be "directory"
                #expect(mode == "directory",
                        "attributes mode of /tmp should be 'directory', got '\(mode)'")
                lua_pop(L, 1)
            }
        }

        // MARK: - Spotlight module: module entry point loads cleanly

        @Test func testSpotlightModuleLoads() {
            withModuleLoaded(luaopen_hs_libspotlight) { L in
                lua_getglobal(L, "mod")
                #expect(lua_type(L, -1) == LUA_TTABLE,
                        "Spotlight module should return a table")

                // Verify definedSearchScopes is a table
                lua_getfield(L, -1, "definedSearchScopes")
                #expect(lua_type(L, -1) == LUA_TTABLE,
                        "definedSearchScopes should be a table")
                lua_pop(L, 1)

                // Verify commonAttributeKeys is a table
                lua_getfield(L, -1, "commonAttributeKeys")
                #expect(lua_type(L, -1) == LUA_TTABLE,
                        "commonAttributeKeys should be a table")
                let keyCount = luaL_len(L, -1)
                #expect(keyCount > 50,
                        "commonAttributeKeys should have many entries, got \(keyCount)")
                lua_pop(L, 2)
            }
        }
    }
}
