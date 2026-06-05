import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Audiodevice {
        init() throws { try loadLuaModule("test_audiodevice") }

        @Test func testGetDefaultEffect() { runLuaTest() }
        @Test func testGetDefaultOutput() { runLuaTest() }
        @Test func testGetDefaultInput() { runLuaTest() }
        @Test func testDataSourceTypeMetadata() { runLuaTest() }
        @Test func testGetCurrentOutput() { runLuaTest() }
        @Test func testGetCurrentInput() { runLuaTest() }
        @Test(.skipInHeadless) func testGetAllDevices() { runLuaTest() }
        @Test(.skipInHeadless) func testGetAllOutputDevices() { runLuaTest() }
        @Test(.skipInHeadless) func testGetAllInputDevices() { runLuaTest() }
        @Test(.skipInHeadless) func testFindDeviceByName() { runLuaTest() }
        @Test(.skipInHeadless) func testFindDeviceByUID() { runLuaTest() }
        @Test(.skipInHeadless) func testFindInputByName() { runLuaTest() }
        @Test(.skipInHeadless) func testFindInputByUID() { runLuaTest() }
        @Test(.skipInHeadless) func testFindOutputByName() { runLuaTest() }
        @Test(.skipInHeadless) func testFindOutputByUID() { runLuaTest() }
        @Test func testToString() { runLuaTest() }
        @Test func testSetDefaultEffect() { runLuaTest() }
        @Test func testSetDefaultOutput() { runLuaTest() }
        @Test func testSetDefaultInput() { runLuaTest() }
        @Test(.skipInHeadless) func testName() { runLuaTest() }
        @Test(.skipInHeadless) func testUID() { runLuaTest() }
        @Test func testIsInputDevice() { runLuaTest() }
        @Test func testIsOutputDevice() { runLuaTest() }
        @Test func testMute() { runLuaTest() }
        @Test func testThru() { runLuaTest() }
        @Test func testVolume() { runLuaTest() }
        @Test func testInputVolume() { runLuaTest() }
        @Test func testOutputVolume() { runLuaTest() }
        @Test func testJackConnected() { runLuaTest() }
        @Test func testTransportType() { runLuaTest() }
        @Test func testWatcher() { runLuaTest() }

        @Test(.skipInHeadless) func testWatcherCallback() {
            _ = runLua("testWatcherCallback()")
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
                if runLua("testWatcherCallbackResult()") == "Success" { return }
            }
            Issue.record("hs.audiodevice watcher callback failed")
        }

        @Test(.skipInHeadless) func testInputSupportsDataSources() { runLuaTest() }
        @Test(.skipInHeadless) func testOutputSupportsDataSources() { runLuaTest() }
        @Test(.skipInHeadless) func testCurrentInputDataSource() { runLuaTest() }
        @Test(.skipInHeadless) func testCurrentOutputDataSource() { runLuaTest() }
        @Test(.skipInHeadless) func testAllInputDataSources() { runLuaTest() }
        @Test(.skipInHeadless) func testAllOutputDataSources() { runLuaTest() }
        @Test(.skipInHeadless) func testDataSourceToString() { runLuaTest() }
        @Test(.skipInHeadless) func testDataSourceName() { runLuaTest() }
        @Test(.skipInHeadless) func testDataSourceSetDefault() { runLuaTest() }
    }
}
