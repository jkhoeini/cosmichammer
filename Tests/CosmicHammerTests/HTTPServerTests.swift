import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class HTTPServer {
        @Test func testHTTPServerActiveGauge() {
            withModuleLoaded(luaopen_hs_libhttpserver) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    server = mod.new(false, false)
                    server:setCallback(function()
                        return "ok", 200, {}
                    end)
                    server:start()
                    server:start()
                    server:stop()
                    server:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.httpserver.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
