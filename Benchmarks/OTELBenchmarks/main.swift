import Darwin
import Foundation

runOTELBenchmarks()

private func runOTELBenchmarks() {
    do {
        let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let registry = BenchmarkRegistry(scriptsRoot: options.scriptsRoot)

        if options.list {
            for benchmarkCase in registry.cases {
                print("\(benchmarkCase.suite)/\(benchmarkCase.name) -> \(benchmarkCase.script)")
            }
            return
        }

        #if DEBUG
        guard options.allowDebug else {
            throw BenchmarkError.invalidArguments("OTEL benchmarks must run with -c release; pass --allow-debug only for CLI smoke checks")
        }
        #endif

        let selectedCases = try registry.selectedCases(for: options.suite)
        let runner = BenchmarkRunner(options: options, registry: registry)
        let results = try selectedCases.map { try runner.run($0) }
        let report = BenchmarkReport(
            suite: options.suite,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            config: options,
            results: results
        )

        switch options.output {
        case .pretty:
            PrettyReporter.print(report)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            print("")
        }
    } catch BenchmarkError.help {
        print(CLIOptions.helpText)
    } catch {
        writeStandardError("error: \(error)")
        Darwin.exit(1)
    }
}

struct BenchmarkRunner {
    let options: CLIOptions
    let registry: BenchmarkRegistry

    func run(_ benchmarkCase: BenchmarkCase) throws -> BenchmarkResult {
        let runtime = try LuaOTELBenchmarkRuntime(telemetryBackend: options.telemetry)
        try runtime.configureTelemetry(enabled: benchmarkCase.enabled)

        let baselineURL = registry.scriptsRoot.appendingPathComponent("baseline.lua")
        let benchmarkURL = registry.scriptsRoot.appendingPathComponent(benchmarkCase.script)
        let baselineRef = try runtime.loadRunFunction(scriptURL: baselineURL)
        let benchmarkRef = try runtime.loadRunFunction(scriptURL: benchmarkURL)
        defer {
            runtime.releaseRunFunction(baselineRef)
            runtime.releaseRunFunction(benchmarkRef)
        }

        for _ in 0..<options.warmup {
            _ = try runtime.run(ref: baselineRef, iterations: options.iterations)
            _ = try runtime.run(ref: benchmarkRef, iterations: options.iterations)
        }

        var samples: [BenchmarkSample] = []
        samples.reserveCapacity(options.samples)

        for index in 0..<options.samples {
            let baseline = try measure(runtime: runtime, ref: baselineRef)
            let measured = try measure(runtime: runtime, ref: benchmarkRef)
            let adjusted = measured.elapsedNanoseconds > baseline.elapsedNanoseconds
                ? measured.elapsedNanoseconds - baseline.elapsedNanoseconds
                : 0
            let operations = max(measured.returnValue.operations, 1)
            let rssDelta = memoryDelta(before: measured.rssBefore, after: measured.rssAfter)

            samples.append(BenchmarkSample(
                index: index,
                operations: operations,
                rawNanoseconds: measured.elapsedNanoseconds,
                baselineNanoseconds: baseline.elapsedNanoseconds,
                adjustedNanoseconds: adjusted,
                nsPerOp: Double(measured.elapsedNanoseconds) / Double(operations),
                adjustedNsPerOp: Double(adjusted) / Double(operations),
                rssDeltaBytes: rssDelta,
                peakRSSBytes: measured.rssAfter
            ))
        }

        let nsPerOp = samples.map(\.nsPerOp)
        let adjustedNsPerOp = samples.map(\.adjustedNsPerOp)
        let baselineNsPerOp = samples.map {
            Double($0.baselineNanoseconds) / Double(max($0.operations, 1))
        }

        return BenchmarkResult(
            suite: benchmarkCase.suite,
            caseName: benchmarkCase.name,
            mode: benchmarkCase.enabled ? "enabled" : "disabled",
            notes: benchmarkCase.notes,
            iterations: options.iterations,
            warmups: options.warmup,
            samples: samples,
            medianNsPerOp: median(nsPerOp),
            p90NsPerOp: percentile(nsPerOp, 0.90),
            minNsPerOp: nsPerOp.min() ?? 0,
            maxNsPerOp: nsPerOp.max() ?? 0,
            medianAdjustedNsPerOp: median(adjustedNsPerOp),
            baselineMedianNsPerOp: median(baselineNsPerOp),
            telemetryCounters: runtime.telemetryCounters()
        )
    }

    private func measure(runtime: LuaOTELBenchmarkRuntime, ref: Int32) throws -> TimedLuaRun {
        let rssBefore = residentSizeBytes()
        let start = MonotonicTimer.nowNanoseconds()
        let returnValue = try runtime.run(ref: ref, iterations: options.iterations)
        let elapsed = MonotonicTimer.nowNanoseconds() - start
        let rssAfter = residentSizeBytes()
        return TimedLuaRun(
            elapsedNanoseconds: elapsed,
            returnValue: returnValue,
            rssBefore: rssBefore,
            rssAfter: rssAfter
        )
    }

    private func memoryDelta(before: UInt64?, after: UInt64?) -> Int64? {
        guard let before, let after else { return nil }
        return Int64(after) - Int64(before)
    }
}

private struct TimedLuaRun {
    var elapsedNanoseconds: UInt64
    var returnValue: LuaBenchmarkReturn
    var rssBefore: UInt64?
    var rssAfter: UInt64?
}

enum PrettyReporter {
    static func print(_ report: BenchmarkReport) {
        Swift.print("OTEL Benchmarks")
        Swift.print("suite: \(report.suite)")
        Swift.print("telemetry: \(report.config.telemetry.rawValue)")
        Swift.print("iterations: \(report.config.iterations), warmup: \(report.config.warmup), samples: \(report.config.samples)")
        Swift.print("")
        Swift.print("\(pad("case", to: 28)) \(pad("median", to: 10)) \(pad("p90", to: 10)) \(pad("adjusted", to: 10)) \(pad("baseline", to: 10))")

        for result in report.results {
            let row = [
                pad(result.caseName, to: 28),
                leftPad(String(format: "%.1f", result.medianNsPerOp), to: 10),
                leftPad(String(format: "%.1f", result.p90NsPerOp), to: 10),
                leftPad(String(format: "%.1f", result.medianAdjustedNsPerOp), to: 10),
                leftPad(String(format: "%.1f", result.baselineMedianNsPerOp), to: 10),
            ].joined(separator: " ")
            Swift.print(row)
            Swift.print("  counters: spans \(result.telemetryCounters.startedSpans)/\(result.telemetryCounters.endedSpans), logs \(result.telemetryCounters.logRecords), metrics \(result.telemetryCounters.metricRecords), dropped \(result.telemetryCounters.droppedRecords)")
        }

        Swift.print("")
        Swift.print("All timing columns are ns/op. Adjusted subtracts the empty-loop baseline for the same sample.")
    }

    private static func pad(_ value: String, to width: Int) -> String {
        value.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func leftPad(_ value: String, to width: Int) -> String {
        let padding = max(width - value.count, 0)
        return String(repeating: " ", count: padding) + value
    }
}
