import Foundation
import CLua
import Lua
import HSDSTCore

private func telemetry(_ L: UnsafeMutablePointer<lua_State>!) -> any TelemetryProtocol {
    environmentGet(L).telemetry
}

private func tableAt(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> [String: Any] {
    (lua_tovalue(L, at: index) as? [String: Any]) ?? [:]
}

private func stringDictionary(_ value: Any?) -> [String: String] {
    guard let dict = value as? [String: Any] else { return [:] }
    var result: [String: String] = [:]
    for (key, value) in dict {
        result[key] = String(describing: value)
    }
    return result
}

private func intDictionary(_ value: Any?) -> [String: Int] {
    guard let dict = value as? [String: Any] else { return [:] }
    var result: [String: Int] = [:]
    for (key, value) in dict {
        if let number = value as? NSNumber {
            result[key] = number.intValue
        } else if let intValue = value as? Int {
            result[key] = intValue
        }
    }
    return result
}

private func mergedIntDictionary(_ value: Any?, defaults: [String: Int]) -> [String: Int] {
    defaults.merging(intDictionary(value)) { _, new in new }
}

private func doubleDictionary(_ value: Any?) -> [String: Double] {
    guard let dict = value as? [String: Any] else { return [:] }
    var result: [String: Double] = [:]
    for (key, value) in dict {
        if let number = value as? NSNumber {
            result[key] = number.doubleValue
        } else if let doubleValue = value as? Double {
            result[key] = doubleValue
        }
    }
    return result
}

private func stringArray(_ value: Any?) -> [String] {
    guard let value else { return ["tracecontext", "baggage"] }
    if let values = value as? [Any] {
        return values.map { String(describing: $0) }
    }
    if let values = value as? [String: Any] {
        return values.keys.sorted().compactMap { key in
            if let enabled = values[key] as? Bool {
                return enabled ? key : nil
            }
            if let enabled = values[key] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() {
                return enabled.boolValue ? key : nil
            }
            return String(describing: values[key]!)
        }
    }
    return ["tracecontext", "baggage"]
}

private func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
    guard let value else { return defaultValue }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    return defaultValue
}

private func doubleValue(_ value: Any?, default defaultValue: Double) -> Double {
    guard let value else { return defaultValue }
    if let number = value as? NSNumber { return number.doubleValue }
    if let double = value as? Double { return double }
    return defaultValue
}

private func stringValue(_ value: Any?, default defaultValue: String) -> String {
    guard let value else { return defaultValue }
    return String(describing: value)
}

private func optionalString(_ value: Any?) -> String? {
    guard let value else { return nil }
    return String(describing: value)
}

private func spanKind(_ value: Any?) -> TelemetrySpanKind {
    switch optionalString(value) {
    case "client": return .client
    case "server": return .server
    case "producer": return .producer
    case "consumer": return .consumer
    default: return .internalSpan
    }
}

private func metricKind(_ value: Any?) -> TelemetryMetricKind {
    switch optionalString(value) {
    case "upDownCounter": return .upDownCounter
    case "gauge": return .gauge
    case "histogram": return .histogram
    default: return .counter
    }
}

private func statusFromTable(_ table: [String: Any]) -> TelemetrySpanStatus {
    let code = stringValue(table["code"], default: "unset")
    if code == "ok" {
        return .ok
    }
    if code == "error" {
        return .error(stringValue(table["message"], default: ""))
    }
    return .unset
}

private func telemetry_configure(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TTABLE)
    let input = tableAt(L, 1)
    let defaults = telemetry(L).configuration
    let config = TelemetryConfiguration(
        enabled: boolValue(input["enabled"], default: defaults.enabled),
        serviceName: stringValue(input["serviceName"], default: defaults.serviceName),
        exporter: stringValue(input["exporter"], default: defaults.exporter),
        protocolName: stringValue(input["protocol"], default: defaults.protocolName),
        endpoint: optionalString(input["endpoint"]),
        tracesEndpoint: optionalString(input["tracesEndpoint"]),
        logsEndpoint: optionalString(input["logsEndpoint"]),
        metricsEndpoint: optionalString(input["metricsEndpoint"]),
        headers: stringDictionary(input["headers"]),
        compression: stringValue(input["compression"], default: defaults.compression),
        timeoutSeconds: doubleValue(input["timeout"], default: defaults.timeoutSeconds),
        batch: intDictionary(input["batch"]),
        capturePrint: stringValue(input["capturePrint"], default: defaults.capturePrint),
        captureLogger: boolValue(input["captureLogger"], default: defaults.captureLogger),
        traces: boolValue(input["traces"], default: defaults.traces),
        logs: boolValue(input["logs"], default: defaults.logs),
        metrics: boolValue(input["metrics"], default: defaults.metrics),
        callbackSampleRates: doubleDictionary(input["callbackSampleRates"]),
        attributeLimits: mergedIntDictionary(input["attributeLimits"], defaults: defaults.attributeLimits),
        resourceAttributes: stringDictionary(input["resourceAttributes"]),
        propagators: stringArray(input["propagators"])
    )
    telemetry(L).configure(config)
    L.push(true)
    return 1
}

private func telemetry_status(_ L: LuaState) throws -> CInt {
    let status = telemetry(L).status()
    lua_pushany(L, [
        "enabled": status.enabled,
        "serviceName": status.serviceName,
        "exporter": status.exporter,
        "protocol": status.protocolName,
        "compression": status.compression,
        "capturePrint": status.capturePrint,
        "captureLogger": status.captureLogger,
        "activeSpanID": status.activeSpanID as Any,
        "startedSpans": status.startedSpans,
        "endedSpans": status.endedSpans,
        "logRecords": status.logRecords,
        "metricRecords": status.metricRecords,
        "droppedRecords": status.droppedRecords,
        "droppedAttributes": status.droppedAttributes,
        "flushCount": status.flushCount,
        "lastFlushDuration": status.lastFlushDuration as Any,
        "lastFlushResult": status.lastFlushResult as Any,
        "shutdownCount": status.shutdownCount,
        "lastShutdownDuration": status.lastShutdownDuration as Any,
        "lastShutdownResult": status.lastShutdownResult as Any,
        "lastExportError": status.lastExportError as Any,
        "lastExporterFailureKind": status.lastExporterFailureKind as Any,
        "exporterFailureCount": status.exporterFailureCount,
        "flushFailureCount": status.flushFailureCount,
        "shutdownFailureCount": status.shutdownFailureCount,
        "backpressureDroppedRecords": status.backpressureDroppedRecords,
        "exporterQueueDepth": status.exporterQueueDepth as Any,
        "exporterQueueCapacity": status.exporterQueueCapacity as Any,
        "exporterMaxExportBatchSize": status.exporterMaxExportBatchSize as Any,
        "exporterScheduleDelay": status.exporterScheduleDelay as Any,
        "exporterTimeout": status.exporterTimeout as Any,
        "lastExportDuration": status.lastExportDuration as Any,
    ])
    return 1
}

private func telemetry_startSpan(_ L: LuaState) throws -> CInt {
    let name: String = try L.checkArgument(1)
    let options = lua_type(L, 2) == LUA_TTABLE ? tableAt(L, 2) : [:]
    let attributes = (options["attributes"] as? [String: Any]) ?? [:]
    let id = telemetry(L).startSpan(
        name: name,
        kind: spanKind(options["kind"]),
        attributes: attributes,
        startTime: nil
    )
    if let id {
        lua_pushinteger(L, lua_Integer(id))
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func telemetry_endSpan(_ L: LuaState) throws -> CInt {
    let id = UInt64(luaL_checkinteger(L, 1))
    let status = lua_type(L, 2) == LUA_TTABLE ? statusFromTable(tableAt(L, 2)) : nil
    let attributes = lua_type(L, 3) == LUA_TTABLE ? tableAt(L, 3) : [:]
    telemetry(L).endSpan(id: id, status: status, attributes: attributes, endTime: nil)
    return 0
}

private func telemetry_setAttributes(_ L: LuaState) throws -> CInt {
    let attributes = lua_type(L, 1) == LUA_TTABLE ? tableAt(L, 1) : [:]
    let spanID = lua_isinteger(L, 2) != 0 ? UInt64(lua_tointeger(L, 2)) : nil
    telemetry(L).setSpanAttributes(spanID: spanID, attributes: attributes)
    return 0
}

private func telemetry_setStatus(_ L: LuaState) throws -> CInt {
    let statusTable = lua_type(L, 1) == LUA_TTABLE ? tableAt(L, 1) : [:]
    let spanID = lua_isinteger(L, 2) != 0 ? UInt64(lua_tointeger(L, 2)) : nil
    telemetry(L).setSpanStatus(spanID: spanID, status: statusFromTable(statusTable))
    return 0
}

private func telemetry_addEvent(_ L: LuaState) throws -> CInt {
    let name: String = try L.checkArgument(1)
    let attributes = lua_type(L, 2) == LUA_TTABLE ? tableAt(L, 2) : [:]
    let spanID = lua_isinteger(L, 3) != 0 ? UInt64(lua_tointeger(L, 3)) : nil
    telemetry(L).addEvent(spanID: spanID, name: name, attributes: attributes, timestamp: nil)
    return 0
}

private func telemetry_recordException(_ L: LuaState) throws -> CInt {
    let message: String = try L.checkArgument(1)
    let stack = lua_type(L, 2) == LUA_TSTRING ? String(cString: lua_tostring(L, 2)) : nil
    let attributes = lua_type(L, 3) == LUA_TTABLE ? tableAt(L, 3) : [:]
    let spanID = lua_isinteger(L, 4) != 0 ? UInt64(lua_tointeger(L, 4)) : nil
    telemetry(L).recordException(spanID: spanID, message: message, stack: stack, attributes: attributes)
    return 0
}

private func telemetry_log(_ L: LuaState) throws -> CInt {
    let level: String = try L.checkArgument(1)
    let message: String = try L.checkArgument(2)
    let attributes = lua_type(L, 3) == LUA_TTABLE ? tableAt(L, 3) : [:]
    telemetry(L).recordLog(level: level, message: message, attributes: attributes, timestamp: nil)
    return 0
}

private func telemetry_metric(_ L: LuaState) throws -> CInt {
    let name: String = try L.checkArgument(1)
    let value = luaL_checknumber(L, 2)
    let options = lua_type(L, 3) == LUA_TTABLE ? tableAt(L, 3) : [:]
    let attributes = (options["attributes"] as? [String: Any]) ?? [:]
    telemetry(L).recordMetric(
        name: name,
        kind: metricKind(options["kind"]),
        value: value,
        attributes: attributes,
        unit: optionalString(options["unit"])
    )
    return 0
}

private func telemetry_inject(_ L: LuaState) throws -> CInt {
    let carrier = lua_type(L, 1) == LUA_TTABLE ? stringDictionary(tableAt(L, 1)) : [:]
    lua_pushany(L, telemetry(L).inject(into: carrier))
    return 1
}

private func telemetry_extract(_ L: LuaState) throws -> CInt {
    let carrier = lua_type(L, 1) == LUA_TTABLE ? stringDictionary(tableAt(L, 1)) : [:]
    telemetry(L).extract(from: carrier)
    return 0
}

private func telemetry_flush(_ L: LuaState) throws -> CInt {
    let timeout = lua_isnumber(L, 1) ? lua_tonumber(L, 1) : telemetry(L).configuration.timeoutSeconds
    L.push(telemetry(L).flush(timeout: timeout))
    return 1
}

private func telemetry_shutdown(_ L: LuaState) throws -> CInt {
    let timeout = lua_isnumber(L, 1) ? lua_tonumber(L, 1) : telemetry(L).configuration.timeoutSeconds
    L.push(telemetry(L).shutdown(timeout: timeout))
    return 1
}

@_cdecl("luaopen_hs_libopentelemetry")
public func luaopen_hs_libopentelemetry(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 14)
        L.push(telemetry_configure)
        lua_setfield(L, -2, "configure")
        L.push(telemetry_status)
        lua_setfield(L, -2, "status")
        L.push(telemetry_startSpan)
        lua_setfield(L, -2, "startSpan")
        L.push(telemetry_endSpan)
        lua_setfield(L, -2, "endSpan")
        L.push(telemetry_setAttributes)
        lua_setfield(L, -2, "setAttributes")
        L.push(telemetry_setStatus)
        lua_setfield(L, -2, "setStatus")
        L.push(telemetry_addEvent)
        lua_setfield(L, -2, "addEvent")
        L.push(telemetry_recordException)
        lua_setfield(L, -2, "recordException")
        L.push(telemetry_log)
        lua_setfield(L, -2, "log")
        L.push(telemetry_metric)
        lua_setfield(L, -2, "metric")
        L.push(telemetry_inject)
        lua_setfield(L, -2, "inject")
        L.push(telemetry_extract)
        lua_setfield(L, -2, "extract")
        L.push(telemetry_flush)
        lua_setfield(L, -2, "flush")
        L.push(telemetry_shutdown)
        lua_setfield(L, -2, "shutdown")
    }
}
