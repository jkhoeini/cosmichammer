import Foundation

public struct ScriptResult: @unchecked Sendable {
    public var success: Bool
    public var output: Any?
    public var error: String?

    public init(success: Bool, output: Any? = nil, error: String? = nil) {
        self.success = success
        self.output = output
        self.error = error
    }
}

public protocol AutomationProtocol: AnyObject {
    func executeAppleScript(source: String) -> ScriptResult
    func executeAppleScriptFile(path: String) -> ScriptResult
    func executeJavaScriptForAutomation(source: String) -> ScriptResult
    func sendAppleEvent(bundleID: String, eventClass: String, eventID: String, parameters: [String: String]) -> ScriptResult
    func openURL(_ url: String) -> Bool
    func registerURLHandler(scheme: String, callback: @escaping (String, [String: String]) -> Void) -> Bool
    func unregisterURLHandler(scheme: String) -> Bool
}
