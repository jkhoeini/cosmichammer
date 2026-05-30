import Cocoa
import CLua
import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class TypedUserdataConversion {
        @Test func testWebviewAlertExtractsTypedWebviewUserdata() {
            bootstrapLuaForTesting()
            _ = runLua("require('hs.webview')")
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            let window = HSWebViewWindow(
                contentRect: NSRect(x: 10, y: 10, width: 100, height: 100),
                styleMask: .borderless,
                backing: .buffered,
                defer: true
            )

            _ = wv_HSWebViewWindow_toLua(L, window)
            #expect(dialog_webviewWindowFromLua(L, at: -1) === window)
            _ = wv_userdata_gc(L)
        }

        @Test func testGenericPushPreservesCanvasViewUserdata() {
            bootstrapLuaForTesting()
            _ = runLua("require('hs.canvas')")
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            let view = HSCanvasView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            lua_pushany(L, view)

            #expect(luaL_testudata(L, -1, canvas_USERDATA_TAG) != nil)
            #expect((canvas_toHSCanvasViewFromLua(L, idx: -1) as? HSCanvasView) === view)
            _ = canvas_userdata_gc(L)
        }

        @Test func testToolbarAndWebviewContextPushTypedUserdata() throws {
            bootstrapLuaForTesting()
            _ = runLua("require('hs.webview')")
            _ = runLua("require('hs.webview.toolbar')")
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            let toolbar = try #require(HSToolbar(
                identifier: "typed-userdata-\(UUID().uuidString)",
                itemTableIndex: LUA_NOREF,
                state: L
            ))

            lua_pushany(L, toolbar)
            #expect(luaL_testudata(L, -1, "hs.webview.toolbar") != nil)
            #expect((lua_toAnyObject(L, at: -1) as? HSToolbar) === toolbar)
            lua_pop(L, 1)

            let window = HSWebViewWindow(
                contentRect: NSRect(x: 20, y: 20, width: 100, height: 100),
                styleMask: .borderless,
                backing: .buffered,
                defer: true
            )
            toolbar_pushWindowContext(L, window: window)

            #expect(luaL_testudata(L, -1, wv_USERDATA_TAG) != nil)
            #expect(wv_getWindowFromUD(L, -1) === window)
            _ = wv_userdata_gc(L)
        }
    }
}
