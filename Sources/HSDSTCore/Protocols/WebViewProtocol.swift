import Foundation

public struct WebViewHandle: Sendable {
    public var id: UInt64
    public var url: String?
    public var title: String?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var frame: (x: Double, y: Double, width: Double, height: Double)
    public var isVisible: Bool
    public var alpha: Double

    public init(id: UInt64, url: String? = nil, title: String? = nil,
                isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false,
                frame: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 800, 600),
                isVisible: Bool = false, alpha: Double = 1.0) {
        self.id = id
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.frame = frame
        self.isVisible = isVisible
        self.alpha = alpha
    }
}

public enum WebViewNavigationAction: Sendable {
    case load(url: String)
    case loadRequest(URLRequest)
    case loadHTML(html: String, baseURL: String?)
    case goBack
    case goForward
    case reload
    case reloadFromOrigin
    case stop
}

public protocol WebViewProtocol: AnyObject {
    func createWebView(frame: (x: Double, y: Double, width: Double, height: Double)) -> UInt64
    /// Registers an externally created web-view object with the protocol layer.
    func registerWebView(_ view: AnyObject) -> UInt64
    func destroyWebView(id: UInt64) -> Bool
    func navigate(webViewID: UInt64, action: WebViewNavigationAction) -> Bool
    @discardableResult
    func evaluateJavaScript(webViewID: UInt64, script: String,
                            completion: @escaping (Any?, Error?) -> Void) -> Bool
    func getTitle(webViewID: UInt64) -> String?
    func getURL(webViewID: UInt64) -> String?
    func isLoading(webViewID: UInt64) -> Bool
    func setFrame(webViewID: UInt64, frame: (x: Double, y: Double, width: Double, height: Double)) -> Bool
    func show(webViewID: UInt64) -> Bool
    func hide(webViewID: UInt64) -> Bool
    func setAlpha(webViewID: UInt64, alpha: Double) -> Bool
    func getAlpha(webViewID: UInt64) -> Double?
    func isVisible(webViewID: UInt64) -> Bool?
    func setNavigationCallback(webViewID: UInt64, callback: @escaping (String, String) -> Void) -> Bool
    func clearDataStore(types: [String]) -> Bool
    func addUserScript(webViewID: UInt64, script: String, injectionTime: Int, forMainFrameOnly: Bool) -> Bool
    func removeAllUserScripts(webViewID: UInt64) -> Bool
}
