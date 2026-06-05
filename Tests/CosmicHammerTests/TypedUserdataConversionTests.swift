import AppKit
import CLua
import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class TypedUserdataConversionTests {
        @Test func testDialogWebviewWindowFromLuaExtractsWebviewUserdata() throws {
            try withBootstrappedLua(requiring: ["hs.webview"]) { L in
                let window = HSWebViewWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: true
                )

                #expect(wv_HSWebViewWindow_toLua(L, window) == 1)
                let extracted = try #require(dialog_webviewWindowFromLua(L: L, at: -1))
                #expect(extracted === window)
                lua_pop(L, 1)
            }
        }

        @Test func testToolbarPushProducesToolbarUserdata() throws {
            try withBootstrappedLua(requiring: ["hs.webview.toolbar"]) { L in
                let toolbar = try #require(HSToolbar(
                    identifier: "typed-userdata-toolbar-\(UUID().uuidString)",
                    itemTableIndex: LUA_NOREF,
                    state: L
                ))

                #expect(toolbar_pushHSToolbar(L, toolbar) == 1)
                #expect(luaL_testudata(L, -1, "hs.webview.toolbar") != nil)
                #expect(lua_toAnyObject(L, at: -1) as? HSToolbar === toolbar)
                lua_pop(L, 1)
            }
        }

        @Test func testToolbarWindowContextPreservesWebviewUserdata() {
            withBootstrappedLua(requiring: ["hs.webview", "hs.webview.toolbar"]) { L in
                let window = HSWebViewWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: true
                )

                #expect(toolbar_pushWindowContext(L, window) == 1)
                #expect(luaL_testudata(L, -1, "hs.webview") != nil)
                #expect(wv_getWindowFromUD(L, -1) === window)
                lua_pop(L, 1)
            }
        }

        @Test func testToolbarWindowContextPreservesChooserUserdata() throws {
            try withBootstrappedLua(requiring: ["hs.chooser", "hs.webview.toolbar"]) { L in
                let chooser = HSChooser(refTable: LUA_NOREF, completionCallbackRef: LUA_NOREF)
                let window = try #require(chooser.window)

                #expect(toolbar_pushWindowContext(L, window) == 1)
                #expect(luaL_testudata(L, -1, "hs.chooser") != nil)
                #expect(lua_toAnyObject(L, at: -1) as? HSChooser === chooser)
                lua_pop(L, 1)
            }
        }

        @Test func testToolbarMethodsSmokeThroughLua() {
            let identifier = "typed-userdata-smoke-\(UUID().uuidString)"
            let result = runLua("""
                local toolbar = require("hs.webview.toolbar")
                local id = "\(identifier)"
                local tb = toolbar.new(id)
                local copy = tb:copyToolbar()
                if tb:identifier() ~= id then return "identifier mismatch" end
                if type(tb:isAttached()) ~= "boolean" then return "isAttached type mismatch" end
                if type(tb:visible()) ~= "boolean" then return "visible getter type mismatch" end
                if tostring(copy):match("^hs%.webview%.toolbar:") == nil then return "copy not toolbar userdata" end
                return "ok"
            """)

            #expect(result == "ok")
        }

        private func withBootstrappedLua(
            requiring modules: [String],
            _ body: (UnsafeMutablePointer<lua_State>) throws -> Void
        ) rethrows {
            bootstrapLuaForTesting()
            for module in modules {
                _ = runLua("require('\(module)')")
            }
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }
            try body(L)
        }
    }
}
