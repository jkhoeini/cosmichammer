import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Bonjour {
        @Test func testBonjourBrowserActiveGauge() {
            withModuleLoaded(luaopen_hs_libbonjour) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    browser = mod.new()
                    browser:findBrowsableDomains(function() end)
                    browser:stop()
                    browser:stop()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.bonjour.browser.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func testBonjourServiceMonitorActiveGauge() {
            withModuleLoaded(luaopen_hs_libbonjourservice) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let serviceName = "bonjour-service-monitor-gauge-\(UUID().uuidString)"
                lua_pushstring(L, serviceName)
                lua_setglobal(L, "bonjourServiceMonitorGaugeName")

                #expect(luaEval(L, """
                    service = mod.new(bonjourServiceMonitorGaugeName, "_http._tcp.", 54321, "local.")
                    service:monitor(function() end)
                    service:monitor(function() end)
                    service:stopMonitoring()
                    service:stopMonitoring()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.bonjour.service.monitor.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func testBonjourServicePublishActiveGauge() {
            withModuleLoaded(luaopen_hs_libbonjourservice) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustBonjourServicePublishCount(-1000, L: L)
                adjustBonjourServicePublishCount(1, L: L)
                adjustBonjourServicePublishCount(1, L: L)
                adjustBonjourServicePublishCount(-1, L: L)
                adjustBonjourServicePublishCount(-1000, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.bonjour.service.publish.active" }
                    .map(\.value)
                #expect(gaugeValues == [0, 1, 2, 1, 0])
            }
        }

        @Test func testBonjourServiceResolveActiveGauge() {
            withModuleLoaded(luaopen_hs_libbonjourservice) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                adjustBonjourServiceResolveCount(-1000, L: L)
                adjustBonjourServiceResolveCount(1, L: L)
                adjustBonjourServiceResolveCount(1, L: L)
                adjustBonjourServiceResolveCount(-1, L: L)
                adjustBonjourServiceResolveCount(-1000, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.bonjour.service.resolve.active" }
                    .map(\.value)
                #expect(gaugeValues == [0, 1, 2, 1, 0])
            }
        }
    }
}
