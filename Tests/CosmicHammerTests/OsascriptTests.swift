import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Osascript {
        init() throws { try loadLuaModule("test_osascript") }

        @Test func testJavaScriptParseError() { runLuaTest() }
        @Test func testJavaScriptAddition() { runLuaTest() }
        @Test func testJavaScriptDestructuring() { runLuaTest() }
        @Test func testJavaScriptString() { runLuaTest() }
        @Test func testJavaScriptArray() { runLuaTest() }
        @Test func testJavaScriptJsonStringify() { runLuaTest() }
        @Test func testJavaScriptJsonParse() { runLuaTest() }
        @Test func testJavaScriptJsonParseError() { runLuaTest() }
        @Test func testAppleScriptParseError() { runLuaTest() }
        @Test func testAppleScriptAddition() { runLuaTest() }
        @Test func testAppleScriptString() { runLuaTest() }
        @Test func testAppleScriptArray() { runLuaTest() }
        @Test func testAppleScriptDict() { runLuaTest() }
        @Test func testAppleScriptExecutionError() { runLuaTest() }

        @Test func testOsascriptExecutionRecordsTelemetry() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            let initialSpanCount = sim.spans.count

            let result = runLua("""
                hs.opentelemetry.configure({ enabled = true })
                local ok, object = hs.osascript.javascript("2+2")
                return tostring(ok) .. ":" .. tostring(object)
                """)

            #expect(result == "true:4")
            let span = sim.spans
                .dropFirst(initialSpanCount)
                .first { $0.name == "hs.osascript.execute" }
            #expect(span?.attributes["osa.language"] == "JavaScript")
            #expect(span?.attributes["osa.source.length"] == "3")
            #expect(span?.status == .ok)
            #expect(span?.ended == true)
            #expect(span?.attributes["osa.source"] == nil)
        }

        @Test func testOsascriptExecutionActiveGauge() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            let initialMetricCount = sim.metrics.count

            let result = runLua("""
                hs.opentelemetry.configure({ enabled = true })
                local ok, object = hs.osascript.javascript("2+2")
                return tostring(ok) .. ":" .. tostring(object)
                """)

            #expect(result == "true:4")
            let gaugeValues = sim.metrics
                .dropFirst(initialMetricCount)
                .filter { $0.name == "cosmichammer.osascript.execution.active" }
                .map(\.value)
            #expect(gaugeValues == [1, 0])
        }
    }
}
