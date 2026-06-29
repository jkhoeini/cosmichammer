import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class NetworkPing {
        @Test func testNetworkPingActiveGauge() {
            withModuleLoaded(luaopen_hs_libnetworkping) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    pinger = mod.echoRequest("127.0.0.1")
                    pinger:start()
                    pinger:start()
                    pinger:stop()
                    pinger:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.network.ping.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func testNetworkPingProcessActiveGauge() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            sim.configure(TelemetryConfiguration(enabled: true))

            let initialMetricCount = sim.metrics.count
            let result = runLua("""
                local ping = require("hs.network.ping")
                local pinger = ping.ping("127.0.0.1", 1, 1, 1, function() end)
                pinger:cancel()
                return "ok"
            """)
            #expect(result == "ok")

            let gaugeValues = sim.metrics
                .dropFirst(initialMetricCount)
                .filter { $0.name == "cosmichammer.network.ping.process.active" }
                .map(\.value)
            #expect(gaugeValues.count == 2)
            #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
        }
    }
}
