import Foundation
import HSDSTCore

public final class SimulatedWebView: WebViewProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var webViews: [UInt64: WebViewHandle] = [:]
    public var executedScripts: [(webViewID: UInt64, script: String)] = []
    public var navigationHistory: [(webViewID: UInt64, action: WebViewNavigationAction)] = []
    public var userScripts: [UInt64: [(script: String, injectionTime: Int, forMainFrameOnly: Bool)]] = [:]
    public var navigationCallbacks: [UInt64: (String, String) -> Void] = [:]

    private var nextID: UInt64 = 1

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func createWebView(frame: (x: Double, y: Double, width: Double, height: Double)) -> UInt64 {
        let id = nextID
        nextID += 1
        webViews[id] = WebViewHandle(id: id, frame: frame)
        userScripts[id] = []
        return id
    }

    public func destroyWebView(id: UInt64) -> Bool {
        guard webViews.removeValue(forKey: id) != nil else { return false }
        userScripts.removeValue(forKey: id)
        navigationCallbacks.removeValue(forKey: id)
        return true
    }

    public func navigate(webViewID: UInt64, action: WebViewNavigationAction) -> Bool {
        guard var handle = webViews[webViewID] else { return false }

        navigationHistory.append((webViewID: webViewID, action: action))

        switch action {
        case .load(let url):
            handle.url = url
            handle.isLoading = false
            handle.title = "Page at \(url)"
            handle.canGoBack = true
            if let cb = navigationCallbacks[webViewID] {
                cb("didFinishNavigation", url)
            }
        case .loadHTML(let html, _):
            handle.url = nil
            handle.isLoading = false
            handle.title = "HTML Content"
            _ = html
        case .goBack:
            guard handle.canGoBack else { return false }
            handle.canGoForward = true
        case .goForward:
            guard handle.canGoForward else { return false }
        case .reload:
            handle.isLoading = false
            if let url = handle.url, let cb = navigationCallbacks[webViewID] {
                cb("didFinishNavigation", url)
            }
        case .stop:
            handle.isLoading = false
        }

        webViews[webViewID] = handle
        return true
    }

    public func evaluateJavaScript(webViewID: UInt64, script: String) -> String? {
        guard webViews[webViewID] != nil else { return nil }
        executedScripts.append((webViewID: webViewID, script: script))
        return ""
    }

    public func getTitle(webViewID: UInt64) -> String? {
        webViews[webViewID]?.title
    }

    public func getURL(webViewID: UInt64) -> String? {
        webViews[webViewID]?.url
    }

    public func isLoading(webViewID: UInt64) -> Bool {
        webViews[webViewID]?.isLoading ?? false
    }

    public func setFrame(webViewID: UInt64, frame: (x: Double, y: Double, width: Double, height: Double)) -> Bool {
        guard var handle = webViews[webViewID] else { return false }
        handle.frame = frame
        webViews[webViewID] = handle
        return true
    }

    public func show(webViewID: UInt64) -> Bool {
        guard var handle = webViews[webViewID] else { return false }
        handle.isVisible = true
        webViews[webViewID] = handle
        return true
    }

    public func hide(webViewID: UInt64) -> Bool {
        guard var handle = webViews[webViewID] else { return false }
        handle.isVisible = false
        webViews[webViewID] = handle
        return true
    }

    public func setAlpha(webViewID: UInt64, alpha: Double) -> Bool {
        guard var handle = webViews[webViewID] else { return false }
        handle.alpha = alpha
        webViews[webViewID] = handle
        return true
    }

    public func setNavigationCallback(webViewID: UInt64, callback: @escaping (String, String) -> Void) -> Bool {
        guard webViews[webViewID] != nil else { return false }
        navigationCallbacks[webViewID] = callback
        return true
    }

    public func clearDataStore(types: [String]) -> Bool {
        return true
    }

    public func addUserScript(webViewID: UInt64, script: String, injectionTime: Int, forMainFrameOnly: Bool) -> Bool {
        guard webViews[webViewID] != nil else { return false }
        userScripts[webViewID, default: []].append((script: script, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly))
        return true
    }

    public func removeAllUserScripts(webViewID: UInt64) -> Bool {
        guard webViews[webViewID] != nil else { return false }
        userScripts[webViewID] = []
        return true
    }
}
