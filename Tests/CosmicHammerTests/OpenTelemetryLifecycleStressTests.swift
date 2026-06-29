import Foundation
import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libopentelemetry")
private func luaopen_hs_libopentelemetry_lifecycle_stress(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_liblsqlite3")
private func luaopen_hs_liblsqlite3_lifecycle_stress(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class OpenTelemetryLifecycleStressTests {
        @Test func repeatedNativeConfigureFlushShutdownReconfigureClearsContext() throws {
            let telemetry = SimulatedTelemetry()
            let cycles = 12

            for cycle in 0..<cycles {
                telemetry.configure(TelemetryConfiguration(
                    enabled: true,
                    serviceName: "stress-\(cycle)",
                    callbackSampleRates: ["*": 1]
                ))
                _ = try #require(telemetry.startSpan(
                    name: "stale-active-\(cycle)",
                    kind: .internalSpan,
                    attributes: [:],
                    startTime: nil
                ))
                telemetry.extract(from: ["traceparent": traceparent(parentID: 0x100 + UInt64(cycle))])

                #expect(telemetry.flush(timeout: 0.1))
                #expect(telemetry.shutdown(timeout: 0.1))
                #expect(telemetry.status().activeSpanID == nil)

                let afterShutdown = try #require(telemetry.startSpan(
                    name: "after-shutdown-\(cycle)",
                    kind: .internalSpan,
                    attributes: [:],
                    startTime: nil
                ))
                telemetry.endSpan(id: afterShutdown, status: .ok, attributes: [:], endTime: nil)

                telemetry.extract(from: ["traceparent": traceparent(parentID: 0x200 + UInt64(cycle))])
                telemetry.configure(TelemetryConfiguration(
                    enabled: true,
                    serviceName: "stress-reconfigured-\(cycle)",
                    callbackSampleRates: ["*": 1]
                ))

                let afterReconfigure = try #require(telemetry.startSpan(
                    name: "after-reconfigure-\(cycle)",
                    kind: .internalSpan,
                    attributes: [:],
                    startTime: nil
                ))
                telemetry.endSpan(id: afterReconfigure, status: .ok, attributes: [:], endTime: nil)
            }

            #expect(telemetry.flushCount == cycles * 2)
            #expect(telemetry.shutdownCount == cycles)
            #expect(telemetry.status().activeSpanID == nil)
            #expect(telemetry.status().serviceName == "stress-reconfigured-\(cycles - 1)")
            #expect(telemetry.lastFlushDuration == nil)
            #expect(telemetry.status().lastFlushResult == nil)

            let resetProbeSpans = telemetry.spans.filter {
                $0.name.hasPrefix("after-shutdown-") || $0.name.hasPrefix("after-reconfigure-")
            }
            #expect(resetProbeSpans.count == cycles * 2)
            #expect(resetProbeSpans.allSatisfy { $0.parentSpanID == nil && $0.ended })
        }

        @Test func luaFacadeStateResetsAcrossIsolatedReloads() throws {
            for cycle in 0..<8 {
                try withModuleLoaded(luaopen_hs_libopentelemetry_lifecycle_stress) { L in
                    let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                    let luaPath = escapedOpenTelemetryLuaPath()

                    #expect(luaEval(L, """
                    hs = {}
                    local native = mod
                    package.preload["hs.libopentelemetry"] = function() return native end
                    otel = assert(loadfile('\(luaPath)'))()

                    staleBeforeSet = otel.getBaggage("cycle")
                    local redactorCalls = 0
                    otel.setRedactor(function(key, value)
                      redactorCalls = redactorCalls + 1
                      if key == "secret" then return nil end
                      return value
                    end)

                    otel.configure({ enabled = true, serviceName = "reload-\(cycle)" })
                    otel.setBaggage("cycle", "\(cycle)")
                    span = otel.startSpan("facade-reload-\(cycle)", {
                      attributes = { secret = "drop", kept = "yes" },
                    })
                    headers = otel.inject({})
                    span:endSpan({ code = "ok" })
                    shutdownOK = otel.shutdown(1)
                    diagnostics = otel.diagnostics()
                    redactorCallCount = redactorCalls
                    """))

                    #expect(sim.configuration.serviceName == "reload-\(cycle)")
                    let span = try #require(sim.spans.first { $0.name == "facade-reload-\(cycle)" })
                    #expect(span.attributes["secret"] == nil)
                    #expect(span.attributes["kept"] == "yes")
                    #expect(span.ended)
                    #expect(sim.shutdownCount == 1)
                    #expect(sim.flushCount == 1)

                    assertGlobalNil(L, "staleBeforeSet")
                    assertGlobalBool(L, "shutdownOK", true)
                    assertGlobalNumberAtLeast(L, "redactorCallCount", 2)

                    lua_getglobal(L, "headers")
                    lua_getfield(L, -1, "baggage")
                    #expect(String(cString: lua_tostring(L, -1)).contains("cycle=\(cycle)"))
                    lua_pop(L, 2)

                    lua_getglobal(L, "diagnostics")
                    lua_getfield(L, -1, "activeSpanID")
                    #expect(lua_isnil(L, -1) != 0)
                    lua_pop(L, 1)
                    lua_getfield(L, -1, "redactorInstalled")
                    #expect(lua_toboolean(L, -1) != 0)
                    lua_pop(L, 2)
                }
            }
        }

        @Test func directCallbackTelemetrySurvivesDuringAndAfterReconfiguration() throws {
            try withModuleLoaded(luaopen_hs_libopentelemetry_lifecycle_stress) { L in
                resetLuaCallbackTelemetrySamplingCounters()
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(
                    enabled: true,
                    callbackSampleRates: ["test.lifecycle": 1]
                ))

                let staleParent = try #require(sim.startSpan(
                    name: "stale-parent",
                    kind: .internalSpan,
                    attributes: [:],
                    startTime: nil
                ))

                #expect(luaEval(L, """
                function reconfiguringCallback()
                  mod.configure({
                    enabled = true,
                    callbackSampleRates = { ["test.lifecycle"] = 1 },
                  })
                  return "during"
                end

                function afterReconfigureCallback()
                  return "after"
                end
                """))

                lua_getglobal(L, "reconfiguringCallback")
                #expect(luaTelemetryPCall(
                    L,
                    nargs: 0,
                    nresults: 1,
                    callbackName: "test.lifecycle",
                    attributes: ["phase": "during"]
                ) == LUA_OK)
                #expect(String(cString: lua_tostring(L, -1)) == "during")
                lua_pop(L, 1)

                let duringSpan = try #require(sim.spans.first {
                    $0.name == "lua.callback" && $0.attributes["phase"] == "during"
                })
                #expect(duringSpan.parentSpanID == staleParent)
                #expect(duringSpan.ended)
                #expect(sim.status().activeSpanID == nil)

                let afterInternalReconfigure = try #require(sim.startSpan(
                    name: "after-internal-reconfigure",
                    kind: .internalSpan,
                    attributes: [:],
                    startTime: nil
                ))
                sim.endSpan(id: afterInternalReconfigure, status: .ok, attributes: [:], endTime: nil)
                #expect(sim.spans.first { $0.name == "after-internal-reconfigure" }?.parentSpanID == nil)

                lua_getglobal(L, "afterReconfigureCallback")
                #expect(luaTelemetryPCall(
                    L,
                    nargs: 0,
                    nresults: 1,
                    callbackName: "test.lifecycle",
                    attributes: ["phase": "after"],
                    parentContext: ["traceparent": traceparent(parentID: 0x42)]
                ) == LUA_OK)
                #expect(String(cString: lua_tostring(L, -1)) == "after")
                lua_pop(L, 1)

                let afterSpan = try #require(sim.spans.first {
                    $0.name == "lua.callback" && $0.attributes["phase"] == "after"
                })
                #expect(afterSpan.parentSpanID == 0x42)
                #expect(afterSpan.ended)
            }
        }

        @Test func callbackSamplingCountersAreProcessGlobalAcrossLuaStates() throws {
            resetLuaCallbackTelemetrySamplingCounters()
            var firstSampledCallbacks = 0
            var secondSampledCallbacks = 0

            try withModuleLoaded(luaopen_hs_libopentelemetry_lifecycle_stress) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(
                    enabled: true,
                    callbackSampleRates: ["test.global-sampling": 0.5]
                ))

                #expect(luaEval(L, "function globalSamplingCallback() return 'first' end"))
                lua_getglobal(L, "globalSamplingCallback")
                #expect(luaTelemetryPCall(
                    L,
                    nargs: 0,
                    nresults: 1,
                    callbackName: "test.global-sampling"
                ) == LUA_OK)
                #expect(String(cString: lua_tostring(L, -1)) == "first")
                lua_pop(L, 1)

                firstSampledCallbacks = sim.spans.filter {
                    $0.name == "lua.callback"
                        && $0.attributes["cosmichammer.lua.callback.name"] == "test.global-sampling"
                }.count
            }

            try withModuleLoaded(luaopen_hs_libopentelemetry_lifecycle_stress) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(
                    enabled: true,
                    callbackSampleRates: ["test.global-sampling": 0.5]
                ))

                #expect(luaEval(L, "function globalSamplingCallback() return 'second' end"))
                lua_getglobal(L, "globalSamplingCallback")
                #expect(luaTelemetryPCall(
                    L,
                    nargs: 0,
                    nresults: 1,
                    callbackName: "test.global-sampling"
                ) == LUA_OK)
                #expect(String(cString: lua_tostring(L, -1)) == "second")
                lua_pop(L, 1)

                secondSampledCallbacks = sim.spans.filter {
                    $0.name == "lua.callback"
                        && $0.attributes["cosmichammer.lua.callback.name"] == "test.global-sampling"
                }.count
            }

            #expect(firstSampledCallbacks == 0)
            #expect(secondSampledCallbacks == 1)
        }

        @Test func sqliteCallbackGaugeLifecycleStressReturnsToZero() {
            withModuleLoaded(luaopen_hs_liblsqlite3_lifecycle_stress) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                for i = 1, 12 do
                  local db = mod.open_memory()
                  db:busy_handler(function() return false end)
                  db:busy_handler(function() return false end)
                  db:progress_handler(1, function() return false end)
                  db:trace(function() end)
                  db:update_hook(function() end)
                  db:commit_hook(function() return false end)
                  db:rollback_hook(function() end)
                  assert(db:create_function("stress_noop_" .. i, 0, function(ctx) end))
                  assert(db:create_aggregate(
                    "stress_agg_" .. i,
                    0,
                    function(ctx) end,
                    function(ctx) end
                  ))
                  assert(db:close() == 0)
                end
                """))

                let hookGaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.sqlite3.hook.callback.active" }
                    .map(\.value)
                let functionGaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.sqlite3.function.callback.active" }
                    .map(\.value)

                #expect(hookGaugeValues.last == 0)
                #expect(hookGaugeValues.max() == 6)
                #expect(hookGaugeValues.allSatisfy { $0 >= 0 && $0 <= 6 })
                #expect(hookGaugeValues.filter { $0 == 0 }.count == 12)

                #expect(functionGaugeValues.last == 0)
                #expect(functionGaugeValues.max() == 2)
                #expect(functionGaugeValues.allSatisfy { $0 >= 0 && $0 <= 2 })
                #expect(functionGaugeValues.filter { $0 == 0 }.count == 12)
            }
        }
    }
}

private let otelLifecycleStressRepoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}()

private func escapedOpenTelemetryLuaPath() -> String {
    otelLifecycleStressRepoRoot
        .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
        .path
        .replacingOccurrences(of: "'", with: "\\'")
}

private func traceparent(parentID: UInt64) -> String {
    "00-00000000000000000000000000000001-\(String(format: "%016llx", parentID))-01"
}

private func assertGlobalNil(_ L: UnsafeMutablePointer<lua_State>, _ name: String) {
    lua_getglobal(L, name)
    #expect(lua_isnil(L, -1) != 0)
    lua_pop(L, 1)
}

private func assertGlobalBool(_ L: UnsafeMutablePointer<lua_State>, _ name: String, _ expected: Bool) {
    lua_getglobal(L, name)
    #expect((lua_toboolean(L, -1) != 0) == expected)
    lua_pop(L, 1)
}

private func assertGlobalNumberAtLeast(_ L: UnsafeMutablePointer<lua_State>, _ name: String, _ minimum: lua_Number) {
    lua_getglobal(L, name)
    #expect(lua_tonumber(L, -1) >= minimum)
    lua_pop(L, 1)
}
