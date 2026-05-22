import Testing
import Foundation

let isHeadless: Bool = ProcessInfo.processInfo.environment["HEADLESS"] != nil

@MainActor
func runLua(_ code: String) -> String? {
    MJLuaRunString(code)
}

@MainActor
func loadLuaModule(_ name: String) throws {
    let result = runLua("require('\(name)')")
    try #require(result == "true", "Unable to load \(name).lua")
}

@MainActor
func runLuaTest(function: String = #function) {
    let funcName = function.replacingOccurrences(of: "()", with: "")
    let result = runLua("\(funcName)()")
    #expect(result == "Success", "Lua test \(funcName) failed: \(result ?? "nil")")
}

@MainActor
func luaTestWithCheckAndTimeout(
    _ timeout: TimeInterval, setup: String, check: String
) {
    let setupResult = runLua(setup)
    guard setupResult == "Success" else {
        Issue.record("Setup failed: \(setup) returned \(setupResult ?? "nil")")
        return
    }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        if runLua(check) == "Success" { return }
    }
    Issue.record("Timed out after \(timeout)s: \(check)")
}

@MainActor
func runTwoPartLuaTest(timeout: TimeInterval, function: String = #function) {
    let funcName = function.replacingOccurrences(of: "()", with: "")
    luaTestWithCheckAndTimeout(timeout, setup: "\(funcName)()", check: "\(funcName)Values()")
}

extension Trait where Self == Testing.ConditionTrait {
    static var skipInHeadless: Self {
        .enabled(if: !isHeadless, "Test requires hardware (display, audio, etc.)")
    }
}
