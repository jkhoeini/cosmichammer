import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Websocket {
        init() throws {
            try loadLuaModule("test_websocket")
            _ = runLua("startEchoServer()")
        }
        @Test func testNew() { runLuaTest() }
        @Test func testEchoData() { runTwoPartLuaTest(timeout: 8) }
        @Test func testEchoText() { runTwoPartLuaTest(timeout: 8) }
        @Test func testOpenStatus() { runTwoPartLuaTest(timeout: 5) }
        @Test func testClosedStatus() { runTwoPartLuaTest(timeout: 5) }
        @Test func testClosingStatus() { runTwoPartLuaTest(timeout: 5) }
        @Test func testLegacy() { runTwoPartLuaTest(timeout: 8) }
    }
}
