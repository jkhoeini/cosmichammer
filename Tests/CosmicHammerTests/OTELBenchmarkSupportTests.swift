import Foundation
import Testing

extension CosmicHammerTests {
    @Suite final class OTELBenchmarkSupportTests {
        private var repositoryRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        @Test func benchmarkLuaWorkloadInventoryIsCheckedIn() throws {
            let benchmarkRoot = repositoryRoot.appendingPathComponent("Benchmarks/otel")
            let expectedScripts = [
                "baggage.lua",
                "callback.lua",
                "log.lua",
                "metric.lua",
                "span.lua",
            ]

            for script in expectedScripts {
                let scriptURL = benchmarkRoot.appendingPathComponent(script)
                #expect(FileManager.default.fileExists(atPath: scriptURL.path), "\(script) should be checked in")

                let source = try String(contentsOf: scriptURL, encoding: .utf8)
                #expect(source.contains("function run(iterations)"), "\(script) should expose run(iterations)")
                #expect(source.contains("return"), "\(script) should return a small result table")
            }
        }

        @Test func otelJustRecipesStayOptIn() throws {
            let justfile = try String(
                contentsOf: repositoryRoot.appendingPathComponent("justfile"),
                encoding: .utf8
            )
            let expectedRecipes = [
                "bench-otel",
                "bench-otel-smoke",
                "bench-otel-full",
                "otel-test",
                "otel-conformance",
                "otel-collector-test",
                "otel-stress-test",
                "otel-benchmark",
                "otel-local-checks",
                "otel-grpc-integration",
            ]

            for recipe in expectedRecipes {
                #expect(justfile.contains("\n\(recipe)"), "missing just recipe \(recipe)")
            }

            let verifyLine = justfile
                .split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("verify:") }
                .map(String.init) ?? ""
            #expect(!verifyLine.contains("otel-local-checks"))
            #expect(!verifyLine.contains("bench-otel"))
            #expect(justfile.contains("OpenTelemetryPropagationConformanceTests"))
            #expect(justfile.contains("OpenTelemetryOTLPExportTests"))
            #expect(justfile.contains("OpenTelemetryLifecycleStressTests"))
        }

        @Test func opentelemetryDocsDescribeLocalVerification() throws {
            let docs = try String(
                contentsOf: repositoryRoot.appendingPathComponent("docs/opentelemetry.md"),
                encoding: .utf8
            )

            #expect(docs.contains("OTEL Benchmarks"))
            #expect(docs.contains("Local Verification"))
            #expect(docs.contains("just bench-otel-smoke"))
            #expect(docs.contains("OTEL_COLLECTOR_TESTS=1"))
            #expect(docs.contains("advisory"))
            #expect(!docs.localizedCaseInsensitiveContains("continuous integration"))
        }
    }
}
