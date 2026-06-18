import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@Suite("DST WebView", .serialized)
struct DSTWebViewTests {

    // MARK: - SimulatedWebView state machine tests

    @Test func createAndDestroyWebView() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(id == 1)
        #expect(wv.webViews.count == 1)
        #expect(wv.webViews[id]?.frame.width == 800)
        #expect(wv.webViews[id]?.frame.height == 600)

        #expect(wv.destroyWebView(id: id) == true)
        #expect(wv.webViews.count == 0)
    }

    @Test func destroyNonexistentWebViewReturnsFalse() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        #expect(wv.destroyWebView(id: 999) == false)
    }

    @Test func navigateLoadSetsURLAndTitle() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(wv.navigate(webViewID: id, action: .load(url: "https://example.com")) == true)
        #expect(wv.getURL(webViewID: id) == "https://example.com")
        #expect(wv.getTitle(webViewID: id) == "Page at https://example.com")
        #expect(wv.isLoading(webViewID: id) == false)
        #expect(wv.navigationHistory.count == 1)
    }

    @Test func navigateHTMLClearsURL() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(wv.navigate(webViewID: id, action: .loadHTML(html: "<h1>Hello</h1>", baseURL: nil)) == true)
        #expect(wv.getURL(webViewID: id) == nil)
        #expect(wv.getTitle(webViewID: id) == "HTML Content")
    }

    @Test func goBackAndForwardToggleFlags() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))

        // Can't go back initially
        #expect(wv.navigate(webViewID: id, action: .goBack) == false)

        // Load a page, now canGoBack is true
        _ = wv.navigate(webViewID: id, action: .load(url: "https://example.com"))
        #expect(wv.webViews[id]?.canGoBack == true)

        // Go back succeeds
        #expect(wv.navigate(webViewID: id, action: .goBack) == true)
        #expect(wv.webViews[id]?.canGoForward == true)

        // Go forward succeeds
        #expect(wv.navigate(webViewID: id, action: .goForward) == true)
    }

    @Test func navigateNonexistentWebViewReturnsFalse() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        #expect(wv.navigate(webViewID: 999, action: .load(url: "https://example.com")) == false)
    }

    @Test func evaluateJavaScriptTracksScripts() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        let result = wv.evaluateJavaScript(webViewID: id, script: "document.title")
        #expect(result == "")
        #expect(wv.executedScripts.count == 1)
        #expect(wv.executedScripts[0].script == "document.title")
    }

    @Test func evaluateJavaScriptOnNonexistentReturnsNil() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        #expect(wv.evaluateJavaScript(webViewID: 999, script: "1+1") == nil)
    }

    @Test func showAndHideToggleVisibility() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(wv.webViews[id]?.isVisible == false)

        #expect(wv.show(webViewID: id) == true)
        #expect(wv.webViews[id]?.isVisible == true)

        #expect(wv.hide(webViewID: id) == true)
        #expect(wv.webViews[id]?.isVisible == false)
    }

    @Test func setFrameUpdatesFrame() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(wv.setFrame(webViewID: id, frame: (x: 100, y: 200, width: 1024, height: 768)) == true)
        #expect(wv.webViews[id]?.frame.x == 100)
        #expect(wv.webViews[id]?.frame.y == 200)
        #expect(wv.webViews[id]?.frame.width == 1024)
        #expect(wv.webViews[id]?.frame.height == 768)
    }

    @Test func setAlphaUpdatesAlpha() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(wv.webViews[id]?.alpha == 1.0)

        #expect(wv.setAlpha(webViewID: id, alpha: 0.5) == true)
        #expect(wv.webViews[id]?.alpha == 0.5)
    }

    @Test func navigationCallbackFiresOnLoad() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        var callbackEvents: [(String, String)] = []
        #expect(wv.setNavigationCallback(webViewID: id, callback: { event, url in
            callbackEvents.append((event, url))
        }) == true)

        _ = wv.navigate(webViewID: id, action: .load(url: "https://example.com"))
        #expect(callbackEvents.count == 1)
        #expect(callbackEvents[0].0 == "didFinishNavigation")
        #expect(callbackEvents[0].1 == "https://example.com")
    }

    @Test func navigationCallbackFiresOnReloadWithURL() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        _ = wv.navigate(webViewID: id, action: .load(url: "https://example.com"))

        var callbackEvents: [(String, String)] = []
        _ = wv.setNavigationCallback(webViewID: id, callback: { event, url in
            callbackEvents.append((event, url))
        })

        _ = wv.navigate(webViewID: id, action: .reload)
        #expect(callbackEvents.count == 1)
        #expect(callbackEvents[0].0 == "didFinishNavigation")
    }

    @Test func userScriptsCRUD() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))

        #expect(wv.addUserScript(webViewID: id, script: "console.log('hi')", injectionTime: 0, forMainFrameOnly: true) == true)
        #expect(wv.userScripts[id]?.count == 1)
        #expect(wv.userScripts[id]?[0].script == "console.log('hi')")
        #expect(wv.userScripts[id]?[0].injectionTime == 0)
        #expect(wv.userScripts[id]?[0].forMainFrameOnly == true)

        #expect(wv.addUserScript(webViewID: id, script: "alert(1)", injectionTime: 1, forMainFrameOnly: false) == true)
        #expect(wv.userScripts[id]?.count == 2)

        #expect(wv.removeAllUserScripts(webViewID: id) == true)
        #expect(wv.userScripts[id]?.count == 0)
    }

    @Test func clearDataStoreReturnsTrue() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        #expect(wv.clearDataStore(types: ["cookies", "localStorage"]) == true)
        #expect(wv.clearDataStore(types: []) == true)
    }

    @Test func destroyWebViewCleansUpCallbacksAndScripts() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        _ = wv.setNavigationCallback(webViewID: id, callback: { _, _ in })
        _ = wv.addUserScript(webViewID: id, script: "test", injectionTime: 0, forMainFrameOnly: true)

        #expect(wv.navigationCallbacks[id] != nil)
        #expect(wv.userScripts[id]?.isEmpty == false)

        _ = wv.destroyWebView(id: id)
        #expect(wv.navigationCallbacks[id] == nil)
        #expect(wv.userScripts[id] == nil)
    }

    @Test func multipleWebViewsHaveUniqueIDs() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id1 = wv.createWebView(frame: (x: 0, y: 0, width: 100, height: 100))
        let id2 = wv.createWebView(frame: (x: 0, y: 0, width: 200, height: 200))
        let id3 = wv.createWebView(frame: (x: 0, y: 0, width: 300, height: 300))

        #expect(id1 != id2)
        #expect(id2 != id3)
        #expect(id1 != id3)
        #expect(wv.webViews.count == 3)
    }

    // MARK: - Environment wiring tests

    @Test func environmentWebViewIsSimulatedInTestHarness() {
        withLuaState { L in
            let wv = environmentGet(L).webView
            #expect(wv is SimulatedWebView)
        }
    }

    @Test func rectFlipUsesScreenProtocolHeight() {
        withLuaState { L in
            // The SimulatedScreen default primary screen has height 900
            let screen = environmentGet(L).screen as! SimulatedScreen
            let primary = screen.primaryScreen()!
            let expectedHeight = CGFloat(primary.frame.height)

            // wv_RectWithFlippedYCoordinate should use the simulated screen height
            let rect = NSMakeRect(100, 200, 400, 300)
            let flipped = wv_RectWithFlippedYCoordinate(rect)

            // Flipped y = screenHeight - y - height = 900 - 200 - 300 = 400
            #expect(flipped.origin.x == 100)
            #expect(flipped.origin.y == expectedHeight - 200 - 300)
            #expect(flipped.size.width == 400)
            #expect(flipped.size.height == 300)
        }
    }

    @Test func stopNavigationStopsLoading() {
        let harness = SimulatorHarness(seed: 42)
        let env = harness.createEnvironment()
        let wv = env.webView as! SimulatedWebView

        let id = wv.createWebView(frame: (x: 0, y: 0, width: 800, height: 600))
        #expect(wv.navigate(webViewID: id, action: .stop) == true)
        #expect(wv.isLoading(webViewID: id) == false)
    }
}
