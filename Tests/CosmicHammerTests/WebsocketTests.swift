import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Websocket {
        init() throws {
            try configureWebsocketTestEnvironment()
            try loadLuaModule("test_websocket")
            _ = runLua("startEchoServer()")
            let initSpinDuration: TimeInterval = testHarness != nil ? 0.001 : 0.2
            RunLoop.main.run(until: Date(timeIntervalSinceNow: initSpinDuration))
        }
        @Test func testNew() { runLuaTest() }
        @Test func testNewWss() { runLuaTest() }

        private func runLuaSendTest(
            setup: String,
            valueCheck: String,
            cleanup: String,
            initialCount: Int,
            currentCount: () -> Int
        ) {
            defer { _ = runLua(cleanup) }

            let setupResult = runLua(setup)
            guard setupResult == "Success" else {
                Issue.record("Setup failed: \(setup) returned \(setupResult ?? "nil")")
                return
            }

            let deadline = Date(timeIntervalSinceNow: 8)
            var sawFrame = false
            var lastValueResult: String?
            while Date() < deadline {
                let spinDuration: TimeInterval = testHarness != nil ? 0.001 : 0.5
                RunLoop.main.run(until: Date(timeIntervalSinceNow: spinDuration))
                testHarness?.advanceTime(by: 0.5)
                sawFrame = sawFrame || currentCount() > initialCount
                lastValueResult = runLua(valueCheck)
                if sawFrame && lastValueResult == "Success" { return }
            }
            Issue.record("Timed out waiting for websocket echo from \(setup); sawFrame=\(sawFrame); last value result=\(lastValueResult ?? "nil")")
        }

        @Test func testEchoData() {
            runLuaSendTest(
                setup: "testEchoData()",
                valueCheck: "testEchoDataValues()",
                cleanup: "testEchoDataCleanup()",
                initialCount: localWebSocketBinaryFrameCount(),
                currentCount: localWebSocketBinaryFrameCount
            )
        }

        @Test func testEchoText() {
            runLuaSendTest(
                setup: "testEchoText()",
                valueCheck: "testEchoTextValues()",
                cleanup: "testEchoTextCleanup()",
                initialCount: localWebSocketTextFrameCount(),
                currentCount: localWebSocketTextFrameCount
            )
        }
        @Test func testOpenStatus() { runTwoPartLuaTest(timeout: 5) }
        @Test func testClosedStatus() { runTwoPartLuaTest(timeout: 5) }
        @Test func testCloseStatusAfterClose() { runTwoPartLuaTest(timeout: 5) }
        @Test func testWebSocketActiveGauge() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            sim.configure(TelemetryConfiguration(enabled: true))

            let echoURL = ProcessInfo.processInfo.environment["COSMIC_HAMMER_TEST_WEBSOCKET_URL"]
                ?? "ws://localhost:8067/"
            let setupResult = runLua("""
                websocketGaugeEvents = {}
                websocketGaugeObject = require("hs.websocket").new("\(echoURL)", function(event)
                    websocketGaugeEvents[#websocketGaugeEvents + 1] = event
                end)
                return success()
            """)
            guard setupResult == "Success" else {
                Issue.record("Setup failed: websocket active gauge returned \(setupResult ?? "nil")")
                return
            }
            defer {
                _ = runLua("""
                    if websocketGaugeObject then websocketGaugeObject:close() end
                    websocketGaugeObject = nil
                    websocketGaugeEvents = nil
                    collectgarbage()
                    collectgarbage()
                    return success()
                """)
            }

            let openDeadline = Date(timeIntervalSinceNow: 5)
            while Date() < openDeadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                testHarness?.advanceTime(by: 0.1)
                let sawOpen = sim.metrics.contains {
                    $0.name == "cosmichammer.websocket.active" && $0.value >= 1
                }
                if sawOpen { break }
            }

            _ = runLua("websocketGaugeObject:close(); return success()")

            let closeDeadline = Date(timeIntervalSinceNow: 5)
            while Date() < closeDeadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                testHarness?.advanceTime(by: 0.1)
                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.websocket.active" }
                    .map(\.value)
                if gaugeValues.count >= 2, gaugeValues.last == gaugeValues.first.map({ max(0, $0 - 1) }) {
                    return
                }
            }

            let gaugeValues = sim.metrics
                .filter { $0.name == "cosmichammer.websocket.active" }
                .map(\.value)
            #expect(gaugeValues.count >= 2)
            #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
        }
        @Test func testLegacy() {
            runLuaSendTest(
                setup: "testLegacy()",
                valueCheck: "testLegacyValues()",
                cleanup: "testLegacyCleanup()",
                initialCount: localWebSocketBinaryFrameCount(),
                currentCount: localWebSocketBinaryFrameCount
            )
        }
    }
}
