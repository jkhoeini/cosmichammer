import Foundation
import GRPC
import HSDSTCore
import NIO
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import StdoutExporter
import SwiftProtobuf
import os.log

/// SDK-backed telemetry implementation.
///
/// Context model: active-span parenting is a single `activeRemoteParent` plus a
/// hand-managed `activeSpanStack`, not a per-execution context stack. This is
/// intentional and correct for Cosmic Hammer's effectively single-threaded Lua
/// runtime, where spans open and close in LIFO order on one thread. An
/// `extract()`ed remote context is consumed by the next `startSpan` and takes
/// precedence as its parent (the incoming-request pattern). The recursive lock
/// guards state mutation, but it does not make span parenting safe under truly
/// concurrent span creation from multiple threads.
final class ProductionTelemetry: TelemetryProtocol {
    private let lock = NSRecursiveLock()
    private var currentConfiguration = TelemetryConfiguration()
    private var nextSpanID: UInt64 = 1
    private var activeSpanID: UInt64?
    private var activeSpanStack: [UInt64] = []
    private var activeRemoteParent: SpanContext?
    private var startedSpans = 0
    private var endedSpans = 0
    private var logRecords = 0
    private var metricRecords = 0
    private var droppedRecords = 0
    private var droppedAttributes = 0
    private var flushCount = 0
    private var lastFlushDuration: Double?
    private var lastFlushResult: String?
    private var shutdownCount = 0
    private var lastShutdownDuration: Double?
    private var lastShutdownResult: String?
    private var lastExportError: String?
    private var lastExporterFailureKind: String?
    private var exporterFailureCount = 0
    private var flushFailureCount = 0
    private var shutdownFailureCount = 0
    private var backpressureDroppedRecords = 0
    private var tracerProvider: TracerProviderSdk?
    private var loggerProvider: LoggerProviderSdk?
    private var meterProvider: MeterProviderSdk?
    private var logProcessor: BatchLogRecordProcessor?
    // One EventLoopGroup is shared across the trace/log/metric gRPC channels
    // instead of spinning up a group per signal; torn down once on reconfigure
    // or shutdown alongside the channels it backs.
    private var grpcEventLoopGroup: MultiThreadedEventLoopGroup?
    private var grpcTransports: [OTLPGRPCTransport] = []
    private var tracer: Tracer?
    private var logger: OpenTelemetryApi.Logger?
    private var meter: MeterSdk?
    private var spans: [UInt64: Span] = [:]
    private var counters: [String: LongCounterSdk] = [:]
    private var upDownCounters: [String: LongUpDownCounterSdk] = [:]
    private var gauges: [String: DoubleGaugeSdk] = [:]
    private var histograms: [String: DoubleHistogramMeterSdk] = [:]
    private let propagator = W3CTraceContextPropagator()

    var configuration: TelemetryConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return currentConfiguration
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentConfiguration.enabled
    }

    func configure(_ configuration: TelemetryConfiguration) {
        let (pipeline, previousTimeout, shouldFlushMetrics) = detachPipelineWithShutdownSettings()
        shutdownPipeline(pipeline, timeout: previousTimeout, forceFlushMetrics: shouldFlushMetrics)

        lock.lock()
        defer { lock.unlock() }
        currentConfiguration = configuration
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
                  let invalidEndpointMessage = configuration.invalidOTLPEndpointMessage
        {
            recordExporterFailure(kind: "invalid_endpoint", message: invalidEndpointMessage)
        }
        activeSpanID = nil
        activeSpanStack.removeAll()
        activeRemoteParent = nil
        clearTrackedSpans()
        counters.removeAll()
        upDownCounters.removeAll()
        gauges.removeAll()
        histograms.removeAll()

        if configuration.enabled, configurationDiagnosticFailureKind(configuration) == nil {
            installPipeline(configuration)
            os_log(.info, "OpenTelemetry configured with exporter %{public}s", configuration.exporter)
        }
    }

    func status() -> TelemetryStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TelemetryStatusSnapshot(
            enabled: currentConfiguration.enabled,
            serviceName: currentConfiguration.serviceName,
            exporter: currentConfiguration.exporter,
            protocolName: currentConfiguration.protocolName,
            compression: currentConfiguration.compression,
            capturePrint: currentConfiguration.capturePrint,
            captureLogger: currentConfiguration.captureLogger,
            activeSpanID: activeSpanID,
            startedSpans: startedSpans,
            endedSpans: endedSpans,
            logRecords: logRecords,
            metricRecords: metricRecords,
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
            exporterQueueCapacity: configuredMaxQueueSize(currentConfiguration),
            exporterMaxExportBatchSize: configuredMaxExportBatchSize(currentConfiguration),
            exporterScheduleDelay: configuredScheduleDelay(currentConfiguration),
            exporterTimeout: currentConfiguration.timeoutSeconds,
            lastExportDuration: lastFlushDuration
        )
    }

    func startSpan(name: String, kind: TelemetrySpanKind, attributes: [String: Any], startTime: TimeInterval?) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.traces else { return nil }
        guard let tracer else {
            droppedRecords += 1
            return nil
        }

        let builder = tracer.spanBuilder(spanName: name)
            .setSpanKind(spanKind: spanKind(kind))
            .setActive(true)
        for (key, value) in attributeValues(attributes) {
            _ = builder.setAttribute(key: key, value: value)
        }
        if let startTime {
            _ = builder.setStartTime(time: Date(timeIntervalSince1970: startTime))
        }
        if let activeRemoteParent {
            _ = builder.setParent(activeRemoteParent)
            self.activeRemoteParent = nil
        }

        let span = builder.startSpan()
        let id = nextSpanID
        nextSpanID += 1
        activeSpanID = id
        activeSpanStack.append(id)
        spans[id] = span
        startedSpans += 1
        emitConsoleLine("SPAN \(name) [\(id)] \(kind.rawValue)")
        return id
    }

    func setSpanAttributes(spanID: UInt64?, attributes: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.traces else { return }
        let id = spanID ?? activeSpanID
        guard let id, let span = spans[id] else {
            droppedRecords += 1
            return
        }
        span.setAttributes(attributeValues(attributes))
    }

    func setSpanStatus(spanID: UInt64?, status: TelemetrySpanStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.traces else { return }
        let id = spanID ?? activeSpanID
        guard let id, let span = spans[id] else {
            droppedRecords += 1
            return
        }
        span.status = spanStatus(status)
    }

    func endSpan(id: UInt64, status: TelemetrySpanStatus?, attributes: [String: Any], endTime: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.traces else { return }
        guard let span = spans.removeValue(forKey: id) else {
            droppedRecords += 1
            return
        }
        span.setAttributes(attributeValues(attributes))
        if let status {
            span.status = spanStatus(status)
        }
        if let endTime {
            span.end(time: Date(timeIntervalSince1970: endTime))
        } else {
            span.end()
        }
        OpenTelemetry.instance.contextProvider.removeContextForSpan(span)
        endedSpans += 1
        activeSpanStack.removeAll { $0 == id }
        activeSpanID = activeSpanStack.last
        if case .some(.error(let message)) = status {
            emitConsoleLine("SPAN_ERROR [\(id)] \(message)")
        }
    }

    func addEvent(spanID: UInt64?, name: String, attributes: [String: Any], timestamp: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.traces else { return }
        let id = spanID ?? activeSpanID
        guard let id, let span = spans[id] else {
            droppedRecords += 1
            return
        }
        let converted = attributeValues(attributes)
        if let timestamp {
            span.addEvent(name: name, attributes: converted, timestamp: Date(timeIntervalSince1970: timestamp))
        } else {
            span.addEvent(name: name, attributes: converted)
        }
        emitConsoleLine("EVENT \(name) [\(id)]")
    }

    func recordException(spanID: UInt64?, message: String, stack: String?, attributes: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.traces else { return }
        let id = spanID ?? activeSpanID
        var eventAttributes = attributes
        eventAttributes["exception.message"] = message
        if let stack {
            eventAttributes["exception.stacktrace"] = stack
        }
        if let id, let span = spans[id] {
            span.addEvent(name: "exception", attributes: attributeValues(eventAttributes))
            // Deliberate convenience deviation from the strict OTEL spec (which
            // treats recording an exception and setting status as independent):
            // Cosmic Hammer marks the span errored when an exception is recorded.
            // Covered by `recordExceptionMarksActiveSpanError`.
            span.status = .error(description: message)
        } else {
            droppedRecords += 1
        }
        emitConsoleLine("EXCEPTION\(id.map { " [\($0)]" } ?? "") \(message)")
    }

    func recordLog(level: String, message: String, attributes: [String: Any], timestamp: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.logs else { return }
        guard let logger else {
            droppedRecords += 1
            return
        }
        let builder = logger.logRecordBuilder()
            .setSeverity(severity(level))
            .setBody(.string(message))
            .setAttributes(attributeValues(attributes))
        if let timestamp {
            _ = builder.setTimestamp(Date(timeIntervalSince1970: timestamp))
        }
        if let activeSpanID, let span = spans[activeSpanID] {
            _ = builder.setSpanContext(span.context)
        }
        builder.emit()
        logRecords += 1
        emitConsoleLine("LOG [\(level.uppercased())] \(message)")
    }

    func recordMetric(name: String, kind: TelemetryMetricKind, value: Double, attributes: [String: Any], unit: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.metrics else { return }
        guard let meter else {
            droppedRecords += 1
            return
        }
        let converted = attributeValues(attributes)
        switch kind {
        case .counter:
            let counter = counters[name] ?? meter.counterBuilder(name: name).setUnit(unit ?? "1").build()
            counters[name] = counter
            counter.add(value: max(0, Int(value.rounded())), attributes: converted)
        case .upDownCounter:
            let counter = upDownCounters[name] ?? meter.upDownCounterBuilder(name: name).setUnit(unit ?? "1").build()
            upDownCounters[name] = counter
            counter.add(value: Int(value.rounded()), attributes: converted)
        case .gauge:
            let gauge = gauges[name] ?? meter.gaugeBuilder(name: name).setUnit(unit ?? "1").build()
            gauges[name] = gauge
            gauge.record(value: value, attributes: converted)
        case .histogram:
            let histogram = histograms[name] ?? meter.histogramBuilder(name: name).setUnit(unit ?? "1").build()
            histograms[name] = histogram
            histogram.record(value: max(0, value), attributes: converted)
        }
        metricRecords += 1
        emitConsoleLine("METRIC \(kind.rawValue) \(name)=\(value)\(unit.map { " \($0)" } ?? "")")
    }

    func inject(into carrier: [String: String]) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled,
              currentConfiguration.propagationEnabled("tracecontext"),
              let activeSpanID,
              let span = spans[activeSpanID]
        else { return carrier }
        var updated = carrier
        propagator.inject(spanContext: span.context, carrier: &updated, setter: DictionarySetter())
        return updated
    }

    func extract(from carrier: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        guard currentConfiguration.enabled, currentConfiguration.propagationEnabled("tracecontext") else { return }
        activeRemoteParent = propagator.extract(carrier: carrier, getter: DictionaryGetter())
    }

    func flush(timeout: TimeInterval) -> Bool {
        lock.lock()
        guard currentConfiguration.enabled else {
            lock.unlock()
            return true
        }
        let configuration = currentConfiguration
        let tracerProvider = self.tracerProvider
        let meterProvider = self.meterProvider
        let logProcessor = self.logProcessor
        let shouldFlushMetrics = metricRecords > 0
        lock.unlock()

        let start = Date()
        tracerProvider?.forceFlush(timeout: timeout)
        let metricResult = shouldFlushMetrics ? meterProvider?.forceFlush() : .success
        let logResult = logProcessor?.forceFlush(explicitTimeout: timeout)
        let duration = Date().timeIntervalSince(start)

        lock.lock()
        defer { lock.unlock() }
        flushCount += 1
        let succeeded = metricResult != .failure && logResult != .failure
        lastFlushDuration = duration
        lastFlushResult = succeeded ? "success" : "failure"
        if succeeded {
            if configurationDiagnosticFailureKind(configuration) == nil {
                lastExportError = nil
                lastExporterFailureKind = nil
            }
        } else {
            flushFailureCount += 1
            recordExporterFailure(kind: "flush_failed", message: "Telemetry flush failed")
        }
        recordRuntimeDiagnostics(flushDuration: duration, flushSucceeded: succeeded)
        emitConsoleLine("FLUSH timeout=\(timeout)")
        return succeeded
    }

    func shutdown(timeout: TimeInterval) -> Bool {
        lock.lock()
        let start = Date()
        shutdownCount += 1
        let shouldFlushMetricsOnShutdown = metricRecords > 0
        lock.unlock()

        let flushed = flush(timeout: timeout)
        let pipeline = detachPipeline()
        shutdownPipeline(pipeline, timeout: timeout, forceFlushMetrics: shouldFlushMetricsOnShutdown)

        lock.lock()
        defer { lock.unlock() }
        activeSpanID = nil
        activeSpanStack.removeAll()
        activeRemoteParent = nil
        clearTrackedSpans()
        lastShutdownDuration = Date().timeIntervalSince(start)
        lastShutdownResult = flushed ? "success" : "failure"
        if !flushed {
            shutdownFailureCount += 1
        }
        return flushed
    }

    private struct Pipeline {
        var tracerProvider: TracerProviderSdk?
        var loggerProvider: LoggerProviderSdk?
        var meterProvider: MeterProviderSdk?
        var logProcessor: BatchLogRecordProcessor?
        var tracer: Tracer?
        var logger: OpenTelemetryApi.Logger?
        var meter: MeterSdk?
        var grpcTransports: [OTLPGRPCTransport]
        var grpcEventLoopGroup: MultiThreadedEventLoopGroup?
    }

    private func detachPipelineWithShutdownSettings() -> (Pipeline, TimeInterval, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (detachPipelineAssumingLocked(), currentConfiguration.timeoutSeconds, metricRecords > 0)
    }

    private func installPipeline(_ configuration: TelemetryConfiguration) {
        let resource = Resource(attributes: resourceAttributes(configuration))
        let spanExporter = makeSpanExporter(configuration)
        let logExporter = makeLogExporter(configuration)
        let metricExporter = makeMetricExporter(configuration)
        let maxQueueSize = configuration.batch["maxQueueSize"] ?? 2048
        let maxExportBatchSize = configuration.batch["maxExportBatchSize"] ?? 512
        let scheduleDelay = Double(configuration.batch["scheduleDelay"] ?? 5)

        let meterProvider = MeterProviderSdk.builder()
            .setResource(resource: resource)
            .registerView(
                selector: InstrumentSelectorBuilder().build(),
                view: View.builder().build()
            )
            .registerMetricReader(
                reader: PeriodicMetricReaderBuilder(exporter: metricExporter)
                    .setInterval(timeInterval: max(1, scheduleDelay))
                    .build()
            )
            .build()
        let tracerProvider = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: BatchSpanProcessor(
                spanExporter: spanExporter,
                meterProvider: meterProvider,
                scheduleDelay: scheduleDelay,
                exportTimeout: configuration.timeoutSeconds,
                maxQueueSize: maxQueueSize,
                maxExportBatchSize: maxExportBatchSize
            ))
            .build()
        let logProcessor = BatchLogRecordProcessor(
            logRecordExporter: logExporter,
            scheduleDelay: scheduleDelay,
            exportTimeout: configuration.timeoutSeconds,
            maxQueueSize: maxQueueSize,
            maxExportBatchSize: maxExportBatchSize
        )
        let loggerProvider = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build()

        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)
        OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
        OpenTelemetry.registerPropagators(
            textPropagators: [W3CTraceContextPropagator()],
            baggagePropagator: W3CBaggagePropagator()
        )
        OpenTelemetry.registerFeedbackHandler { [weak self] message in
            self?.recordExporterFailure(kind: "exporter_feedback", message: message)
            os_log(.error, "OpenTelemetry feedback: %{public}s", message)
        }

        self.tracerProvider = tracerProvider
        self.loggerProvider = loggerProvider
        self.meterProvider = meterProvider
        self.logProcessor = logProcessor
        tracer = tracerProvider.get(instrumentationName: "cosmichammer.lua")
        logger = loggerProvider.get(instrumentationScopeName: "cosmichammer.lua")
        meter = meterProvider.get(name: "cosmichammer.lua")
    }

    private func detachPipeline() -> Pipeline {
        lock.lock()
        defer { lock.unlock() }
        return detachPipelineAssumingLocked()
    }

    private func detachPipelineAssumingLocked() -> Pipeline {
        let pipeline = Pipeline(
            tracerProvider: tracerProvider,
            loggerProvider: loggerProvider,
            meterProvider: meterProvider,
            logProcessor: logProcessor,
            tracer: tracer,
            logger: logger,
            meter: meter,
            grpcTransports: grpcTransports,
            grpcEventLoopGroup: grpcEventLoopGroup
        )
        tracerProvider = nil
        loggerProvider = nil
        meterProvider = nil
        logProcessor = nil
        tracer = nil
        logger = nil
        meter = nil
        grpcTransports.removeAll()
        grpcEventLoopGroup = nil
        return pipeline
    }

    private func shutdownPipeline(_ pipeline: Pipeline, timeout: TimeInterval, forceFlushMetrics: Bool) {
        pipeline.tracerProvider?.forceFlush(timeout: timeout)
        pipeline.tracerProvider?.shutdown()
        if forceFlushMetrics {
            _ = pipeline.meterProvider?.forceFlush()
        }
        _ = pipeline.meterProvider?.shutdown()
        _ = pipeline.logProcessor?.forceFlush(explicitTimeout: timeout)
        _ = pipeline.logProcessor?.shutdown(explicitTimeout: timeout)
        pipeline.grpcTransports.forEach { $0.shutdown() }
        try? pipeline.grpcEventLoopGroup?.syncShutdownGracefully()
    }

    private func clearTrackedSpans() {
        for span in spans.values {
            OpenTelemetry.instance.contextProvider.removeContextForSpan(span)
        }
        spans.removeAll()
    }

    private func recordRuntimeDiagnostics(flushDuration: Double, flushSucceeded: Bool) {
        let activeSpanCount = spans.count
        let droppedRecordCount = droppedRecords
        let droppedAttributeCount = droppedAttributes
        recordMetric(
            name: TelemetrySemanticConventions.Metric.Telemetry.flushDuration,
            kind: .histogram,
            value: flushDuration,
            attributes: [TelemetrySemanticConventions.Attribute.Telemetry.flushResult: flushSucceeded ? "success" : "failure"],
            unit: "s"
        )
        recordMetric(
            name: TelemetrySemanticConventions.Metric.Telemetry.flushCount,
            kind: .counter,
            value: 1,
            attributes: [TelemetrySemanticConventions.Attribute.Telemetry.flushResult: flushSucceeded ? "success" : "failure"],
            unit: "1"
        )
        recordMetric(
            name: TelemetrySemanticConventions.Metric.Telemetry.activeSpans,
            kind: .gauge,
            value: Double(activeSpanCount),
            attributes: [:],
            unit: "1"
        )
        recordMetric(
            name: TelemetrySemanticConventions.Metric.Telemetry.droppedRecords,
            kind: .gauge,
            value: Double(droppedRecordCount),
            attributes: [:],
            unit: "1"
        )
        recordMetric(
            name: TelemetrySemanticConventions.Metric.Telemetry.droppedAttributes,
            kind: .gauge,
            value: Double(droppedAttributeCount),
            attributes: [:],
            unit: "1"
        )
    }

    private func makeSpanExporter(_ configuration: TelemetryConfiguration) -> SpanExporter {
        if configuration.exporter == "otlp",
           configuration.otlpProtocolIsGRPC,
           let exporter = makeGRPCSpanExporter(configuration)
        {
            return exporter
        }
        if configuration.exporter == "otlp",
           configuration.otlpProtocolIsHTTP,
           let endpoint = endpointURL(configuration, signalPath: "v1/traces")
        {
            return OtlpHttpTraceExporter(
                endpoint: endpoint,
                config: otlpConfiguration(configuration),
                envVarHeaders: nil
            )
        }
        return StdoutSpanExporter(isDebug: true)
    }

    private func makeLogExporter(_ configuration: TelemetryConfiguration) -> LogRecordExporter {
        if configuration.exporter == "otlp",
           configuration.otlpProtocolIsGRPC,
           let exporter = makeGRPCLogExporter(configuration)
        {
            return exporter
        }
        if configuration.exporter == "otlp",
           configuration.otlpProtocolIsHTTP,
           let endpoint = endpointURL(configuration, signalPath: "v1/logs")
        {
            return OtlpHttpLogExporter(
                endpoint: endpoint,
                config: otlpConfiguration(configuration),
                envVarHeaders: nil
            )
        }
        return StdoutLogExporter(isDebug: true)
    }

    private func makeMetricExporter(_ configuration: TelemetryConfiguration) -> MetricExporter {
        if configuration.exporter == "otlp",
           configuration.otlpProtocolIsGRPC,
           let exporter = makeGRPCMetricExporter(configuration)
        {
            return exporter
        }
        if configuration.exporter == "otlp",
           configuration.otlpProtocolIsHTTP,
           let endpoint = endpointURL(configuration, signalPath: "v1/metrics")
        {
            return OtlpHttpMetricExporter(
                endpoint: endpoint,
                config: otlpConfiguration(configuration),
                envVarHeaders: nil
            )
        }
        return StdoutMetricExporter(isDebug: true)
    }

    private func makeGRPCSpanExporter(_ configuration: TelemetryConfiguration) -> SpanExporter? {
        guard let transport = makeGRPCTransport(configuration, signal: .traces) else { return nil }
        return OtlpTraceExporter(
            channel: transport.channel,
            config: otlpConfiguration(configuration),
            envVarHeaders: nil
        )
    }

    private func makeGRPCLogExporter(_ configuration: TelemetryConfiguration) -> LogRecordExporter? {
        guard let transport = makeGRPCTransport(configuration, signal: .logs) else { return nil }
        return OtlpLogExporter(
            channel: transport.channel,
            config: otlpConfiguration(configuration),
            envVarHeaders: nil
        )
    }

    private func makeGRPCMetricExporter(_ configuration: TelemetryConfiguration) -> MetricExporter? {
        guard let transport = makeGRPCTransport(configuration, signal: .metrics) else { return nil }
        return OtlpMetricExporter(
            channel: transport.channel,
            config: otlpConfiguration(configuration),
            envVarHeaders: nil
        )
    }

    private func recordExporterFailure(kind: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        lastExporterFailureKind = kind
        lastExportError = message
        exporterFailureCount += 1
    }

    private func configuredMaxQueueSize(_ configuration: TelemetryConfiguration) -> Int {
        configuration.batch["maxQueueSize"] ?? 2048
    }

    private func configuredMaxExportBatchSize(_ configuration: TelemetryConfiguration) -> Int {
        configuration.batch["maxExportBatchSize"] ?? 512
    }

    private func configuredScheduleDelay(_ configuration: TelemetryConfiguration) -> Double {
        Double(configuration.batch["scheduleDelay"] ?? 5)
    }

    private func configurationDiagnosticFailureKind(_ configuration: TelemetryConfiguration) -> String? {
        if configuration.enabled,
           configuration.exporter == "otlp",
           !configuration.otlpProtocolIsSupported
        {
            return "unsupported_protocol"
        }
        if configuration.enabled, configuration.invalidOTLPEndpointMessage != nil {
            return "invalid_endpoint"
        }
        return nil
    }

    private func makeGRPCTransport(_ configuration: TelemetryConfiguration, signal: OTLPSignal) -> OTLPGRPCTransport? {
        guard let endpoint = grpcEndpoint(configuration, signal: signal) else { return nil }
        let group = grpcEventLoopGroup ?? {
            let created = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            grpcEventLoopGroup = created
            return created
        }()
        let baseChannel: GRPCChannel = endpoint.usesTLS
            ? ClientConnection.usingPlatformAppropriateTLS(for: group).connect(host: endpoint.host, port: endpoint.port)
            : ClientConnection.insecure(group: group).connect(host: endpoint.host, port: endpoint.port)
        let channel: GRPCChannel
        if let messageEncoding = grpcMessageEncoding(configuration) {
            channel = CompressionConfiguredGRPCChannel(base: baseChannel, messageEncoding: messageEncoding)
        } else {
            channel = baseChannel
        }
        let transport = OTLPGRPCTransport(channel: channel, baseChannel: baseChannel)
        grpcTransports.append(transport)
        return transport
    }

    private func grpcEndpoint(_ configuration: TelemetryConfiguration, signal: OTLPSignal) -> OTLPGRPCEndpoint? {
        let configuredEndpoint: String?
        switch signal {
        case .traces:
            configuredEndpoint = configuration.tracesEndpoint ?? configuration.endpoint
        case .logs:
            configuredEndpoint = configuration.logsEndpoint ?? configuration.endpoint
        case .metrics:
            configuredEndpoint = configuration.metricsEndpoint ?? configuration.endpoint
        }
        let endpoint = configuredEndpoint ?? "http://localhost"
        guard TelemetryEndpoint.grpcDiagnostic(endpoint) == nil,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              let host = url.host
        else {
            return nil
        }
        return OTLPGRPCEndpoint(host: host, port: url.port ?? 4317, usesTLS: scheme == "https")
    }

    private func otlpConfiguration(_ configuration: TelemetryConfiguration) -> OtlpConfiguration {
        OtlpConfiguration(
            timeout: configuration.timeoutSeconds,
            compression: otlpCompression(configuration),
            headers: headerTuples(configuration),
            exportAsJson: false
        )
    }

    private func headerTuples(_ configuration: TelemetryConfiguration) -> [(String, String)]? {
        let headers = configuration.headers
            .filter { !$0.key.isEmpty }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
        return headers.isEmpty ? nil : headers
    }

    private func otlpCompression(_ configuration: TelemetryConfiguration) -> CompressionType {
        switch configuration.compression.lowercased() {
        case "none", "identity", "off", "false":
            return .none
        case "deflate":
            return .deflate
        default:
            return .gzip
        }
    }

    private func grpcMessageEncoding(_ configuration: TelemetryConfiguration) -> ClientMessageEncoding? {
        let algorithm: CompressionAlgorithm?
        switch configuration.compression.lowercased() {
        case "none", "identity", "off", "false":
            algorithm = nil
        case "deflate":
            algorithm = .deflate
        default:
            algorithm = .gzip
        }
        guard let algorithm else { return nil }
        return .enabled(.init(
            forRequests: algorithm,
            acceptableForResponses: CompressionAlgorithm.all,
            decompressionLimit: .absolute(.max)
        ))
    }

    private func endpointURL(_ configuration: TelemetryConfiguration, signalPath: String) -> URL? {
        let signalEndpoint: String? = switch signalPath {
        case "v1/traces": configuration.tracesEndpoint
        case "v1/logs": configuration.logsEndpoint
        case "v1/metrics": configuration.metricsEndpoint
        default: nil
        }
        if let signalEndpoint {
            return URL(string: signalEndpoint)
        }
        guard let endpoint = configuration.endpoint else { return nil }
        if endpoint.hasSuffix(signalPath) {
            return URL(string: endpoint)
        }
        return URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + signalPath)
    }

    private func resourceAttributes(_ configuration: TelemetryConfiguration) -> [String: AttributeValue] {
        var attributes = attributeValues(configuration.resourceAttributes)
        attributes["service.name"] = .string(configuration.serviceName)
        attributes["process.runtime.name"] = .string("cosmichammer")
        attributes["process.runtime.version"] = .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        attributes["telemetry.sdk.name"] = .string("cosmichammer-opentelemetry")
        attributes["telemetry.sdk.language"] = .string("swift-lua")
        attributes["cosmichammer.bundle_id"] = .string(Bundle.main.bundleIdentifier ?? "org.cosmic-hammer.CosmicHammer")
        return attributes
    }

    private func attributeValues(_ attributes: [String: Any]) -> [String: AttributeValue] {
        let limited = currentConfiguration.limitedAttributes(attributes)
        // Attribute-level drops (over `maxCount` or truncated for `maxValueLength`)
        // are tracked separately from record-level drops so the dropped-records
        // gauge is not inflated by ordinary attribute limiting.
        droppedAttributes += limited.totalDropped
        var result: [String: AttributeValue] = [:]
        for (key, value) in limited.pairs {
            result[key] = attributeValue(value)
        }
        return result
    }

    private func attributeValue(_ value: Any) -> AttributeValue {
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .int(value) }
        if let value = value as? Int32 { return .int(Int(value)) }
        if let value = value as? Int64 { return .int(Int(value)) }
        if let value = value as? UInt { return .int(Int(value)) }
        if let value = value as? UInt32 { return .int(Int(value)) }
        if let value = value as? UInt64 { return .int(Int(value)) }
        if let value = value as? Double { return .double(value) }
        if let value = value as? Float { return .double(Double(value)) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .double(value.doubleValue)
        }
        return .string(String(describing: value))
    }

    private func spanKind(_ kind: TelemetrySpanKind) -> SpanKind {
        switch kind {
        case .internalSpan: return .internal
        case .client: return .client
        case .server: return .server
        case .producer: return .producer
        case .consumer: return .consumer
        }
    }

    private func spanStatus(_ status: TelemetrySpanStatus) -> OpenTelemetryApi.Status {
        switch status {
        case .unset: return .unset
        case .ok: return .ok
        case .error(let message): return .error(description: message)
        }
    }

    private func severity(_ level: String) -> Severity {
        switch level.lowercased() {
        case "trace", "verbose": return .trace
        case "debug": return .debug
        case "warning", "warn": return .warn
        case "error": return .error
        case "fatal": return .fatal
        default: return .info
        }
    }

    // Console mode intentionally emits twice: the SDK's Stdout*Exporter writes
    // structured records, while these `OTEL:`-prefixed os_log lines give a
    // compact, test-observable trace of individual operations.
    private func emitConsoleLine(_ line: String) {
        guard currentConfiguration.exporter == "console" else { return }
        os_log(.default, "OTEL: %{public}s", line)
    }
}

private enum OTLPSignal {
    case traces
    case logs
    case metrics
}

private struct OTLPGRPCEndpoint {
    var host: String
    var port: Int
    var usesTLS: Bool
}

private final class OTLPGRPCTransport {
    let channel: GRPCChannel
    private let baseChannel: GRPCChannel
    private var isShutdown = false

    init(channel: GRPCChannel, baseChannel: GRPCChannel) {
        self.channel = channel
        self.baseChannel = baseChannel
    }

    // Closes only the channel; the backing EventLoopGroup is shared across all
    // signal transports and torn down once by `shutdownPipeline`.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        _ = try? baseChannel.close().wait()
    }
}

private final class CompressionConfiguredGRPCChannel: GRPCChannel {
    private let base: GRPCChannel
    private let messageEncoding: ClientMessageEncoding

    init(base: GRPCChannel, messageEncoding: ClientMessageEncoding) {
        self.base = base
        self.messageEncoding = messageEncoding
    }

    func makeCall<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        path: String,
        type: GRPCCallType,
        callOptions: CallOptions,
        interceptors: [ClientInterceptor<Request, Response>]
    ) -> Call<Request, Response> {
        var updatedOptions = callOptions
        updatedOptions.messageEncoding = messageEncoding
        return base.makeCall(
            path: path,
            type: type,
            callOptions: updatedOptions,
            interceptors: interceptors
        )
    }

    func makeCall<Request: GRPCPayload, Response: GRPCPayload>(
        path: String,
        type: GRPCCallType,
        callOptions: CallOptions,
        interceptors: [ClientInterceptor<Request, Response>]
    ) -> Call<Request, Response> {
        var updatedOptions = callOptions
        updatedOptions.messageEncoding = messageEncoding
        return base.makeCall(
            path: path,
            type: type,
            callOptions: updatedOptions,
            interceptors: interceptors
        )
    }

    func close() -> EventLoopFuture<Void> {
        base.close()
    }

    func close(promise: EventLoopPromise<Void>) {
        base.close(promise: promise)
    }

    func closeGracefully(deadline: NIODeadline, promise: EventLoopPromise<Void>) {
        base.closeGracefully(deadline: deadline, promise: promise)
    }
}

private struct DictionarySetter: Setter {
    func set(carrier: inout [String: String], key: String, value: String) {
        carrier[key] = value
    }
}

private struct DictionaryGetter: Getter {
    func get(carrier: [String: String], key: String) -> [String]? {
        if let value = carrier[key] {
            return [value]
        }
        let lowercasedKey = key.lowercased()
        if let match = carrier.first(where: { $0.key.lowercased() == lowercasedKey }) {
            return [match.value]
        }
        return nil
    }
}
