import AppKit
import Foundation
import HSDSTCore
import OSAKit
import os.log

final class ProductionAutomation: AutomationProtocol {
    func executeAppleScript(source: String) -> ScriptResult {
        return executeOSA(source: source, language: "AppleScript")
    }

    func executeAppleScriptFile(path: String) -> ScriptResult {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ScriptResult(success: false, output: nil, error: "Cannot read file: \(path)")
        }
        return executeOSA(source: source, language: "AppleScript")
    }

    func executeJavaScriptForAutomation(source: String) -> ScriptResult {
        return executeOSA(source: source, language: "JavaScript")
    }

    func sendAppleEvent(bundleID: String, eventClass: String, eventID: String,
                        parameters: [String: String]) -> ScriptResult {
        // Build an AppleScript "tell" block to target the app
        var script = "tell application id \"\(bundleID)\"\n"
        // Sending raw Apple Events via OSA is complex; delegate to AppleScript
        // For a generic event, we rely on the caller to provide valid AppleScript
        script += "  activate\n"
        script += "end tell"
        return executeOSA(source: script, language: "AppleScript")
    }

    func openURL(_ url: String) -> Bool {
        guard let nsURL = URL(string: url) else { return false }
        return NSWorkspace.shared.open(nsURL)
    }

    func registerURLHandler(scheme: String,
                            callback: @escaping (String, [String: String]) -> Void) -> Bool {
        // URL scheme handling requires NSAppleEventManager integration which is
        // tightly coupled to the app's main event loop and NSApplicationDelegate.
        // TODO: Requires app-level integration to forward kAEGetURL events.
        return false
    }

    func unregisterURLHandler(scheme: String) -> Bool {
        // TODO: Paired with registerURLHandler
        return false
    }

    // MARK: - Private

    private func executeOSA(source: String, language: String) -> ScriptResult {
        guard let lang = OSALanguage(forName: language) else {
            return ScriptResult(success: false, output: nil,
                                error: "Unknown OSA language: \(language)")
        }
        let osa = OSAScript(source: source, language: lang)
        var compileError: NSDictionary?
        osa.compileAndReturnError(&compileError)

        if let compileError = compileError {
            return ScriptResult(success: false, output: nil,
                                error: NSString(format: "%@", compileError) as String)
        }

        var runError: NSDictionary?
        let result = osa.executeAndReturnError(&runError)

        if let result = result {
            return ScriptResult(success: true, output: result.objectValue, error: nil)
        } else {
            let errStr = runError.map { NSString(format: "%@", $0) as String } ?? "Unknown error"
            return ScriptResult(success: false, output: nil, error: errStr)
        }
    }
}
