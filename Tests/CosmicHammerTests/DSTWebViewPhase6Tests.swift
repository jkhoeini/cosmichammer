import Testing
import Foundation
import CLua
import AppKit
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

/// Phase 6: core webview view operations route through WebViewProtocol so DST tests
/// can simulate them. Uses the SimulatedWebView via the bootstrapped Lua state; the
/// real WebKit is never touched.
@Suite("DST WebView Phase6", .serialized)
struct DSTWebViewPhase6Tests {

    // MARK: - SimulatedWebView.registerWebView

    @Test @MainActor func registerWebViewReturnsFreshIDAndStoresOpaqueToken() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let id = wv.registerWebView(view)

        #expect(wv.webViews[id] != nil)
        #expect(wv.registeredViews[id] != nil)
        #expect(wv.registeredViews[id] === view)
        // Registered handles start with the default handle state, not a created frame.
        if let handle = wv.webViews[id] {
            #expect(handle.frame == (0, 0, 800, 600))
        }
    }

    @Test @MainActor func registeredViewSupportsCoreOpsEndToEnd() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let id = wv.registerWebView(view)

        // Navigate load
        #expect(wv.navigate(webViewID: id, action: .load(url: "https://example.com")) == true)
        #expect(wv.getURL(webViewID: id) == "https://example.com")
        #expect(wv.getTitle(webViewID: id) == "Page at https://example.com")
        #expect(wv.isLoading(webViewID: id) == false)

        // Go back / forward state machine
        #expect(wv.navigate(webViewID: id, action: .goBack) == true)
        #expect(wv.webViews[id]?.canGoForward == true)
        #expect(wv.navigate(webViewID: id, action: .goForward) == true)

        // Reload and stop
        #expect(wv.navigate(webViewID: id, action: .reload) == true)
        #expect(wv.navigate(webViewID: id, action: .stop) == true)
        #expect(wv.isLoading(webViewID: id) == false)

        // evaluateJavaScript records through the protocol and completes with its result.
        var scriptResult: Any?
        var scriptError: Error?
        let started = wv.evaluateJavaScript(webViewID: id, script: "1+1") { result, error in
            scriptResult = result
            scriptError = error
        }
        #expect(started)
        #expect(scriptError == nil)
        #expect(scriptResult as? String == "")
        #expect(wv.executedScripts.count == 1)
        #expect(wv.executedScripts[0].webViewID == id)
        #expect(wv.executedScripts[0].script == "1+1")

        // Show / hide
        #expect(wv.show(webViewID: id) == true)
        #expect(wv.webViews[id]?.isVisible == true)
        #expect(wv.hide(webViewID: id) == true)
        #expect(wv.webViews[id]?.isVisible == false)

        // Alpha
        #expect(wv.setAlpha(webViewID: id, alpha: 0.25) == true)
        #expect(wv.webViews[id]?.alpha == 0.25)
    }

    @Test @MainActor func registeredViewHistoryRecordsAllNavigationActions() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let id = wv.registerWebView(view)

        _ = wv.navigate(webViewID: id, action: .load(url: "https://example.com"))
        _ = wv.navigate(webViewID: id, action: .goBack)
        _ = wv.navigate(webViewID: id, action: .goForward)
        _ = wv.navigate(webViewID: id, action: .reload)
        _ = wv.navigate(webViewID: id, action: .stop)

        let actions = wv.navigationHistory.filter { $0.webViewID == id }.map { $0.action }
        #expect(actions.count == 5)
        if actions.count == 5 {
            if case .load(let url) = actions[0] {
                #expect(url == "https://example.com")
            } else {
                Issue.record("expected load action, got \(actions[0])")
            }
            if case .goBack = actions[1] {} else { Issue.record("expected goBack, got \(actions[1])") }
            if case .goForward = actions[2] {} else { Issue.record("expected goForward, got \(actions[2])") }
            if case .reload = actions[3] {} else { Issue.record("expected reload, got \(actions[3])") }
            if case .stop = actions[4] {} else { Issue.record("expected stop, got \(actions[4])") }
        }
    }

    @Test @MainActor func destroyWebViewCleansUpRegisteredView() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let id = wv.registerWebView(view)
        _ = wv.navigate(webViewID: id, action: .load(url: "https://example.com"))

        #expect(wv.destroyWebView(id: id) == true)
        #expect(wv.webViews[id] == nil)
        #expect(wv.registeredViews[id] == nil)
        #expect(wv.navigate(webViewID: id, action: .load(url: "https://example.com")) == false)
    }

    @Test @MainActor func registerWebViewIDsDoNotCollideWithCreateWebView() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let created = wv.createWebView(frame: (x: 0, y: 0, width: 400, height: 300))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let registered = wv.registerWebView(view)
        let created2 = wv.createWebView(frame: (x: 0, y: 0, width: 400, height: 300))

        #expect(created != registered)
        #expect(registered != created2)
        #expect(created != created2)
        #expect(wv.webViews.count == 3)
    }

    // MARK: - webview_new registers the view; Lua ops route through the simulator

    @Test @MainActor func webviewNewRegistersProtocolID() {
        bootstrapLuaForTesting()
        let L = lua_getCurrentState()!
        let wv = environmentGet(L).webView as! SimulatedWebView
        let before = wv.webViews.count

        let result = runLua("""
            local webview = require("hs.webview")
            local view = webview.new({ x = 0, y = 0, w = 400, h = 300 })
            if type(view) ~= "userdata" then return "bad type: " .. type(view) end
            view:delete()
            return "ok"
        """)
        #expect(result == "ok")
        #expect(wv.webViews.count == before)
    }

    @Test @MainActor func webviewUrlRoundTripRoutesThroughSimulator() {
        bootstrapLuaForTesting()
        let L = lua_getCurrentState()!
        let wv = environmentGet(L).webView as! SimulatedWebView
        let before = wv.webViews.keys.max() ?? 0

        let result = runLua("""
            local webview = require("hs.webview")
            __wv6 = webview.new({ x = 0, y = 0, w = 400, h = 300 })
            __wv6:url("https://example.com")
            return "ok"
        """)
        #expect(result == "ok")

        let id = wv.webViews.keys.max() ?? 0
        #expect(id > before)

        // The setter routed through navigate(load:) on the registered handle.
        #expect(wv.getURL(webViewID: id) == "https://example.com")
        #expect(wv.getTitle(webViewID: id) == "Page at https://example.com")

        // The getters read through getURL/getTitle on the registered handle.
        #expect(runLua("return __wv6:url()") == "https://example.com")
        #expect(runLua("return __wv6:title()") == "Page at https://example.com")
    }

    @Test @MainActor func webviewLoadingAndStopRouteThroughSimulator() {
        bootstrapLuaForTesting()
        let L = lua_getCurrentState()!
        let wv = environmentGet(L).webView as! SimulatedWebView

        let result = runLua("""
            local webview = require("hs.webview")
            __wv6 = webview.new({ x = 0, y = 0, w = 400, h = 300 })
            __wv6:url("https://example.com")
            return "ok"
        """)
        #expect(result == "ok")
        let id = wv.webViews.keys.max() ?? 0

        #expect(runLua("return __wv6:loading()") == "false")

        let historyCount = wv.navigationHistory.count
        runLua("__wv6:stopLoading()")
        #expect(wv.navigationHistory.count == historyCount)
    }

    @Test @MainActor func webviewGoBackGoForwardReloadRouteThroughSimulator() {
        bootstrapLuaForTesting()
        let L = lua_getCurrentState()!
        let wv = environmentGet(L).webView as! SimulatedWebView

        let result = runLua("""
            local webview = require("hs.webview")
            __wv6 = webview.new({ x = 0, y = 0, w = 400, h = 300 })
            __wv6:url("https://example.com")
            return "ok"
        """)
        #expect(result == "ok")
        let id = wv.webViews.keys.max() ?? 0

        runLua("__wv6:goBack()")
        runLua("__wv6:goForward()")
        runLua("__wv6:reload()")

        let actions = wv.navigationHistory.filter { $0.webViewID == id }.suffix(3).map { $0.action }
        #expect(actions.count == 3)
        if actions.count == 3 {
            if case .goBack = actions[0] {} else { Issue.record("expected goBack, got \(actions[0])") }
            if case .goForward = actions[1] {} else { Issue.record("expected goForward, got \(actions[1])") }
            if case .reload = actions[2] {} else { Issue.record("expected reload, got \(actions[2])") }
        }
    }

    @Test @MainActor func webviewEvaluateJavaScriptRoutesThroughSimulator() {
        bootstrapLuaForTesting()
        let L = lua_getCurrentState()!
        let wv = environmentGet(L).webView as! SimulatedWebView
        let before = wv.executedScripts.count

        let result = runLua("""
            local webview = require("hs.webview")
            __wv6 = webview.new({ x = 0, y = 0, w = 400, h = 300 })
            return "ok"
        """)
        #expect(result == "ok")
        let id = wv.webViews.keys.max() ?? 0

        runLua("__wv6:evaluateJavaScript('window.__phase6 = 1')")
        #expect(wv.executedScripts.count == before + 1)
        #expect(wv.executedScripts.last?.script == "window.__phase6 = 1")
        #expect(wv.executedScripts.last?.webViewID == id)
    }

    @Test @MainActor func webviewShowHideAlphaRouteThroughSimulator() {
        bootstrapLuaForTesting()
        let L = lua_getCurrentState()!
        let wv = environmentGet(L).webView as! SimulatedWebView

        let result = runLua("""
            local webview = require("hs.webview")
            __wv6 = webview.new({ x = 0, y = 0, w = 400, h = 300 })
            return "ok"
        """)
        #expect(result == "ok")
        let id = wv.webViews.keys.max() ?? 0

        runLua("__wv6:show()")
        #expect(wv.webViews[id]?.isVisible == true)
        #expect(runLua("return __wv6:isVisible()") == "true")

        runLua("__wv6:hide()")
        #expect(wv.webViews[id]?.isVisible == false)
        #expect(runLua("return __wv6:isVisible()") == "false")

        runLua("__wv6:alpha(0.5)")
        #expect(wv.webViews[id]?.alpha == 0.5)
        #expect(runLua("return __wv6:alpha()") == "0.5")
    }
}
