import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class IPCTelemetry {
        @Test func testIPCLocalPortActiveGauge() {
            withModuleLoaded(luaopen_hs_libipc) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let portName = "cosmic-hammer-ipc-gauge-\(UUID().uuidString)"
                lua_pushstring(L, portName)
                lua_setglobal(L, "ipcGaugePortName")

                #expect(luaEval(L, """
                    localPort = mod.localPort(ipcGaugePortName, function() end)
                    localPort:delete()
                    localPort:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.ipc.local_port.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
                #expect(sim.metrics
                    .filter { $0.name == "cosmichammer.ipc.local_port.active" }
                    .allSatisfy {
                        $0.attributes["cosmichammer.ipc.message_id"] == nil
                            && $0.attributes["ipc.message_id"] == nil
                            && $0.attributes["ipc.port.name"] == nil
                    })
            }
        }

        @Test func testCLIQueryExtractsRegisteredTelemetryContext() throws {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            sim.configure(TelemetryConfiguration(enabled: true))
            let initialSpanCount = sim.spans.count

            let result = runLua("""
                hs.opentelemetry.configure({ enabled = true })
                local originalIPC = package.loaded["hs.ipc"]
                local originalLibIPC = package.loaded["hs.libipc"]
                package.loaded["hs.ipc"] = nil
                package.loaded["hs.libipc"] = {
                    localPort = function()
                        return {
                            delete = function() end,
                            isValid = function() return true end,
                            sendMessage = function() return true end,
                        }
                    end,
                    remotePort = function()
                        return {
                            delete = function() end,
                            isValid = function() return true end,
                            sendMessage = function() return true end,
                        }
                    end,
                    print_inside = function() return false end,
                    print_enter = function() end,
                    print_exit = function() end,
                }
                local ipc = require("hs.ipc")
                local instanceID = "otelcli"
                ipc.__registeredCLIInstances[instanceID] = setmetatable({
                    _cli = {
                        telemetryContext = {
                            traceparent = "00-00000000000000000000000000000001-0000000000000042-01",
                        },
                        quietMode = true,
                    },
                    print = function() end,
                }, {
                    __index = _G,
                    __newindex = function(_, key, value) _G[key] = value end,
                })
                local response = ipc.__defaultHandler(nil, 501, instanceID .. "\\0" .. "42")
                ipc.__registeredCLIInstances[instanceID] = nil
                package.loaded["hs.ipc"] = originalIPC
                package.loaded["hs.libipc"] = originalLibIPC
                return response
                """)

            #expect(result == "42\n")

            let newSpans = Array(sim.spans.dropFirst(initialSpanCount))
            let cliSpan = try #require(newSpans.first { $0.name == "hs.cli.execute" })
            #expect(cliSpan.parentSpanID == 0x42)
            #expect(cliSpan.kind == .server)
            #expect(cliSpan.attributes["cosmichammer.lua.source"] == "cli")
            #expect(cliSpan.attributes["cosmichammer.ipc.message_id"] == "501")
            #expect(cliSpan.attributes["ipc.message_id"] == nil)
            #expect(cliSpan.attributes["messaging.message.id"] == nil)
            #expect(cliSpan.status == .ok)
        }
    }
}
