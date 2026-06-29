import Darwin
import Foundation
import HSDSTCore

enum BenchmarkError: Error, CustomStringConvertible {
    case help
    case invalidArguments(String)
    case missingScript(String)
    case lua(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .help:
            return CLIOptions.helpText
        case .invalidArguments(let message),
             .missingScript(let message),
             .lua(let message),
             .unsupported(let message):
            return message
        }
    }
}

enum OutputFormat: String, Codable {
    case pretty
    case json
}

enum TelemetryBackend: String, Codable {
    case simulated
    case production
}

struct CLIOptions: Codable {
    var suite = "smoke"
    var iterations = 10_000
    var warmup = 1
    var samples = 5
    var telemetry = TelemetryBackend.simulated
    var output = OutputFormat.pretty
    var scriptsRoot = "Benchmarks/otel"
    var list = false
    var allowDebug = false

    static let helpText = """
    Usage: swift run -c release OTELBenchmarks [options]

    Options:
      --suite <smoke|disabled|enabled|callbacks|baseline|all>
      --iterations <count>
      --warmup <count>
      --samples <count>
      --telemetry <simulated|production>
      --output <pretty|json>
      --scripts <path>
      --list
      --allow-debug
      --help
    """

    static func parse(_ rawArguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        func requireValue(after flag: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < rawArguments.count else {
                throw BenchmarkError.invalidArguments("missing value after \(flag)")
            }
            return rawArguments[valueIndex]
        }

        while index < rawArguments.count {
            let argument = rawArguments[index]
            switch argument {
            case "--help", "-h":
                throw BenchmarkError.help
            case "--list":
                options.list = true
            case "--allow-debug":
                options.allowDebug = true
            case "--suite":
                options.suite = try requireValue(after: argument)
                index += 1
            case "--iterations":
                options.iterations = try parsePositiveInt(try requireValue(after: argument), flag: argument)
                index += 1
            case "--warmup":
                options.warmup = try parseNonNegativeInt(try requireValue(after: argument), flag: argument)
                index += 1
            case "--samples":
                options.samples = try parsePositiveInt(try requireValue(after: argument), flag: argument)
                index += 1
            case "--telemetry":
                let rawValue = try requireValue(after: argument)
                guard let telemetry = TelemetryBackend(rawValue: rawValue) else {
                    throw BenchmarkError.invalidArguments("unsupported telemetry backend: \(rawValue)")
                }
                options.telemetry = telemetry
                index += 1
            case "--output":
                let rawValue = try requireValue(after: argument)
                guard let output = OutputFormat(rawValue: rawValue) else {
                    throw BenchmarkError.invalidArguments("unsupported output format: \(rawValue)")
                }
                options.output = output
                index += 1
            case "--scripts":
                options.scriptsRoot = try requireValue(after: argument)
                index += 1
            default:
                throw BenchmarkError.invalidArguments("unknown argument: \(argument)")
            }
            index += 1
        }

        return options
    }

    private static func parsePositiveInt(_ value: String, flag: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw BenchmarkError.invalidArguments("\(flag) must be a positive integer")
        }
        return parsed
    }

    private static func parseNonNegativeInt(_ value: String, flag: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw BenchmarkError.invalidArguments("\(flag) must be zero or a positive integer")
        }
        return parsed
    }
}

struct BenchmarkCase: Codable {
    var suite: String
    var name: String
    var script: String
    var enabled: Bool
    var notes: String
}

struct BenchmarkRegistry {
    let scriptsRoot: URL

    var cases: [BenchmarkCase] {
        [
            BenchmarkCase(suite: "baseline", name: "empty_loop", script: "baseline.lua", enabled: false, notes: "empty Lua loop baseline"),
            BenchmarkCase(suite: "disabled", name: "span_disabled", script: "span.lua", enabled: false, notes: "native start/end span calls while disabled"),
            BenchmarkCase(suite: "disabled", name: "log_disabled", script: "log.lua", enabled: false, notes: "native log calls while disabled"),
            BenchmarkCase(suite: "disabled", name: "metric_disabled", script: "metric.lua", enabled: false, notes: "native metric calls while disabled"),
            BenchmarkCase(suite: "disabled", name: "baggage_disabled", script: "baggage.lua", enabled: false, notes: "inject/extract carrier calls while disabled"),
            BenchmarkCase(suite: "enabled", name: "span_enabled", script: "span.lua", enabled: true, notes: "simulated span records while enabled"),
            BenchmarkCase(suite: "enabled", name: "log_enabled", script: "log.lua", enabled: true, notes: "simulated log records while enabled"),
            BenchmarkCase(suite: "enabled", name: "metric_enabled", script: "metric.lua", enabled: true, notes: "simulated metric records while enabled"),
            BenchmarkCase(suite: "enabled", name: "baggage_enabled", script: "baggage.lua", enabled: true, notes: "inject/extract carrier calls while enabled"),
            BenchmarkCase(suite: "callbacks", name: "callback_plain_disabled", script: "callback.lua", enabled: false, notes: "plain Lua callback loop while telemetry disabled"),
            BenchmarkCase(suite: "callbacks", name: "callback_plain_enabled", script: "callback.lua", enabled: true, notes: "plain Lua callback loop while telemetry enabled"),
        ]
    }

    init(scriptsRoot: String) {
        let rootURL = URL(fileURLWithPath: scriptsRoot, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        self.scriptsRoot = rootURL.standardizedFileURL
    }

    func selectedCases(for suite: String) throws -> [BenchmarkCase] {
        let selected: [BenchmarkCase]
        switch suite {
        case "smoke":
            selected = cases.filter { ["span_disabled", "log_disabled", "metric_disabled"].contains($0.name) }
        case "all":
            selected = cases.filter { $0.suite != "baseline" }
        case "baseline", "disabled", "enabled", "callbacks":
            selected = cases.filter { $0.suite == suite }
        default:
            throw BenchmarkError.invalidArguments("unknown suite: \(suite)")
        }

        for benchmarkCase in selected + cases.filter({ $0.suite == "baseline" }) {
            let scriptURL = scriptsRoot.appendingPathComponent(benchmarkCase.script)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                throw BenchmarkError.missingScript("missing benchmark script: \(scriptURL.path)")
            }
        }

        return selected
    }
}

struct BenchmarkSample: Codable {
    var index: Int
    var operations: Int
    var rawNanoseconds: UInt64
    var baselineNanoseconds: UInt64
    var adjustedNanoseconds: UInt64
    var nsPerOp: Double
    var adjustedNsPerOp: Double
    var rssDeltaBytes: Int64?
    var peakRSSBytes: UInt64?
}

struct TelemetryCounters: Codable {
    var startedSpans: Int
    var endedSpans: Int
    var logRecords: Int
    var metricRecords: Int
    var droppedRecords: Int
    var flushCount: Int

    init(status: TelemetryStatusSnapshot) {
        self.startedSpans = status.startedSpans
        self.endedSpans = status.endedSpans
        self.logRecords = status.logRecords
        self.metricRecords = status.metricRecords
        self.droppedRecords = status.droppedRecords
        self.flushCount = status.flushCount
    }
}

struct BenchmarkResult: Codable {
    var suite: String
    var caseName: String
    var mode: String
    var notes: String
    var iterations: Int
    var warmups: Int
    var samples: [BenchmarkSample]
    var medianNsPerOp: Double
    var p90NsPerOp: Double
    var minNsPerOp: Double
    var maxNsPerOp: Double
    var medianAdjustedNsPerOp: Double
    var baselineMedianNsPerOp: Double
    var telemetryCounters: TelemetryCounters
}

struct BenchmarkReport: Codable {
    var suite: String
    var generatedAt: String
    var config: CLIOptions
    var results: [BenchmarkResult]
}

enum MonotonicTimer {
    static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

func residentSizeBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}

func median(_ values: [Double]) -> Double {
    percentile(values, 0.50)
}

func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(max(Int((Double(sorted.count) * percentile).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
