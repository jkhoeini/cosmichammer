import Testing
import Foundation

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
