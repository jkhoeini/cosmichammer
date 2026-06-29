import Foundation
import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Pathwatcher {
        @Test func testPathwatcherActiveGauge() throws {
            let watchURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cosmichammer-pathwatcher-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: watchURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: watchURL) }

            withModuleLoaded(luaopen_hs_libpathwatcher) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                L.push(watchURL.path)
                lua_setglobal(L, "watchPath")

                #expect(luaEval(L, """
                    watcher = mod.new(watchPath, function() end)
                    watcher:start()
                    watcher:start()
                    watcher:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.pathwatcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues == [1, 0])
            }
        }
    }
}
