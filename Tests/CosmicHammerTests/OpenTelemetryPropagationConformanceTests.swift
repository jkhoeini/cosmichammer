import Foundation
import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libopentelemetry")
private func luaopen_hs_libopentelemetry_for_conformance(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class OpenTelemetryPropagationConformanceTests {
        @Test func simulatedTraceparentValidFixturesParentNextSpan() throws {
            for fixture in OpenTelemetryGoldenFixtures.validTraceparentCases {
                let telemetry = SimulatedTelemetry()
                telemetry.configure(TelemetryConfiguration(enabled: true))

                telemetry.extract(from: [fixture.headerName: fixture.headerValue])
                let child = try #require(telemetry.startSpan(
                    name: "valid-\(fixture.name)",
                    kind: .server,
                    attributes: [:],
                    startTime: nil
                ))
                telemetry.endSpan(id: child, status: .ok, attributes: [:], endTime: nil)

                #expect(telemetry.spans.last?.parentSpanID == fixture.expectedParentSpanID)
            }
        }

        @Test func simulatedTraceparentInvalidFixturesClearStaleRemoteParent() throws {
            let validTraceparent = OpenTelemetryGoldenFixtures.validTraceparentCases[0].headerValue

            for fixture in OpenTelemetryGoldenFixtures.invalidTraceparentCases {
                let telemetry = SimulatedTelemetry()
                telemetry.configure(TelemetryConfiguration(enabled: true))
                telemetry.extract(from: ["traceparent": validTraceparent])
                telemetry.extract(from: ["traceparent": fixture.headerValue])

                let child = try #require(telemetry.startSpan(
                    name: "invalid-\(fixture.name)",
                    kind: .server,
                    attributes: [:],
                    startTime: nil
                ))
                telemetry.endSpan(id: child, status: .ok, attributes: [:], endTime: nil)

                #expect(telemetry.spans.last?.parentSpanID == nil)
            }
        }

        @Test func simulatedTraceparentInjectionUsesCanonicalW3CHeader() throws {
            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(enabled: true))
            let span = try #require(telemetry.startSpan(
                name: "inject",
                kind: .client,
                attributes: [:],
                startTime: nil
            ))

            let carrier = telemetry.inject(into: [:])
            telemetry.endSpan(id: span, status: .ok, attributes: [:], endTime: nil)

            #expect(carrier["traceparent"] == "00-00000000000000000000000000000001-0000000000000001-01")
        }

        @Test func luaFacadeBaggageExtractionMatchesGoldenFixtures() {
            withModuleLoaded(luaopen_hs_libopentelemetry_for_conformance) { L in
                let luaPath = opentelemetryLuaPath()

                for fixture in OpenTelemetryGoldenFixtures.baggageExtractionCases {
                    #expect(luaEval(L, """
                    hs = {}
                    local native = mod
                    package.preload["hs.libopentelemetry"] = function() return native end
                    otel = assert(loadfile(\(luaString(luaPath))))()
                    otel.configure({ enabled = true })
                    otel.setBaggage("stale", "value")
                    otel.extract({ [\(luaString(fixture.headerName))] = \(luaString(fixture.headerValue)) })
                    remoteBaggage = otel.getBaggage()
                    diagnostics = otel.diagnostics()
                    """))

                    for (key, expectedValue) in fixture.expectedItems {
                        #expect(luaGlobalTableString(L, global: "remoteBaggage", key: key) == expectedValue)
                    }
                    for key in fixture.rejectedKeys {
                        #expect(luaGlobalTableString(L, global: "remoteBaggage", key: key) == nil)
                    }
                    #expect(luaGlobalTableString(L, global: "remoteBaggage", key: "stale") == nil)

                    lua_getglobal(L, "diagnostics")
                    lua_getfield(L, -1, "baggageCount")
                    #expect(lua_tointeger(L, -1) == lua_Integer(fixture.expectedItems.count))
                    lua_pop(L, 2)
                }
            }
        }

        @Test func luaFacadeBaggageInjectionMatchesGoldenFixtures() {
            withModuleLoaded(luaopen_hs_libopentelemetry_for_conformance) { L in
                let luaPath = opentelemetryLuaPath()

                for fixture in OpenTelemetryGoldenFixtures.baggageInjectionCases {
                    let setters = fixture.items
                        .sorted { $0.key < $1.key }
                        .map { "otel.setBaggage(\(luaString($0.key)), \(luaString($0.value)))" }
                        .joined(separator: "\n")

                    #expect(luaEval(L, """
                    hs = {}
                    local native = mod
                    package.preload["hs.libopentelemetry"] = function() return native end
                    otel = assert(loadfile(\(luaString(luaPath))))()
                    otel.configure({ enabled = true })
                    \(setters)
                    injected = otel.inject({ baggage = "stale=yes", Baggage = "also=stale" })
                    """))

                    #expect(luaGlobalTableString(L, global: "injected", key: "baggage") == fixture.expectedHeader)
                    #expect(luaGlobalTableString(L, global: "injected", key: "Baggage") == nil)
                }
            }
        }

        @Test
        func w3cTraceparentRejectsUppercaseHexFields() throws {
            for fixture in OpenTelemetryGoldenFixtures.currentlyAcceptedInvalidTraceparentCases {
                let telemetry = SimulatedTelemetry()
                telemetry.configure(TelemetryConfiguration(enabled: true))
                telemetry.extract(from: ["traceparent": fixture.headerValue])

                let child = try #require(telemetry.startSpan(
                    name: "uppercase-\(fixture.name)",
                    kind: .server,
                    attributes: [:],
                    startTime: nil
                ))
                telemetry.endSpan(id: child, status: .ok, attributes: [:], endTime: nil)

                #expect(telemetry.spans.last?.parentSpanID == nil)
            }
        }
    }
}

private func opentelemetryLuaPath() -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
        .path
}

private func luaString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "'", with: "\\'")
    return "'\(escaped)'"
}

private func luaGlobalTableString(_ L: UnsafeMutablePointer<lua_State>, global: String, key: String) -> String? {
    lua_getglobal(L, global)
    defer { lua_pop(L, 1) }
    guard lua_istable(L, -1) != 0 else { return nil }
    lua_getfield(L, -1, key)
    defer { lua_pop(L, 1) }
    guard lua_type(L, -1) == LUA_TSTRING else { return nil }
    return String(cString: lua_tostring(L, -1))
}
