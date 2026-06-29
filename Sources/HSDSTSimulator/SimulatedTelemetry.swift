import Foundation
import HSDSTCore

public struct SimulatedSpanRecord: Equatable {
    public var id: UInt64
    public var name: String
    public var kind: TelemetrySpanKind
    public var attributes: [String: String]
    public var status: TelemetrySpanStatus
    public var ended: Bool
    public var parentSpanID: UInt64?
}

public struct SimulatedLogRecord: Equatable {
    public var level: String
    public var message: String
    public var attributes: [String: String]
}

public struct SimulatedMetricRecord: Equatable {
    public var name: String
    public var kind: TelemetryMetricKind
    public var value: Double
    public var attributes: [String: String]
    public var unit: String?
}

public final class SimulatedTelemetry: TelemetryProtocol {
    public private(set) var configuration = TelemetryConfiguration()
    public private(set) var spans: [SimulatedSpanRecord] = []
    public private(set) var logs: [SimulatedLogRecord] = []
    public private(set) var metrics: [SimulatedMetricRecord] = []
    public private(set) var events: [(spanID: UInt64?, name: String, attributes: [String: String])] = []
    public private(set) var exceptions: [(spanID: UInt64?, message: String, stack: String?)] = []
    public private(set) var flushCount = 0
    public private(set) var shutdownCount = 0
    public private(set) var lastFlushDuration: Double?
    public private(set) var lastShutdownDuration: Double?

    private var rng: RPRNG
    private let faults: FaultConfig
    private var nextSpanID: UInt64 = 1
    private var activeSpanID: UInt64?
    private var activeSpanStack: [UInt64] = []
    private var activeRemoteParentID: UInt64?
    private var droppedRecords = 0
    private var droppedAttributes = 0
    private var lastExportError: String?
    private var lastFlushResult: String?
    private var lastShutdownResult: String?
    private var lastExporterFailureKind: String?
    private var exporterFailureCount = 0
    private var flushFailureCount = 0
    private var shutdownFailureCount = 0
    private var backpressureDroppedRecords = 0
    private var queuedExportRecords = 0
    private var recordingDiagnostics = false

    public init(rng: RPRNG = RPRNG(seed: 0), faults: FaultConfig = FaultConfig()) {
        self.rng = rng
        self.faults = faults
    }

    public var isEnabled: Bool { configuration.enabled }

    public func configure(_ configuration: TelemetryConfiguration) {
        self.configuration = configuration
        lastExportError = nil
        lastExporterFailureKind = nil
        lastFlushDuration = nil
        lastFlushResult = nil
        lastShutdownDuration = nil
        lastShutdownResult = nil
        if configuration.enabled,
           configuration.exporter == "otlp",
           !configuration.otlpProtocolIsSupported
        {
            recordExporterFailure(
                kind: "unsupported_protocol",
                message: "Unsupported OTLP protocol '\(configuration.protocolName)'; supported protocols are http/protobuf and grpc"
            )
        } else if configuration.enabled,
                  let invalidEndpointMessage = invalidOTLPEndpointMessage(configuration)
        {
            recordExporterFailure(kind: "invalid_endpoint", message: invalidEndpointMessage)
        }
        activeSpanID = nil
        activeSpanStack.removeAll()
        activeRemoteParentID = nil
        queuedExportRecords = 0
    }

    public func status() -> TelemetryStatusSnapshot {
        TelemetryStatusSnapshot(
            enabled: configuration.enabled,
            serviceName: configuration.serviceName,
            exporter: configuration.exporter,
            protocolName: configuration.protocolName,
            compression: configuration.compression,
            capturePrint: configuration.capturePrint,
            captureLogger: configuration.captureLogger,
            activeSpanID: activeSpanID,
            startedSpans: spans.count,
            endedSpans: spans.filter(\.ended).count,
            logRecords: logs.count,
            metricRecords: metrics.count,
            droppedRecords: droppedRecords,
            droppedAttributes: droppedAttributes,
            flushCount: flushCount,
            lastFlushDuration: lastFlushDuration,
            lastFlushResult: lastFlushResult,
            shutdownCount: shutdownCount,
            lastShutdownDuration: lastShutdownDuration,
            lastShutdownResult: lastShutdownResult,
            lastExportError: lastExportError,
            lastExporterFailureKind: lastExporterFailureKind,
            exporterFailureCount: exporterFailureCount,
            flushFailureCount: flushFailureCount,
            shutdownFailureCount: shutdownFailureCount,
            backpressureDroppedRecords: backpressureDroppedRecords,
            exporterQueueDepth: nil,
            exporterQueueCapacity: effectiveQueueCapacity(),
            exporterMaxExportBatchSize: configuration.batch["maxExportBatchSize"],
            exporterScheduleDelay: configuration.batch["scheduleDelay"].map { Double($0) },
            exporterTimeout: configuration.timeoutSeconds,
            lastExportDuration: lastFlushDuration
        )
    }

    public func startSpan(name: String, kind: TelemetrySpanKind, attributes: [String: Any], startTime: TimeInterval?) -> UInt64? {
        guard configuration.enabled, configuration.traces else { return nil }
        let parentSpanID = activeRemoteParentID ?? activeSpanID
        let id = nextSpanID
        nextSpanID += 1
        activeSpanID = id
        activeSpanStack.append(id)
        activeRemoteParentID = nil
        spans.append(SimulatedSpanRecord(
            id: id,
            name: name,
            kind: kind,
            attributes: stringify(attributes),
            status: .unset,
            ended: false,
            parentSpanID: parentSpanID
        ))
        return id
    }

    public func setSpanAttributes(spanID: UInt64?, attributes: [String: Any]) {
        guard configuration.enabled, configuration.traces else { return }
        guard let id = spanID ?? activeSpanID,
              let index = spans.firstIndex(where: { $0.id == id && !$0.ended })
        else {
            droppedRecords += 1
            return
        }
        spans[index].attributes.merge(stringify(attributes)) { _, new in new }
    }

    public func setSpanStatus(spanID: UInt64?, status: TelemetrySpanStatus) {
        guard configuration.enabled, configuration.traces else { return }
        guard let id = spanID ?? activeSpanID,
              let index = spans.firstIndex(where: { $0.id == id && !$0.ended })
        else {
            droppedRecords += 1
            return
        }
        spans[index].status = status
    }

    public func endSpan(id: UInt64, status: TelemetrySpanStatus?, attributes: [String: Any], endTime: TimeInterval?) {
        guard configuration.enabled, configuration.traces else { return }
        if let index = spans.firstIndex(where: { $0.id == id }) {
            guard !spans[index].ended else {
                droppedRecords += 1
                return
            }
            if let status {
                spans[index].status = status
            }
            spans[index].ended = true
            spans[index].attributes.merge(stringify(attributes)) { _, new in new }
        } else {
            droppedRecords += 1
        }
        activeSpanStack.removeAll { $0 == id }
        activeSpanID = activeSpanStack.last
    }

    public func addEvent(spanID: UInt64?, name: String, attributes: [String: Any], timestamp: TimeInterval?) {
        guard configuration.enabled, configuration.traces else { return }
        guard let id = spanID ?? activeSpanID,
              spans.contains(where: { $0.id == id && !$0.ended })
        else {
            droppedRecords += 1
            return
        }
        events.append((id, name, stringify(attributes)))
    }

    public func recordException(spanID: UInt64?, message: String, stack: String?, attributes: [String: Any]) {
        guard configuration.enabled, configuration.traces else { return }
        guard let id = spanID ?? activeSpanID,
              let index = spans.firstIndex(where: { $0.id == id && !$0.ended })
        else {
            droppedRecords += 1
            return
        }
        // Mirrors ProductionTelemetry: recording an exception marks the span
        // errored (a deliberate convenience deviation from the strict OTEL spec).
        spans[index].status = .error(message)
        exceptions.append((id, message, stack))
    }

    public func recordLog(level: String, message: String, attributes: [String: Any], timestamp: TimeInterval?) {
        guard configuration.enabled, configuration.logs else { return }
        guard acceptExportRecord() else { return }
        logs.append(SimulatedLogRecord(level: level, message: message, attributes: stringify(attributes)))
    }

    public func recordMetric(name: String, kind: TelemetryMetricKind, value: Double, attributes: [String: Any], unit: String?) {
        guard configuration.enabled, configuration.metrics else { return }
        guard acceptExportRecord() else { return }
        let recordedValue: Double
        switch kind {
        case .counter:
            recordedValue = Double(max(0, Int(value.rounded())))
        case .upDownCounter:
            recordedValue = Double(Int(value.rounded()))
        case .gauge:
            recordedValue = value
        case .histogram:
            recordedValue = max(0, value)
        }
        metrics.append(SimulatedMetricRecord(
            name: name,
            kind: kind,
            value: recordedValue,
            attributes: stringify(attributes),
            unit: unit
        ))
    }

    public func inject(into carrier: [String: String]) -> [String: String] {
        guard configuration.enabled, configuration.propagationEnabled("tracecontext"), let activeSpanID else { return carrier }
        var updated = carrier
        updated["traceparent"] = "00-00000000000000000000000000000001-\(String(format: "%016llx", activeSpanID))-01"
        return updated
    }

    public func extract(from carrier: [String: String]) {
        guard configuration.enabled, configuration.propagationEnabled("tracecontext") else { return }
        activeRemoteParentID = nil
        guard let traceparent = carrier.first(where: { $0.key.lowercased() == "traceparent" })?.value else {
            return
        }
        guard let parentID = parseTraceparentParentID(traceparent) else {
            return
        }
        activeRemoteParentID = parentID
    }

    public func flush(timeout: TimeInterval) -> Bool {
        guard configuration.enabled else { return true }
        let start = Date()
        flushCount += 1
        let failure = simulatedFlushFailure()
        let succeeded = failure == nil
        let duration = Date().timeIntervalSince(start)
        lastFlushDuration = duration
        lastFlushResult = succeeded ? "success" : "failure"
        if let failure {
            flushFailureCount += 1
            recordExporterFailure(kind: failure.kind, message: failure.message)
        } else {
            queuedExportRecords = 0
            lastExportError = nil
            lastExporterFailureKind = nil
        }
        recordingDiagnostics = true
        recordRuntimeDiagnostics(flushDuration: duration, flushSucceeded: succeeded)
        recordingDiagnostics = false
        return succeeded
    }

    public func shutdown(timeout: TimeInterval) -> Bool {
        let start = Date()
        shutdownCount += 1
        activeSpanID = nil
        activeSpanStack.removeAll()
        activeRemoteParentID = nil
        let flushed = flush(timeout: timeout)
        let shutdownFailed = rng.boolean(probability: faults.telemetryShutdownFailProbability)
        let succeeded = flushed && !shutdownFailed
        lastShutdownDuration = Date().timeIntervalSince(start)
        lastShutdownResult = succeeded ? "success" : "failure"
        if shutdownFailed {
            shutdownFailureCount += 1
            recordExporterFailure(kind: "shutdown_failed", message: "Telemetry shutdown failed (simulated)")
        } else if !flushed {
            shutdownFailureCount += 1
        }
        return succeeded
    }

    private func acceptExportRecord() -> Bool {
        guard !recordingDiagnostics else { return true }
        guard let capacity = effectiveQueueCapacity() else {
            queuedExportRecords += 1
            return true
        }
        guard queuedExportRecords < capacity else {
            droppedRecords += 1
            backpressureDroppedRecords += 1
            return false
        }
        queuedExportRecords += 1
        return true
    }

    private func effectiveQueueCapacity() -> Int? {
        if let capacity = faults.telemetryQueueCapacity {
            return max(0, capacity)
        }
        if let capacity = configuration.batch["maxQueueSize"] {
            return max(0, capacity)
        }
        return nil
    }

    private func recordExporterFailure(kind: String, message: String) {
        lastExporterFailureKind = kind
        lastExportError = message
        exporterFailureCount += 1
    }

    private func simulatedFlushFailure() -> (kind: String, message: String)? {
        if let invalidEndpointMessage = invalidOTLPEndpointMessage(configuration) {
            return ("invalid_endpoint", invalidEndpointMessage)
        }
        if faults.telemetryCollectorUnavailable {
            return ("collector_unavailable", "Telemetry collector unavailable (simulated)")
        }
        if rng.boolean(probability: faults.telemetryExportTimeoutProbability) {
            return ("timeout", "Telemetry export timed out (simulated)")
        }
        if rng.boolean(probability: faults.telemetryFlushFailProbability) {
            return ("flush_failed", "Telemetry flush failed (simulated)")
        }
        return nil
    }

    private func stringify(_ attributes: [String: Any]) -> [String: String] {
        let limited = configuration.limitedAttributes(attributes)
        // Attribute-level drops are tracked separately from record-level drops
        // so the dropped-records gauge is not inflated by attribute limiting.
        droppedAttributes += limited.totalDropped
        var result: [String: String] = [:]
        for (key, value) in limited.pairs {
            result[key] = String(describing: value)
        }
        return result
    }

    private func recordRuntimeDiagnostics(flushDuration: Double, flushSucceeded: Bool) {
        let activeSpanCount = activeSpanStack.count
        let droppedRecordCount = droppedRecords
        let droppedAttributeCount = droppedAttributes
        let result = flushSucceeded ? "success" : "failure"
        recordMetric(
            name: "cosmichammer.telemetry.flush.duration",
            kind: .histogram,
            value: flushDuration,
            attributes: ["cosmichammer.telemetry.flush.result": result],
            unit: "s"
        )
        recordMetric(
            name: "cosmichammer.telemetry.flush.count",
            kind: .counter,
            value: 1,
            attributes: ["cosmichammer.telemetry.flush.result": result],
            unit: "1"
        )
        recordMetric(
            name: "cosmichammer.telemetry.spans.active",
            kind: .gauge,
            value: Double(activeSpanCount),
            attributes: [:],
            unit: "1"
        )
        recordMetric(
            name: "cosmichammer.telemetry.records.dropped",
            kind: .gauge,
            value: Double(droppedRecordCount),
            attributes: [:],
            unit: "1"
        )
        recordMetric(
            name: "cosmichammer.telemetry.attributes.dropped",
            kind: .gauge,
            value: Double(droppedAttributeCount),
            attributes: [:],
            unit: "1"
        )
        if let queueCapacity = effectiveQueueCapacity() {
            recordMetric(
                name: "cosmichammer.telemetry.exporter.queue.capacity",
                kind: .gauge,
                value: Double(queueCapacity),
                attributes: [:],
                unit: "1"
            )
        }
        if let maxBatchSize = configuration.batch["maxExportBatchSize"] {
            recordMetric(
                name: "cosmichammer.telemetry.exporter.batch.max_size",
                kind: .gauge,
                value: Double(maxBatchSize),
                attributes: [:],
                unit: "1"
            )
        }
        if let scheduleDelay = configuration.batch["scheduleDelay"] {
            recordMetric(
                name: "cosmichammer.telemetry.exporter.schedule.delay",
                kind: .gauge,
                value: Double(scheduleDelay),
                attributes: [:],
                unit: "s"
            )
        }
        recordMetric(
            name: "cosmichammer.telemetry.exporter.timeout",
            kind: .gauge,
            value: configuration.timeoutSeconds,
            attributes: [:],
            unit: "s"
        )
        recordMetric(
            name: "cosmichammer.telemetry.exporter.backpressure.dropped_records",
            kind: .gauge,
            value: Double(backpressureDroppedRecords),
            attributes: [:],
            unit: "1"
        )
        recordMetric(
            name: "cosmichammer.telemetry.exporter.failure.count",
            kind: .gauge,
            value: Double(exporterFailureCount),
            attributes: [:],
            unit: "1"
        )
    }

    /// Deterministic endpoint validation with the simulator's fault injection
    /// layered on top of the shared `TelemetryConfiguration` diagnostic.
    private func invalidOTLPEndpointMessage(_ configuration: TelemetryConfiguration) -> String? {
        if faults.telemetryMalformedEndpoint,
           configuration.exporter == "otlp",
           configuration.otlpProtocolIsSupported
        {
            return "Invalid OTLP endpoint (simulated)"
        }
        return configuration.invalidOTLPEndpointMessage
    }

    private func parseTraceparentParentID(_ traceparent: String) -> UInt64? {
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "00",
              isValidHexField(parts[1], length: 32, allowAllZeros: false),
              isValidHexField(parts[2], length: 16, allowAllZeros: false),
              isValidHexField(parts[3], length: 2, allowAllZeros: true)
        else {
            return nil
        }
        return UInt64(parts[2], radix: 16)
    }

    private func isValidHexField(_ value: Substring, length: Int, allowAllZeros: Bool) -> Bool {
        guard value.count == length else { return false }
        var sawNonZero = false
        for byte in value.utf8 {
            let isHex = (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            guard isHex else { return false }
            if byte != 48 {
                sawNonZero = true
            }
        }
        return allowAllZeros || sawNonZero
    }
}
