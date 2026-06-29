import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Sharing {
        @Test func testSharingLoadsWithBuiltinConstants() {
            let result = runLua("""
            (function()
                local ok, mod = pcall(require, 'hs.sharing')
                if not ok then return 'require failed: ' .. tostring(mod) end

                local writeOK = pcall(function()
                    mod.builtinSharingServices.composeEmail = 'modified'
                end)

                return table.concat({
                    type(mod),
                    type(mod.builtinSharingServices),
                    tostring(writeOK),
                    tostring(mod.builtinSharingServices.composeEmail ~= nil),
                }, ':')
            end)()
            """)

            #expect(result == "table:table:false:true")
        }

        @Test func testSharingCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libsharing) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let wrapper = HSSharingService(serviceName: "cosmichammer.test.missing-sharing-service")
                setSharingCallbackCounted(wrapper, true, L: L)
                setSharingCallbackCounted(wrapper, true, L: L)
                setSharingCallbackCounted(wrapper, false, L: L)
                setSharingCallbackCounted(wrapper, false, L: L)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.sharing.callback.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }
    }
}
