import Foundation
import Testing
import HSDSTCore
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class OpenTelemetryGRPCIntegrationTests {
        @Test func productionGRPCExporterConfiguresWithoutCollector() {
            let telemetry = ProductionTelemetry()
            telemetry.configure(grpcConfiguration(serviceName: "cosmichammer-otel-grpc-pending"))
            defer { _ = telemetry.shutdown(timeout: 1) }

            let status = telemetry.status()
            #expect(status.exporter == "otlp")
            #expect(status.protocolName == "grpc")
            #expect(status.lastExportError == nil)
            #expect(status.lastExporterFailureKind == nil)
        }

        @Test(.enabled(
            if: otelGRPCIntegrationTestsRunnable,
            "Requires COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 and a collector on COSMIC_HAMMER_OTEL_GRPC_ENDPOINT"
        ))
        func collectorBackedGRPCTraceExportSmoke() throws {
            let telemetry = configuredGRPCTelemetry(serviceName: "cosmichammer-otel-grpc-traces")
            defer { _ = telemetry.shutdown(timeout: 5) }

            let spanID = try #require(telemetry.startSpan(
                name: "grpc.integration.trace",
                kind: .client,
                attributes: ["test.signal": "trace"],
                startTime: nil
            ))
            telemetry.addEvent(spanID: spanID, name: "collector-ready", attributes: ["transport": "grpc"], timestamp: nil)
            telemetry.endSpan(id: spanID, status: .ok, attributes: ["test.result": "success"], endTime: nil)

            #expect(telemetry.flush(timeout: 5))
            let status = telemetry.status()
            #expect(status.startedSpans == 1)
            #expect(status.endedSpans == 1)
            #expect(status.lastExportError == nil)
        }

        @Test(.enabled(
            if: otelGRPCIntegrationTestsRunnable,
            "Requires COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 and a collector on COSMIC_HAMMER_OTEL_GRPC_ENDPOINT"
        ))
        func collectorBackedGRPCLogExportSmoke() {
            let telemetry = configuredGRPCTelemetry(serviceName: "cosmichammer-otel-grpc-logs")
            defer { _ = telemetry.shutdown(timeout: 5) }

            telemetry.recordLog(
                level: "info",
                message: "grpc.integration.log",
                attributes: ["test.signal": "log", "transport": "grpc"],
                timestamp: nil
            )

            #expect(telemetry.flush(timeout: 5))
            let status = telemetry.status()
            #expect(status.logRecords == 1)
            #expect(status.lastExportError == nil)
        }

        @Test(.enabled(
            if: otelGRPCIntegrationTestsRunnable,
            "Requires COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 and a collector on COSMIC_HAMMER_OTEL_GRPC_ENDPOINT"
        ))
        func collectorBackedGRPCMetricExportSmoke() {
            let telemetry = configuredGRPCTelemetry(serviceName: "cosmichammer-otel-grpc-metrics")

            telemetry.recordMetric(
                name: "grpc.integration.metric",
                kind: .counter,
                value: 1,
                attributes: ["test.signal": "metric", "transport": "grpc"],
                unit: "1"
            )

            Thread.sleep(forTimeInterval: 2)
            #expect(telemetry.flush(timeout: 5))
            #expect(telemetry.shutdown(timeout: 5))
            let status = telemetry.status()
            #expect(status.metricRecords >= 1)
            #expect(status.lastExportError == nil)
        }
    }
}

private let otelGRPCIntegrationTestsRunnable =
    ProcessInfo.processInfo.environment["COSMIC_HAMMER_OTEL_GRPC_INTEGRATION"] == "1"

private func configuredGRPCTelemetry(serviceName: String) -> ProductionTelemetry {
    let telemetry = ProductionTelemetry()
    telemetry.configure(grpcConfiguration(serviceName: serviceName))

    let status = telemetry.status()
    #expect(status.exporter == "otlp")
    #expect(status.protocolName == "grpc")
    #expect(
        status.lastExportError == nil,
        "OTLP/gRPC production exporter should configure cleanly before running collector-backed checks"
    )

    return telemetry
}

private func grpcConfiguration(serviceName: String) -> TelemetryConfiguration {
    TelemetryConfiguration(
        enabled: true,
        serviceName: serviceName,
        exporter: "otlp",
        protocolName: "grpc",
        endpoint: ProcessInfo.processInfo.environment["COSMIC_HAMMER_OTEL_GRPC_ENDPOINT"] ?? "http://127.0.0.1:4317",
        timeoutSeconds: 5,
        batch: [
            "scheduleDelay": 1,
            "maxQueueSize": 128,
            "maxExportBatchSize": 16,
        ],
        capturePrint: "off",
        captureLogger: true,
        traces: true,
        logs: true,
        metrics: true,
        resourceAttributes: [
            "deployment.environment.name": "integration",
            "test.transport": "grpc",
        ]
    )
}
