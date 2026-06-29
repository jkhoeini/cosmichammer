import Foundation
import Testing
import HSDSTCore
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class OpenTelemetryOTLPExportTests {
        @Test
        func localLoopbackReceivesOTLPHTTPProtobufExports() throws {
            let result = try exportLoopbackFixture()

            for expected in OpenTelemetryGoldenFixtures.otlpHTTPRequests {
                let request = try #require(
                    result.requests.first { $0.path == expected.path },
                    "Missing OTLP \(expected.signal) request to \(expected.path)"
                )
                #expect(request.method == "POST")
                #expect(request.headers["content-type"]?.hasPrefix(expected.contentTypePrefix) == true)
                #expect(!request.body.isEmpty)
            }

            let status = result.status
            #expect(status.startedSpans == 2)
            #expect(status.endedSpans == 2)
            #expect(status.logRecords == 1)
            #expect(status.metricRecords >= 1)
        }

        @Test
        func localLoopbackHonorsSignalSpecificOTLPEndpoints() throws {
            let receiver = try LocalOTLPHTTPReceiver()
            let telemetry = ProductionTelemetry()
            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                serviceName: "cosmichammer-otlp-signal-endpoints",
                exporter: "otlp",
                protocolName: "http/protobuf",
                tracesEndpoint: "\(receiver.endpoint)/custom/traces",
                logsEndpoint: "\(receiver.endpoint)/custom/logs",
                metricsEndpoint: "\(receiver.endpoint)/custom/metrics",
                compression: "none",
                timeoutSeconds: 2,
                batch: [
                    "scheduleDelay": 1,
                    "maxQueueSize": 64,
                    "maxExportBatchSize": 8,
                ],
                traces: true,
                logs: true,
                metrics: true
            ))

            let spanID = try #require(telemetry.startSpan(
                name: "otlp.custom-endpoint.trace",
                kind: .client,
                attributes: [:],
                startTime: nil
            ))
            telemetry.endSpan(id: spanID, status: .ok, attributes: [:], endTime: nil)
            telemetry.recordLog(level: "info", message: "otlp.custom-endpoint.log", attributes: [:], timestamp: nil)
            telemetry.recordMetric(name: "otlp.custom_endpoint.metric", kind: .gauge, value: 1, attributes: [:], unit: "1")

            #expect(telemetry.flush(timeout: 2))
            #expect(telemetry.shutdown(timeout: 2))

            let requests = receiver.waitForRequests(count: 3, timeout: 5)
            let paths = Set(requests.map(\.path))
            #expect(paths.contains("/custom/traces"))
            #expect(paths.contains("/custom/logs"))
            #expect(paths.contains("/custom/metrics"))
        }

        @Test
        func decodesOTLPProtobufPayloadsAgainstGoldenFixtures() throws {
            let payload = OpenTelemetryGoldenFixtures.otlpPayload
            let result = try exportLoopbackFixture()
            let decoded = try decodeOTLPRequests(result.requests)

            assertResourceAttributes(decoded.resources, payload: payload)
            assertTracePayload(decoded.resourceSpans, payload: payload)
            assertLogPayload(decoded.resourceLogs, payload: payload)
            assertMetricPayload(decoded.resourceMetrics, payload: payload)
        }
    }
}

private struct LoopbackExportResult {
    var requests: [LocalOTLPHTTPRequest]
    var status: TelemetryStatusSnapshot
}

private struct DecodedOTLPRequests {
    var resourceSpans: [Opentelemetry_Proto_Trace_V1_ResourceSpans]
    var resourceLogs: [Opentelemetry_Proto_Logs_V1_ResourceLogs]
    var resourceMetrics: [Opentelemetry_Proto_Metrics_V1_ResourceMetrics]

    var resources: [Opentelemetry_Proto_Resource_V1_Resource] {
        resourceSpans.map(\.resource) + resourceLogs.map(\.resource) + resourceMetrics.map(\.resource)
    }
}

private func exportLoopbackFixture() throws -> LoopbackExportResult {
    let payload = OpenTelemetryGoldenFixtures.otlpPayload
    let receiver = try LocalOTLPHTTPReceiver()
    let telemetry = ProductionTelemetry()
    telemetry.configure(TelemetryConfiguration(
        enabled: true,
        serviceName: payload.serviceName,
        exporter: "otlp",
        protocolName: "http/protobuf",
        endpoint: receiver.endpoint,
        compression: "none",
        timeoutSeconds: 2,
        batch: [
            "scheduleDelay": 1,
            "maxQueueSize": 64,
            "maxExportBatchSize": 8,
        ],
        traces: true,
        logs: true,
        metrics: true,
        resourceAttributes: payload.resourceAttributes
    ))

    try emitLoopbackSignals(telemetry, payload: payload)
    #expect(telemetry.flush(timeout: 2))
    #expect(telemetry.shutdown(timeout: 2))

    let requests = receiver.waitForRequests(
        count: OpenTelemetryGoldenFixtures.otlpHTTPRequests.count,
        timeout: 5
    )
    return LoopbackExportResult(requests: requests, status: telemetry.status())
}

private func emitLoopbackSignals(
    _ telemetry: ProductionTelemetry,
    payload: OpenTelemetryGoldenFixtures.OTLPPayloadExpectation
) throws {
    let parentID = try #require(telemetry.startSpan(
        name: payload.parentSpanName,
        kind: .server,
        attributes: ["test.signal": "trace", "span.role": "parent"],
        startTime: nil
    ))
    let childID = try #require(telemetry.startSpan(
        name: payload.childSpanName,
        kind: .client,
        attributes: ["test.signal": "trace", "span.role": "child"],
        startTime: nil
    ))

    telemetry.addEvent(spanID: childID, name: payload.spanEventName, attributes: ["phase": "export"], timestamp: nil)
    telemetry.endSpan(id: childID, status: .ok, attributes: ["test.result": "success"], endTime: nil)
    telemetry.recordLog(
        level: "info",
        message: payload.logMessage,
        attributes: ["test.signal": "log"],
        timestamp: nil
    )
    telemetry.recordMetric(
        name: payload.metricName,
        kind: .counter,
        value: 1,
        attributes: ["test.signal": "metric"],
        unit: "1"
    )
    telemetry.endSpan(id: parentID, status: .ok, attributes: ["test.result": "success"], endTime: nil)
}

private func decodeOTLPRequests(_ requests: [LocalOTLPHTTPRequest]) throws -> DecodedOTLPRequests {
    let traceRequests = requests.filter { $0.path == "/v1/traces" }
    let logRequests = requests.filter { $0.path == "/v1/logs" }
    let metricRequests = requests.filter { $0.path == "/v1/metrics" && !$0.body.isEmpty }
    #expect(!traceRequests.isEmpty)
    #expect(!logRequests.isEmpty)
    #expect(!metricRequests.isEmpty)

    let resourceSpans = try traceRequests.flatMap { request in
        try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(
            serializedBytes: request.body
        ).resourceSpans
    }
    let resourceLogs = try logRequests.flatMap { request in
        try Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest(
            serializedBytes: request.body
        ).resourceLogs
    }
    let resourceMetrics = try metricRequests.flatMap { request in
        try Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest(
            serializedBytes: request.body
        ).resourceMetrics
    }

    return DecodedOTLPRequests(
        resourceSpans: resourceSpans,
        resourceLogs: resourceLogs,
        resourceMetrics: resourceMetrics
    )
}

private func assertResourceAttributes(
    _ resources: [Opentelemetry_Proto_Resource_V1_Resource],
    payload: OpenTelemetryGoldenFixtures.OTLPPayloadExpectation
) {
    #expect(!resources.isEmpty)
    for resource in resources {
        let attributes = stringAttributes(resource.attributes)
        #expect(attributes["service.name"] == payload.serviceName)
        for (key, value) in payload.resourceAttributes {
            #expect(attributes[key] == value)
        }
    }
}

private func assertTracePayload(
    _ resourceSpans: [Opentelemetry_Proto_Trace_V1_ResourceSpans],
    payload: OpenTelemetryGoldenFixtures.OTLPPayloadExpectation
) {
    let spans = resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
    let parent = spans.first { $0.name == payload.parentSpanName }
    let child = spans.first { $0.name == payload.childSpanName }

    #expect(parent != nil)
    #expect(child != nil)
    guard let parent, let child else { return }

    #expect(parent.kind == .server)
    #expect(parent.parentSpanID.isEmpty)
    #expect(parent.status.code == .ok)
    #expect(child.kind == .client)
    #expect(child.parentSpanID == parent.spanID)
    #expect(child.status.code == .ok)
    #expect(stringAttributes(child.attributes)["test.signal"] == "trace")
    #expect(stringAttributes(child.attributes)["test.result"] == "success")

    let event = child.events.first { $0.name == payload.spanEventName }
    #expect(event != nil)
    if let event {
        #expect(stringAttributes(event.attributes)["phase"] == "export")
    }
}

private func assertLogPayload(
    _ resourceLogs: [Opentelemetry_Proto_Logs_V1_ResourceLogs],
    payload: OpenTelemetryGoldenFixtures.OTLPPayloadExpectation
) {
    let records = resourceLogs.flatMap(\.scopeLogs).flatMap(\.logRecords)
    let record = records.first { stringValue($0.body) == payload.logMessage }

    #expect(record != nil)
    guard let record else { return }

    #expect(record.severityNumber == .info)
    #expect(record.severityText.lowercased() == "info")
    #expect(stringAttributes(record.attributes)["test.signal"] == "log")
    #expect(!record.traceID.isEmpty)
    #expect(!record.spanID.isEmpty)
}

private func assertMetricPayload(
    _ resourceMetrics: [Opentelemetry_Proto_Metrics_V1_ResourceMetrics],
    payload: OpenTelemetryGoldenFixtures.OTLPPayloadExpectation
) {
    let metrics = resourceMetrics.flatMap(\.scopeMetrics).flatMap(\.metrics)
    let metric = metrics.first { $0.name == payload.metricName }

    #expect(metric != nil)
    guard let metric else { return }

    #expect(metric.unit == "1")
    guard case .sum(let sum)? = metric.data else {
        Issue.record("Expected \(payload.metricName) to export as an OTLP sum")
        return
    }
    #expect(sum.isMonotonic)
    #expect(sum.dataPoints.contains { point in
        stringAttributes(point.attributes)["test.signal"] == "metric" && numberValue(point) == 1
    })
}

private func stringAttributes(_ attributes: [Opentelemetry_Proto_Common_V1_KeyValue]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: attributes.compactMap { attribute in
        guard let value = stringValue(attribute.value) else { return nil }
        return (attribute.key, value)
    })
}

private func stringValue(_ value: Opentelemetry_Proto_Common_V1_AnyValue) -> String? {
    if case .stringValue(let string)? = value.value {
        return string
    }
    return nil
}

private func numberValue(_ point: Opentelemetry_Proto_Metrics_V1_NumberDataPoint) -> Double? {
    switch point.value {
    case .asDouble(let value):
        return value
    case .asInt(let value):
        return Double(value)
    case nil:
        return nil
    }
}
