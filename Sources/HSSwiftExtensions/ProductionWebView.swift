import Foundation
import HSDSTCore
import WebKit

final class ProductionWebView: WebViewProtocol {
    private var nextID: UInt64 = 1
    private var webViews: [UInt64: WebViewState] = [:]

    private class WebViewState: NSObject, WKNavigationDelegate {
        let window: NSWindow
        let webView: WKWebView
        var navigationCallback: ((String, String) -> Void)?

        init(frame: NSRect) {
            let config = WKWebViewConfiguration()
            config.preferences.isElementFullscreenEnabled = true
            webView = WKWebView(frame: NSRect(x: 0, y: 0,
                                               width: frame.width,
                                               height: frame.height),
                                configuration: config)
            window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.contentView = webView
            super.init()
            webView.navigationDelegate = self
        }

        // WKNavigationDelegate
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigationCallback?("didFinish", webView.url?.absoluteString ?? "")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                      withError error: Error) {
            navigationCallback?("didFail", error.localizedDescription)
        }

        func webView(_ webView: WKWebView,
                      didStartProvisionalNavigation navigation: WKNavigation!) {
            navigationCallback?("didStart", webView.url?.absoluteString ?? "")
        }
    }

    func createWebView(frame: (x: Double, y: Double, width: Double, height: Double)) -> UInt64 {
        let id = nextID
        nextID += 1
        let nsFrame = NSRect(x: frame.x, y: frame.y,
                              width: frame.width, height: frame.height)
        let state = WebViewState(frame: nsFrame)
        webViews[id] = state
        return id
    }

    func destroyWebView(id: UInt64) -> Bool {
        guard let state = webViews.removeValue(forKey: id) else { return false }
        state.webView.stopLoading()
        state.window.close()
        return true
    }

    func navigate(webViewID: UInt64, action: WebViewNavigationAction) -> Bool {
        guard let state = webViews[webViewID] else { return false }
        switch action {
        case .load(let url):
            guard let nsURL = URL(string: url) else { return false }
            state.webView.load(URLRequest(url: nsURL))
        case .loadHTML(let html, let baseURL):
            let base = baseURL.flatMap { URL(string: $0) }
            state.webView.loadHTMLString(html, baseURL: base)
        case .goBack:
            state.webView.goBack()
        case .goForward:
            state.webView.goForward()
        case .reload:
            state.webView.reload()
        case .stop:
            state.webView.stopLoading()
        }
        return true
    }

    func evaluateJavaScript(webViewID: UInt64, script: String) -> String? {
        guard let state = webViews[webViewID] else { return nil }
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        state.webView.evaluateJavaScript(script) { value, _ in
            if let value = value {
                result = "\(value)"
            }
            semaphore.signal()
        }

        // Wait briefly for result (non-blocking on main thread is complex)
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    func getTitle(webViewID: UInt64) -> String? {
        webViews[webViewID]?.webView.title
    }

    func getURL(webViewID: UInt64) -> String? {
        webViews[webViewID]?.webView.url?.absoluteString
    }

    func isLoading(webViewID: UInt64) -> Bool {
        webViews[webViewID]?.webView.isLoading ?? false
    }

    func setFrame(webViewID: UInt64,
                  frame: (x: Double, y: Double, width: Double, height: Double)) -> Bool
    {
        guard let state = webViews[webViewID] else { return false }
        state.window.setFrame(
            NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            display: true)
        return true
    }

    func show(webViewID: UInt64) -> Bool {
        guard let state = webViews[webViewID] else { return false }
        state.window.orderFront(nil)
        return true
    }

    func hide(webViewID: UInt64) -> Bool {
        guard let state = webViews[webViewID] else { return false }
        state.window.orderOut(nil)
        return true
    }

    func setAlpha(webViewID: UInt64, alpha: Double) -> Bool {
        guard let state = webViews[webViewID] else { return false }
        state.window.alphaValue = CGFloat(alpha)
        return true
    }

    func setNavigationCallback(webViewID: UInt64,
                                callback: @escaping (String, String) -> Void) -> Bool
    {
        guard let state = webViews[webViewID] else { return false }
        state.navigationCallback = callback
        return true
    }

    func clearDataStore(types: [String]) -> Bool {
        let dataTypes: Set<String> = Set(types.isEmpty
            ? [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
               WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage]
            : types)

        let store = WKWebsiteDataStore.default()
        let semaphore = DispatchSemaphore(value: 0)
        store.removeData(ofTypes: dataTypes,
                         modifiedSince: Date.distantPast) {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return true
    }

    func addUserScript(webViewID: UInt64, script: String,
                       injectionTime: Int, forMainFrameOnly: Bool) -> Bool
    {
        guard let state = webViews[webViewID] else { return false }
        let time: WKUserScriptInjectionTime = injectionTime == 0
            ? .atDocumentStart : .atDocumentEnd
        let userScript = WKUserScript(
            source: script,
            injectionTime: time,
            forMainFrameOnly: forMainFrameOnly)
        state.webView.configuration.userContentController.addUserScript(userScript)
        return true
    }

    func removeAllUserScripts(webViewID: UInt64) -> Bool {
        guard let state = webViews[webViewID] else { return false }
        state.webView.configuration.userContentController.removeAllUserScripts()
        return true
    }
}
