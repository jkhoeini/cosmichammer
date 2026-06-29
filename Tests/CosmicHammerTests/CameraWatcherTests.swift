import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class CameraWatcher {
        @Test func testCameraDeviceWatcherActiveGauge() {
            withModuleLoaded(luaopen_hs_libcamera) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    mod.setWatcherCallback(function() end)
                    mod.startWatcher()
                    mod.startWatcher()
                    mod.stopWatcher()
                    mod.stopWatcher()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.camera.device_watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
