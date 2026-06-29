import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Serial {
        init() throws { try loadLuaModule("test_serial") }

        @Test func testSerialDeviceWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libserial) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    mod.deviceCallback(function() end)
                    mod.deviceCallback(function() end)
                    mod.deviceCallback(nil)
                    mod.deviceCallback(nil)
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.serial.device_watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func testAvailablePortNames() { runLuaTest() }
        @Test func testAvailablePortPaths() { runLuaTest() }
        @Test(.requiresRealOS) func testNewFromName() { runLuaTest() }
        @Test(.requiresRealOS) func testNewFromPath() { runLuaTest() }
        @Test(.requiresRealOS) func testOpenAndClose() { runLuaTest() }
        @Test(.requiresRealOS) func testAttributes() { runLuaTest() }
    }
}
