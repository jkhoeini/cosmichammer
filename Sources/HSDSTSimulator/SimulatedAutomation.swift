import Foundation
import HSDSTCore

public final class SimulatedAutomation: AutomationProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var executedScripts: [(source: String, type: String)] = []
    public var scriptResults: [String: ScriptResult] = [:]
    public var defaultResult: ScriptResult = ScriptResult(success: true, output: nil, error: nil)
    public var openedURLs: [String] = []
    public var registeredSchemes: [String: (String, [String: String]) -> Void] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Result lookup

    private func result(for source: String) -> ScriptResult {
        for (key, value) in scriptResults where source.contains(key) {
            return value
        }
        return defaultResult
    }

    // MARK: - AutomationProtocol

    public func executeAppleScript(source: String) -> ScriptResult {
        executedScripts.append((source: source, type: "applescript"))
        return result(for: source)
    }

    public func executeAppleScriptFile(path: String) -> ScriptResult {
        executedScripts.append((source: path, type: "file"))
        return result(for: path)
    }

    public func executeJavaScriptForAutomation(source: String) -> ScriptResult {
        executedScripts.append((source: source, type: "jxa"))
        return result(for: source)
    }

    public func sendAppleEvent(bundleID: String, eventClass: String, eventID: String, parameters: [String: String]) -> ScriptResult {
        let description = "\(bundleID):\(eventClass)/\(eventID)"
        executedScripts.append((source: description, type: "appleevent"))
        return result(for: description)
    }

    public func openURL(_ url: String) -> Bool {
        openedURLs.append(url)
        return true
    }

    public func registerURLHandler(scheme: String, callback: @escaping (String, [String: String]) -> Void) -> Bool {
        registeredSchemes[scheme] = callback
        return true
    }

    public func unregisterURLHandler(scheme: String) -> Bool {
        return registeredSchemes.removeValue(forKey: scheme) != nil
    }
}
