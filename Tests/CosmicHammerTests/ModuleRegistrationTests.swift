import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

// Forward declarations for the C-visible entry points in HSExtensions.
// These are provided by the HSExtensions module (linked into the test target).
@_silgen_name("luaopen_hs_libbase64")
private func luaopen_hs_libbase64(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libmath")
private func luaopen_hs_libmath(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libjson")
private func luaopen_hs_libjson(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libhash")
private func luaopen_hs_libhash(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libcrash")
private func luaopen_hs_libcrash(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libbrightness")
private func luaopen_hs_libbrightness(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libhid")
private func luaopen_hs_libhid(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libusb")
private func luaopen_hs_libusb(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libmouse")
private func luaopen_hs_libmouse(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libsettings")
private func luaopen_hs_libsettings(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libplist")
private func luaopen_hs_libplist(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libmarkdown")
private func luaopen_hs_libmarkdown(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libosascript")
private func luaopen_hs_libosascript(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libopentelemetry")
private func luaopen_hs_libopentelemetry(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libhost")
private func luaopen_hs_libhost(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libhost_locale")
private func luaopen_hs_libhost_locale(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {

    @Suite(.serialized) final class ModuleRegistrationTests {

        /// Helper: call a luaopen_* function and verify it returns 1 and
        /// leaves a table on the stack.
        private func assertRegisters(
            _ openFn: (UnsafeMutablePointer<lua_State>?) -> Int32,
            name: String
        ) {
            withLuaState { L in
                let result = openFn(L)
                #expect(result == 1, "\(name) should return 1, got \(result)")
                #expect(lua_type(L, -1) == LUA_TTABLE,
                    "\(name) should push a table, got type \(lua_type(L, -1))")
            }
        }

        @Test func testBase64Registration() {
            assertRegisters(luaopen_hs_libbase64, name: "hs.base64")
        }

        @Test func testMathRegistration() {
            assertRegisters(luaopen_hs_libmath, name: "hs.math")
        }

        @Test func testJsonRegistration() {
            assertRegisters(luaopen_hs_libjson, name: "hs.json")
        }

        @Test func testHashRegistration() {
            assertRegisters(luaopen_hs_libhash, name: "hs.hash")
        }

        @Test func testCrashRegistration() {
            assertRegisters(luaopen_hs_libcrash, name: "hs.crash")
        }

        @Test func testBrightnessRegistration() {
            assertRegisters(luaopen_hs_libbrightness, name: "hs.brightness")
        }

        @Test func testHIDRegistration() {
            assertRegisters(luaopen_hs_libhid, name: "hs.hid")
        }

        @Test func testUSBRegistration() {
            assertRegisters(luaopen_hs_libusb, name: "hs.usb")
        }

        @Test func testMouseRegistration() {
            assertRegisters(luaopen_hs_libmouse, name: "hs.mouse")
        }

        @Test func testSettingsRegistration() {
            assertRegisters(luaopen_hs_libsettings, name: "hs.settings")
        }

        @Test func testPlistRegistration() {
            assertRegisters(luaopen_hs_libplist, name: "hs.plist")
        }

        @Test func testMarkdownRegistration() {
            assertRegisters(luaopen_hs_libmarkdown, name: "hs.doc.markdown")
        }

        @Test func testOsascriptRegistration() {
            assertRegisters(luaopen_hs_libosascript, name: "hs.osascript")
        }

        @Test func testOpenTelemetryRegistration() {
            assertRegisters(luaopen_hs_libopentelemetry, name: "hs.opentelemetry")
        }

        @Test func testHostRegistration() {
            assertRegisters(luaopen_hs_libhost, name: "hs.host")
        }

        @Test func testHostLocaleRegistration() {
            assertRegisters(luaopen_hs_libhost_locale, name: "hs.host.locale")
        }

        // Verify that registering a module that sets up metatables (hash)
        // leaves a clean stack with exactly 1 table.
        @Test func testHashRegistrationStackClean() {
            withLuaState { L in
                let before = lua_gettop(L)
                _ = luaopen_hs_libhash(L)
                let after = lua_gettop(L)
                #expect(after - before == 1,
                    "luaopen_hs_libhash should push exactly 1 value, pushed \(after - before)")
            }
        }

        // Verify that the hash module table exposes the expected "new" constructor
        @Test func testHashModuleHasNewFunction() {
            withLuaState { L in
                _ = luaopen_hs_libhash(L)
                lua_getfield(L, -1, "new")
                #expect(lua_type(L, -1) == LUA_TFUNCTION,
                    "hs.hash table should have a 'new' function")
            }
        }

        // Verify that the hash module table exposes the "types" constant
        @Test func testHashModuleHasTypesTable() {
            withLuaState { L in
                _ = luaopen_hs_libhash(L)
                lua_getfield(L, -1, "types")
                #expect(lua_type(L, -1) == LUA_TTABLE,
                    "hs.hash table should have a 'types' table")
                let len = luaL_len(L, -1)
                #expect(len > 0, "hs.hash.types should not be empty")
            }
        }
    }
}
