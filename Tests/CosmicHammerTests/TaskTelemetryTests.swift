import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class TaskTelemetry {
        @Test func testTaskActiveGauge() {
            withModuleLoaded(luaopen_hs_libtask) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    task = mod.new("/usr/bin/true", nil)
                    task:start()
                    task:start()
                    task:waitUntilExit()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.task.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
                #expect(sim.metrics
                    .filter { $0.name == "cosmichammer.task.active" }
                    .allSatisfy {
                        $0.attributes[TelemetrySemanticConventions.Attribute.Process.executablePath] == nil
                            && $0.attributes[TelemetrySemanticConventions.Attribute.Process.argsCount] == nil
                            && $0.attributes[TelemetrySemanticConventions.Attribute.Process.workingDirectory] == nil
                    })
            }
        }

        @Test func testTaskSpansUseSemanticProcessAttributes() throws {
            try withModuleLoaded(luaopen_hs_libtask) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    task = mod.new("/bin/echo", nil, nil, {"hello"})
                    task:start()
                    task:waitUntilExit()
                """))

                let span = try #require(sim.spans.first { $0.name == "hs.task" })
                #expect(span.attributes["process.executable.path"] == "/bin/echo")
                #expect(span.attributes["process.args_count"] == "1")
                #expect(TelemetrySemanticConventions.Attribute.Process.exitCode == "process.exit.code")
                #expect(span.attributes["process.command_args.count"] == nil)
                #expect(span.attributes["process.exit_code"] == nil)
                #expect(span.attributes["cosmichammer.process.executable.path"] == nil)
                #expect(span.attributes["cosmichammer.process.args_count"] == nil)
            }
        }
    }
}
