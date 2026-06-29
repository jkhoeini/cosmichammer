import Foundation
import CLua
import Lua
import HSDSTCore
import OSAKit

private var activeOsascriptExecutionCount = 0

private func recordActiveOsascriptExecutionGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.osascript.execution.active",
        kind: .gauge,
        value: Double(activeOsascriptExecutionCount),
        attributes: [:],
        unit: "1"
    )
}

func adjustOsascriptExecutionCount(_ delta: Int, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    activeOsascriptExecutionCount = max(0, activeOsascriptExecutionCount + delta)
    recordActiveOsascriptExecutionGauge(L)
}

/// hs.osascript._osascript(source, language) -> bool, object, descriptor
/// Function
/// Runs osascript code
///
/// Parameters:
///  * source - Some osascript code to execute
///  * language - A string containing the OSA language, either 'AppleScript' or 'JavaScript'. Defaults to AppleScript if invalid language
///
/// Returns:
///  * A boolean value indicating whether the code succeeded or not
///  * An object containing the parsed output that can be any type, or nil if unsuccessful
///  * A string containing the raw output of the code and/or its errors
private func runosascript(_ L: LuaState) throws -> CInt {
    let source: String = try L.checkArgument(1)
    let language: String = try L.checkArgument(2)
    let telemetry = environmentGet(L).telemetry
    let spanID = telemetry.startSpan(
        name: "hs.osascript.execute",
        kind: .internalSpan,
        attributes: [
            "osa.language": language,
            "osa.source.length": source.count,
        ],
        startTime: nil
    )
    adjustOsascriptExecutionCount(1, L: L)
    defer { adjustOsascriptExecutionCount(-1, L: L) }

    let osa = OSAScript(source: source, language: OSALanguage(forName: language))
    var compileError: NSDictionary?
    osa.compileAndReturnError(&compileError)

    if let compileError = compileError {
        let message = NSString(format: "%@", compileError) as String
        telemetry.recordException(
            spanID: spanID,
            message: message,
            stack: nil,
            attributes: ["osa.error.phase": "compile", "osa.language": language]
        )
        if let spanID {
            telemetry.endSpan(
                id: spanID,
                status: .error(message),
                attributes: ["osa.error.phase": "compile"],
                endTime: nil
            )
        }
        L.push(false)
        lua_pushnil(L)
        L.push(message)
        return 3
    }

    var error: NSDictionary?
    let result = osa.executeAndReturnError(&error)
    let didSucceed = (result != nil)
    if didSucceed {
        if let spanID {
            telemetry.endSpan(id: spanID, status: .ok, attributes: [:], endTime: nil)
        }
    } else {
        let message = NSString(format: "%@", error ?? [:]) as String
        telemetry.recordException(
            spanID: spanID,
            message: message,
            stack: nil,
            attributes: ["osa.error.phase": "execute", "osa.language": language]
        )
        if let spanID {
            telemetry.endSpan(
                id: spanID,
                status: .error(message),
                attributes: ["osa.error.phase": "execute"],
                endTime: nil
            )
        }
    }

    L.push(didSucceed)
    if didSucceed {
        lua_pushany(L, result!.objectValue)
    } else {
        lua_pushnil(L)
    }
    L.push(NSString(format: "%@", didSucceed ? result! : error!) as String)
    return 3
}

@_cdecl("luaopen_hs_libosascript")
public func luaopen_hs_libosascript(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 1)
        L.push(runosascript)
        lua_setfield(L, -2, "_osascript")
    }
}
