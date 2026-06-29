import Foundation
import CLua
import HSDSTCore

private let defaultCallbackSampleRates: [String: Double] = [
    "hs.eventtap": 0,
    "hs.sqlite3.busyHandler": 0,
    "hs.sqlite3.commitHook": 0,
    "hs.sqlite3.collation": 0,
    "hs.sqlite3.exec": 0,
    "hs.sqlite3.finalizeFunction": 0,
    "hs.sqlite3.progressHandler": 0,
    "hs.sqlite3.sqlFunction": 0,
]

private var callbackSampleCounters: [String: UInt64] = [:]
private let callbackSampleCountersLock = NSLock()

func resetLuaCallbackTelemetrySamplingCounters() {
    callbackSampleCountersLock.lock()
    defer { callbackSampleCountersLock.unlock() }
    callbackSampleCounters.removeAll()
}

private func shouldSampleCallback(_ telemetry: any TelemetryProtocol, callbackName: String) -> Bool {
    guard telemetry.isEnabled else { return false }
    let configuredRates = telemetry.configuration.callbackSampleRates
    let rate = configuredRates[callbackName] ?? configuredRates["*"] ?? defaultCallbackSampleRates[callbackName] ?? 1
    if rate <= 0 { return false }
    if rate >= 1 { return true }

    let interval = max(UInt64((1 / rate).rounded()), 1)
    callbackSampleCountersLock.lock()
    defer { callbackSampleCountersLock.unlock() }
    let nextCount = (callbackSampleCounters[callbackName] ?? 0) + 1
    callbackSampleCounters[callbackName] = nextCount
    return nextCount % interval == 0
}

func luaTelemetryPCall(
    _ L: UnsafeMutablePointer<lua_State>!,
    nargs: Int32,
    nresults: Int32,
    callbackName: String,
    attributes: [String: Any] = [:],
    parentContext: [String: String]? = nil
) -> Int32 {
    let telemetry = environmentGet(L).telemetry
    guard shouldSampleCallback(telemetry, callbackName: callbackName) else {
        return lua_pcall(L, nargs, nresults, 0)
    }

    var spanAttributes = attributes
    spanAttributes[TelemetrySemanticConventions.Attribute.Lua.callbackName] = callbackName
    let start = Date()
    if let parentContext, !parentContext.isEmpty {
        telemetry.extract(from: parentContext)
    }
    let spanID = telemetry.startSpan(
        name: "lua.callback",
        kind: .internalSpan,
        attributes: spanAttributes,
        startTime: start.timeIntervalSince1970
    )

    let status = lua_pcall(L, nargs, nresults, 0)
    let duration = Date().timeIntervalSince(start)
    telemetry.recordMetric(
        name: "cosmichammer.lua.callback.duration",
        kind: .histogram,
        value: duration,
        attributes: [TelemetrySemanticConventions.Attribute.Lua.callbackName: callbackName],
        unit: "s"
    )

    if status == LUA_OK {
        if let spanID {
            telemetry.endSpan(id: spanID, status: .ok, attributes: [:], endTime: nil)
        }
    } else {
        let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "(non-string error)"
        telemetry.recordException(
            spanID: spanID,
            message: errorMsg,
            stack: nil,
            attributes: [TelemetrySemanticConventions.Attribute.Lua.callbackName: callbackName]
        )
        if let spanID {
            telemetry.endSpan(id: spanID, status: .error(errorMsg), attributes: [:], endTime: nil)
        }
    }

    return status
}
