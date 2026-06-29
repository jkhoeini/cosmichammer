import Foundation

public enum TelemetrySpanKind: String, Sendable {
    case internalSpan = "internal"
    case client
    case server
    case producer
    case consumer
}

public enum TelemetrySpanStatus: Equatable, Sendable {
    case unset
    case ok
    case error(String)
}

public enum TelemetryMetricKind: String, Sendable {
    case counter
    case upDownCounter
    case gauge
    case histogram
}

public struct TelemetryConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var serviceName: String
    public var exporter: String
    public var protocolName: String
    public var endpoint: String?
    public var tracesEndpoint: String?
    public var logsEndpoint: String?
    public var metricsEndpoint: String?
    public var headers: [String: String]
    public var compression: String
    public var timeoutSeconds: Double
    public var batch: [String: Int]
    public var capturePrint: String
    public var captureLogger: Bool
    public var traces: Bool
    public var logs: Bool
    public var metrics: Bool
    public var callbackSampleRates: [String: Double]
    public var attributeLimits: [String: Int]
    public var resourceAttributes: [String: String]
    public var propagators: [String]

    public init(
        enabled: Bool = false,
        serviceName: String = "cosmichammer",
        exporter: String = "console",
        protocolName: String = "http/protobuf",
        endpoint: String? = nil,
        tracesEndpoint: String? = nil,
        logsEndpoint: String? = nil,
        metricsEndpoint: String? = nil,
        headers: [String: String] = [:],
        compression: String = "gzip",
        timeoutSeconds: Double = 5,
        batch: [String: Int] = [:],
        capturePrint: String = "off",
        captureLogger: Bool = true,
        traces: Bool = true,
        logs: Bool = true,
        metrics: Bool = true,
        callbackSampleRates: [String: Double] = [:],
        attributeLimits: [String: Int] = [
            "maxCount": 64,
            "maxValueLength": 4096,
        ],
        resourceAttributes: [String: String] = [:],
        propagators: [String] = ["tracecontext", "baggage"]
    ) {
        self.enabled = enabled
        self.serviceName = serviceName
        self.exporter = exporter
        self.protocolName = protocolName
        self.endpoint = endpoint
        self.tracesEndpoint = tracesEndpoint
        self.logsEndpoint = logsEndpoint
        self.metricsEndpoint = metricsEndpoint
        self.headers = headers
        self.compression = compression
        self.timeoutSeconds = timeoutSeconds
        self.batch = batch
        self.capturePrint = capturePrint
        self.captureLogger = captureLogger
        self.traces = traces
        self.logs = logs
        self.metrics = metrics
        self.callbackSampleRates = callbackSampleRates
        self.attributeLimits = attributeLimits
        self.resourceAttributes = resourceAttributes
        self.propagators = propagators
    }
}

public struct TelemetryStatusSnapshot: Equatable, Sendable {
    public var enabled: Bool
    public var serviceName: String
    public var exporter: String
    public var protocolName: String
    public var compression: String
    public var capturePrint: String
    public var captureLogger: Bool
    public var activeSpanID: UInt64?
    public var startedSpans: Int
    public var endedSpans: Int
    public var logRecords: Int
    public var metricRecords: Int
    public var droppedRecords: Int
    public var droppedAttributes: Int
    public var flushCount: Int
    public var lastFlushDuration: Double?
    public var lastFlushResult: String?
    public var shutdownCount: Int
    public var lastShutdownDuration: Double?
    public var lastShutdownResult: String?
    public var lastExportError: String?
    public var lastExporterFailureKind: String?
    public var exporterFailureCount: Int
    public var flushFailureCount: Int
    public var shutdownFailureCount: Int
    public var backpressureDroppedRecords: Int
    public var exporterQueueDepth: Int?
    public var exporterQueueCapacity: Int?
    public var exporterMaxExportBatchSize: Int?
    public var exporterScheduleDelay: Double?
    public var exporterTimeout: Double?
    public var lastExportDuration: Double?

    public init(
        enabled: Bool = false,
        serviceName: String = "cosmichammer",
        exporter: String = "console",
        protocolName: String = "http/protobuf",
        compression: String = "gzip",
        capturePrint: String = "off",
        captureLogger: Bool = true,
        activeSpanID: UInt64? = nil,
        startedSpans: Int = 0,
        endedSpans: Int = 0,
        logRecords: Int = 0,
        metricRecords: Int = 0,
        droppedRecords: Int = 0,
        droppedAttributes: Int = 0,
        flushCount: Int = 0,
        lastFlushDuration: Double? = nil,
        lastFlushResult: String? = nil,
        shutdownCount: Int = 0,
        lastShutdownDuration: Double? = nil,
        lastShutdownResult: String? = nil,
        lastExportError: String? = nil,
        lastExporterFailureKind: String? = nil,
        exporterFailureCount: Int = 0,
        flushFailureCount: Int = 0,
        shutdownFailureCount: Int = 0,
        backpressureDroppedRecords: Int = 0,
        exporterQueueDepth: Int? = nil,
        exporterQueueCapacity: Int? = nil,
        exporterMaxExportBatchSize: Int? = nil,
        exporterScheduleDelay: Double? = nil,
        exporterTimeout: Double? = nil,
        lastExportDuration: Double? = nil
    ) {
        self.enabled = enabled
        self.serviceName = serviceName
        self.exporter = exporter
        self.protocolName = protocolName
        self.compression = compression
        self.capturePrint = capturePrint
        self.captureLogger = captureLogger
        self.activeSpanID = activeSpanID
        self.startedSpans = startedSpans
        self.endedSpans = endedSpans
        self.logRecords = logRecords
        self.metricRecords = metricRecords
        self.droppedRecords = droppedRecords
        self.droppedAttributes = droppedAttributes
        self.flushCount = flushCount
        self.lastFlushDuration = lastFlushDuration
        self.lastFlushResult = lastFlushResult
        self.shutdownCount = shutdownCount
        self.lastShutdownDuration = lastShutdownDuration
        self.lastShutdownResult = lastShutdownResult
        self.lastExportError = lastExportError
        self.lastExporterFailureKind = lastExporterFailureKind
        self.exporterFailureCount = exporterFailureCount
        self.flushFailureCount = flushFailureCount
        self.shutdownFailureCount = shutdownFailureCount
        self.backpressureDroppedRecords = backpressureDroppedRecords
        self.exporterQueueDepth = exporterQueueDepth
        self.exporterQueueCapacity = exporterQueueCapacity
        self.exporterMaxExportBatchSize = exporterMaxExportBatchSize
        self.exporterScheduleDelay = exporterScheduleDelay
        self.exporterTimeout = exporterTimeout
        self.lastExportDuration = lastExportDuration
    }
}

public protocol TelemetryProtocol: AnyObject {
    var configuration: TelemetryConfiguration { get }
    var isEnabled: Bool { get }

    func configure(_ configuration: TelemetryConfiguration)
    func status() -> TelemetryStatusSnapshot
    func startSpan(name: String, kind: TelemetrySpanKind, attributes: [String: Any], startTime: TimeInterval?) -> UInt64?
    func setSpanAttributes(spanID: UInt64?, attributes: [String: Any])
    func setSpanStatus(spanID: UInt64?, status: TelemetrySpanStatus)
    func endSpan(id: UInt64, status: TelemetrySpanStatus?, attributes: [String: Any], endTime: TimeInterval?)
    func addEvent(spanID: UInt64?, name: String, attributes: [String: Any], timestamp: TimeInterval?)
    func recordException(spanID: UInt64?, message: String, stack: String?, attributes: [String: Any])
    func recordLog(level: String, message: String, attributes: [String: Any], timestamp: TimeInterval?)
    func recordMetric(name: String, kind: TelemetryMetricKind, value: Double, attributes: [String: Any], unit: String?)
    func inject(into carrier: [String: String]) -> [String: String]
    func extract(from carrier: [String: String])
    func flush(timeout: TimeInterval) -> Bool
    func shutdown(timeout: TimeInterval) -> Bool
}
