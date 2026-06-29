import Foundation
import Testing
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libopentelemetry")
private func luaopen_hs_libopentelemetry(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

@_silgen_name("luaopen_hs_libsettings")
private func luaopen_hs_libsettings(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) final class OpenTelemetryFunctionalTests {
        @Test func configureEnablesTelemetryAndRecordsSignals() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({
                  enabled = true,
                  serviceName = "test-service",
                  exporter = "console",
                  traces = true,
                  logs = true,
                  metrics = true,
                })
                span = mod.startSpan("work", {
                  kind = "internal",
                  attributes = { component = "test" },
                })
                mod.log("info", "hello", { component = "test" })
                mod.metric("jobs_total", 2, {
                  kind = "counter",
                  unit = "1",
                  attributes = { result = "ok" },
                })
                mod.addEvent("step", { n = 1 }, span)
                mod.endSpan(span, { code = "ok" })
                """))

                #expect(sim.configuration.enabled)
                #expect(sim.configuration.serviceName == "test-service")
                #expect(sim.spans.count == 1)
                #expect(sim.spans[0].name == "work")
                #expect(sim.spans[0].ended)
                #expect(sim.spans[0].status == .ok)
                #expect(sim.logs.count == 1)
                #expect(sim.logs[0].message == "hello")
                #expect(sim.metrics.count == 1)
                #expect(sim.metrics[0].name == "jobs_total")
                #expect(sim.events.count == 1)
            }
        }

        @Test func disabledTelemetryDoesNotRecordSignals() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = false })
                span = mod.startSpan("ignored")
                mod.log("info", "ignored")
                mod.metric("ignored", 1)
                """))

                #expect(!sim.configuration.enabled)
                #expect(sim.spans.isEmpty)
                #expect(sim.logs.isEmpty)
                #expect(sim.metrics.isEmpty)
            }
        }

        @Test func productionOTLPGRPCProtocolConfiguresWithoutDiagnostic() {
            let telemetry = ProductionTelemetry()
            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                protocolName: "grpc",
                endpoint: "http://localhost:4317",
                headers: ["x-test-token": "secret"],
                compression: "deflate",
                timeoutSeconds: 2
            ))
            defer { _ = telemetry.shutdown(timeout: 1) }

            let status = telemetry.status()
            #expect(status.protocolName == "grpc")
            #expect(status.lastExportError == nil)
            #expect(status.lastExporterFailureKind == nil)
            #expect(telemetry.configuration.headers["x-test-token"] == "secret")
            #expect(telemetry.configuration.compression == "deflate")
        }

        @Test func unknownProductionOTLPProtocolReportsDiagnostic() {
            let telemetry = ProductionTelemetry()
            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                protocolName: "unknown",
                endpoint: "http://localhost:4317"
            ))
            defer { _ = telemetry.shutdown(timeout: 1) }

            let status = telemetry.status()
            #expect(status.protocolName == "unknown")
            #expect(status.lastExporterFailureKind == "unsupported_protocol")
            #expect(status.lastExportError?.contains("Unsupported OTLP protocol 'unknown'") == true)
        }

        @Test func productionOTLPGRPCPathBearingEndpointReportsDiagnostic() {
            let telemetry = ProductionTelemetry()
            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                protocolName: "otlp-grpc",
                endpoint: "https://collector.example:4317/v1/traces?debug=true#fragment"
            ))
            defer { _ = telemetry.shutdown(timeout: 1) }

            let status = telemetry.status()
            #expect(status.protocolName == "otlp-grpc")
            #expect(status.lastExporterFailureKind == "invalid_endpoint")
            #expect(status.lastExportError?.contains("must not include a path, query, or fragment") == true)
        }

        @Test func otlpCredentialHeadersRequireTLSUnlessLoopback() {
            let remote = ProductionTelemetry()
            remote.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                protocolName: "http/protobuf",
                endpoint: "http://collector.example:4318",
                headers: ["Authorization": "Bearer secret"]
            ))
            var status = remote.status()
            #expect(status.lastExporterFailureKind == "invalid_endpoint")
            #expect(status.lastExportError?.contains("credential headers over cleartext HTTP") == true)

            let local = ProductionTelemetry()
            local.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                protocolName: "http/protobuf",
                endpoint: "http://127.0.0.1:4318",
                headers: ["Authorization": "Bearer local"]
            ))
            defer { _ = local.shutdown(timeout: 1) }
            status = local.status()
            #expect(status.lastExporterFailureKind == nil)
            #expect(status.lastExportError == nil)
        }

        @Test func productionAndSimulatorStatusShareConfiguredExporterDefaults() {
            let configuration = TelemetryConfiguration(
                enabled: true,
                serviceName: "parity",
                exporter: "otlp",
                protocolName: "grpc",
                endpoint: "http://localhost:4317",
                compression: "none",
                timeoutSeconds: 3,
                batch: [
                    "maxQueueSize": 11,
                    "maxExportBatchSize": 7,
                    "scheduleDelay": 2,
                ]
            )
            let production = ProductionTelemetry()
            production.configure(configuration)
            defer { _ = production.shutdown(timeout: 1) }

            let simulator = SimulatedTelemetry()
            simulator.configure(configuration)

            let productionStatus = production.status()
            let simulatorStatus = simulator.status()
            #expect(productionStatus.exporter == simulatorStatus.exporter)
            #expect(productionStatus.protocolName == simulatorStatus.protocolName)
            #expect(productionStatus.compression == simulatorStatus.compression)
            #expect(productionStatus.exporterQueueDepth == nil)
            #expect(simulatorStatus.exporterQueueDepth == nil)
            #expect(productionStatus.exporterQueueCapacity == simulatorStatus.exporterQueueCapacity)
            #expect(productionStatus.exporterMaxExportBatchSize == simulatorStatus.exporterMaxExportBatchSize)
            #expect(productionStatus.exporterScheduleDelay == simulatorStatus.exporterScheduleDelay)
            #expect(productionStatus.exporterTimeout == simulatorStatus.exporterTimeout)
            #expect(productionStatus.lastExporterFailureKind == nil)
            #expect(simulatorStatus.lastExporterFailureKind == nil)
        }

        @Test func luaConfigureAcceptsGRPCProtocolAndCompression() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({
                  enabled = true,
                  exporter = "otlp",
                  protocol = "grpc",
                  endpoint = "http://localhost:4317",
                  compression = "none",
                  headers = { ["x-test-token"] = "secret" },
                })
                status = mod.status()
                """))

                #expect(sim.configuration.protocolName == "grpc")
                #expect(sim.configuration.compression == "none")
                #expect(sim.configuration.headers["x-test-token"] == "secret")
                #expect(sim.status().lastExportError == nil)
                lua_getglobal(L, "status")
                lua_getfield(L, -1, "lastExportError")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func captureLoggerAndPrintFlagsSuppressFacadeLogTelemetry() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({
                  enabled = true,
                  captureLogger = false,
                  capturePrint = "off",
                })
                otel.log("info", "logger secret", { ["log.source"] = "hs.logger" })
                otel.log("info", "print secret", { ["log.source"] = "hs._logmessage" })
                otel.log("info", "direct app log", { ["log.source"] = "app" })
                """))

                #expect(sim.logs.map(\.message) == ["direct app log"])
            }
        }

        @Test func swiftLoggerCaptureFlagSuppressesNativeLoggerTelemetry() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true, captureLogger: false))

                HSLogger(lua: nil).logForLuaSkin(atLevel: 3, withMessage: "private logger message")
                #expect(sim.logs.isEmpty)
                #expect(sim.events.isEmpty)

                sim.configure(TelemetryConfiguration(enabled: true, captureLogger: true))
                HSLogger(lua: nil).logForLuaSkin(atLevel: 3, withMessage: "visible logger message")
                #expect(sim.logs.contains { $0.message == "visible logger message" })
            }
        }

        @Test func luaStatusReportsUnknownOTLPProtocolDiagnostic() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({
                  enabled = true,
                  exporter = "otlp",
                  protocol = "unknown",
                  endpoint = "http://localhost:4317",
                })
                status = mod.status()
                """))

                #expect(sim.status().lastExportError?.contains("Unsupported OTLP protocol") == true)
                lua_getglobal(L, "status")
                lua_getfield(L, -1, "lastExportError")
                #expect(String(cString: lua_tostring(L, -1)).contains("Unsupported OTLP protocol"))
                lua_pop(L, 2)
            }
        }

        @Test func simulatorPreservesFailureCountsButClearsLastResultOnConfigure() {
            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                protocolName: "grpc",
                endpoint: "http://localhost:4317/v1/traces"
            ))

            var status = telemetry.status()
            #expect(status.lastExporterFailureKind == "invalid_endpoint")
            #expect(status.exporterFailureCount == 1)
            _ = telemetry.flush(timeout: 1)
            _ = telemetry.shutdown(timeout: 1)
            let failureCountBeforeReconfigure = telemetry.status().exporterFailureCount

            telemetry.configure(TelemetryConfiguration(enabled: true, exporter: "console"))

            status = telemetry.status()
            #expect(status.lastExporterFailureKind == nil)
            #expect(status.lastExportError == nil)
            #expect(status.lastFlushResult == nil)
            #expect(status.lastShutdownResult == nil)
            #expect(status.exporterFailureCount == failureCountBeforeReconfigure)
        }

        @Test func failedSimulatorShutdownClearsActiveAndRemoteContext() throws {
            let telemetry = SimulatedTelemetry(faults: .withTelemetryShutdownFailure())
            telemetry.configure(TelemetryConfiguration(enabled: true))
            let parent = try #require(telemetry.startSpan(name: "parent", kind: .internalSpan, attributes: [:], startTime: nil))
            telemetry.extract(from: [
                "traceparent": "00-00000000000000000000000000000001-0000000000000042-01"
            ])

            #expect(!telemetry.shutdown(timeout: 1))
            let child = try #require(telemetry.startSpan(name: "after-failed-shutdown", kind: .internalSpan, attributes: [:], startTime: nil))
            telemetry.endSpan(id: child, status: .ok, attributes: [:], endTime: nil)
            telemetry.endSpan(id: parent, status: .ok, attributes: [:], endTime: nil)

            let childSpan = telemetry.spans.first { $0.name == "after-failed-shutdown" }
            #expect(childSpan?.parentSpanID == nil)
            #expect(telemetry.status().activeSpanID == nil)
            #expect(telemetry.status().shutdownFailureCount == 1)
        }

        @Test func luaConfigureAcceptsMalformedEndpointAndReportsDiagnostic() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                #expect(luaEval(L, """
                configureOK = mod.configure({
                  enabled = true,
                  exporter = "otlp",
                  protocol = "http/protobuf",
                  endpoint = "http://[::1",
                })
                status = mod.status()
                """))

                lua_getglobal(L, "configureOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "status")
                lua_getfield(L, -1, "lastExporterFailureKind")
                #expect(String(cString: lua_tostring(L, -1)) == "invalid_endpoint")
                lua_pop(L, 1)
                lua_getfield(L, -1, "exporterFailureCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "lastExportError")
                #expect(String(cString: lua_tostring(L, -1)).contains("Invalid OTLP endpoint"))
                lua_pop(L, 2)
            }
        }

        @Test func luaLifecycleMetricHelperRecordsRuntimeMetric() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                sim.configure(TelemetryConfiguration(enabled: true))
                recordLuaLifecycleMetric(
                    L,
                    name: "cosmichammer.lua.init.count",
                    kind: .counter,
                    value: 1,
                    unit: "1"
                )

                #expect(sim.metrics.count == 1)
                #expect(sim.metrics[0].name == "cosmichammer.lua.init.count")
                #expect(sim.metrics[0].kind == .counter)
                #expect(sim.metrics[0].value == 1)
                #expect(sim.metrics[0].unit == "1")
            }
        }

        @Test func appleScriptPermissionToggleRecordsAuditLog() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                HSAppleScriptSetEnabled(true)
                defer { HSAppleScriptSetEnabled(false) }

                let auditLog = sim.logs.first { $0.message == "permission.applescript.set" }
                #expect(auditLog?.level == "info")
                #expect(auditLog?.attributes["cosmichammer.permission.name"] == "applescript")
                #expect(auditLog?.attributes["cosmichammer.permission.enabled"] == "true")
            }
        }

        @Test func corePrivacyPermissionAuditHelperRecordsLogs() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                for permissionName in ["accessibility", "screen_recording", "microphone", "camera"] {
                    recordPermissionAudit(
                        L,
                        name: permissionName,
                        action: "check",
                        enabled: false,
                        status: "denied_or_not_determined",
                        prompted: false
                    )
                    let auditLog = sim.logs.last
                    #expect(auditLog?.message == "permission.\(permissionName).check")
                    #expect(auditLog?.level == "info")
                    #expect(auditLog?.attributes["cosmichammer.permission.name"] == permissionName)
                    #expect(auditLog?.attributes["cosmichammer.permission.prompted"] == "false")
                    #expect(auditLog?.attributes["cosmichammer.permission.status"] == "denied_or_not_determined")
                    #expect(auditLog?.attributes["cosmichammer.permission.enabled"] == "false")
                }
            }
        }

        @Test func highFrequencyCallbacksAreSampledOutByDefault() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                resetLuaCallbackTelemetrySamplingCounters()
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, "function sampledCallback() return true end"))
                lua_getglobal(L, "sampledCallback")
                #expect(luaTelemetryPCall(L, nargs: 0, nresults: 0, callbackName: "hs.eventtap") == LUA_OK)

                #expect(sim.spans.isEmpty)
                #expect(sim.metrics.isEmpty)
            }
        }

        @Test func callbackSampleRateOverrideRecordsHighFrequencyCallback() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                resetLuaCallbackTelemetrySamplingCounters()
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(
                    enabled: true,
                    callbackSampleRates: ["hs.eventtap": 1]
                ))

                #expect(luaEval(L, "function sampledCallback() return true end"))
                lua_getglobal(L, "sampledCallback")
                #expect(luaTelemetryPCall(L, nargs: 0, nresults: 0, callbackName: "hs.eventtap") == LUA_OK)

                #expect(sim.spans.count == 1)
                #expect(sim.spans[0].attributes["cosmichammer.lua.callback.name"] == "hs.eventtap")
                #expect(sim.spans[0].attributes["lua.callback.name"] == nil)
                #expect(sim.spans[0].ended)
                #expect(sim.metrics.first?.name == "cosmichammer.lua.callback.duration")
            }
        }

        @Test func attributeLimitsDropExtraAttributesAndTruncateValues() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({
                  enabled = true,
                  attributeLimits = {
                    maxCount = 2,
                    maxValueLength = 4,
                  },
                })
                span = mod.startSpan("limited", {
                  attributes = {
                    a = "abcdef",
                    b = "keep",
                    c = "drop",
                  },
                })
                mod.endSpan(span, { code = "ok" })
                """))

                #expect(sim.configuration.attributeLimits["maxCount"] == 2)
                #expect(sim.configuration.attributeLimits["maxValueLength"] == 4)
                #expect(sim.spans.count == 1)
                #expect(sim.spans[0].attributes["a"] == "abcd")
                #expect(sim.spans[0].attributes["b"] == "keep")
                #expect(sim.spans[0].attributes["c"] == nil)
                // One attribute dropped for exceeding maxCount, one value truncated:
                // both are attribute-level drops, not dropped records.
                #expect(sim.status().droppedAttributes == 2)
                #expect(sim.status().droppedRecords == 0)
            }
        }

        @Test func simulatorRecordsMetricValuesLikeProduction() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                mod.metric("negative_counter", -3, { kind = "counter" })
                mod.metric("negative_histogram", -4, { kind = "histogram" })
                mod.metric("negative_gauge", -5, { kind = "gauge" })
                mod.metric("negative_updown", -6, { kind = "upDownCounter" })
                mod.metric("fractional_counter", 1.6, { kind = "counter" })
                mod.metric("fractional_updown", -1.6, { kind = "upDownCounter" })
                mod.metric("fractional_gauge", 1.6, { kind = "gauge" })
                mod.metric("fractional_histogram", 1.6, { kind = "histogram" })
                """))

                #expect(sim.metrics.first { $0.name == "negative_counter" }?.value == 0)
                #expect(sim.metrics.first { $0.name == "negative_histogram" }?.value == 0)
                #expect(sim.metrics.first { $0.name == "negative_gauge" }?.value == -5)
                #expect(sim.metrics.first { $0.name == "negative_updown" }?.value == -6)
                #expect(sim.metrics.first { $0.name == "fractional_counter" }?.value == 2)
                #expect(sim.metrics.first { $0.name == "fractional_updown" }?.value == -2)
                #expect(sim.metrics.first { $0.name == "fractional_gauge" }?.value == 1.6)
                #expect(sim.metrics.first { $0.name == "fractional_histogram" }?.value == 1.6)
            }
        }

        @Test func orphanTraceEventsAndExceptionsAreDropped() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                mod.addEvent("no-active-span", { value = 1 })
                mod.recordException("no active span")
                span = mod.startSpan("short-lived")
                mod.endSpan(span, { code = "ok" })
                mod.addEvent("ended-span", {}, span)
                mod.recordException("ended span", nil, nil, span)
                """))

                #expect(sim.events.isEmpty)
                #expect(sim.exceptions.isEmpty)
                #expect(sim.status().droppedRecords == 4)
            }
        }

        @Test func endingSpanTwiceDropsSecondEnd() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                span = mod.startSpan("single-end")
                mod.endSpan(span, { code = "ok" }, { result = "first" })
                mod.endSpan(span, { code = "error", message = "second" }, { result = "second" })
                """))

                #expect(sim.spans.count == 1)
                #expect(sim.spans[0].ended)
                #expect(sim.spans[0].status == .ok)
                #expect(sim.spans[0].attributes["result"] == "first")
                #expect(sim.status().droppedRecords == 1)
            }
        }

        @Test func recordExceptionMarksActiveSpanError() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                span = mod.startSpan("exception-status")
                mod.recordException("boom", "stack", { source = "test" }, span)
                """))

                #expect(sim.exceptions.count == 1)
                #expect(sim.exceptions[0].message == "boom")
                #expect(sim.spans.count == 1)
                #expect(sim.spans[0].status == .error("boom"))
                #expect(sim.spans[0].ended == false)
            }
        }

        @Test func injectAddsTraceparentWhenSpanIsActive() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                span = mod.startSpan("request")
                headers = mod.inject({})
                """))

                lua_getglobal(L, "headers")
                lua_getfield(L, -1, "traceparent")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                let traceparent = String(cString: lua_tostring(L, -1))
                #expect(traceparent.hasPrefix("00-"))
            }
        }

        @Test func propagatorsConfigControlsNativeTraceContext() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = true, propagators = {} })
                parent = mod.startSpan("parent")
                headers = mod.inject({})
                mod.endSpan(parent, { code = "ok" })
                mod.extract({
                  traceparent = "00-00000000000000000000000000000001-0000000000000042-01",
                })
                child = mod.startSpan("child")
                mod.endSpan(child, { code = "ok" })
                """))

                lua_getglobal(L, "headers")
                lua_getfield(L, -1, "traceparent")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                let childSpan = sim.spans.first { $0.name == "child" }
                #expect(childSpan?.parentSpanID == nil)
            }
        }

        @Test func simulatedTraceparentExtractionRejectsMalformedContextAndClearsStaleParent() throws {
            let validTraceparent = "00-00000000000000000000000000000001-0000000000000042-01"
            let invalidTraceparents = [
                "",
                "00-00000000000000000000000000000001-0000000000000042",
                "00-00000000000000000000000000000000-0000000000000042-01",
                "00-00000000000000000000000000000001-0000000000000000-01",
                "00-00000000000000000000000000000001-0000000000000042-gg",
                "ff-00000000000000000000000000000001-0000000000000042-01",
            ]

            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(enabled: true))
            telemetry.extract(from: ["traceparent": validTraceparent])
            let validChild = try #require(telemetry.startSpan(name: "valid-child", kind: .internalSpan, attributes: [:], startTime: nil))
            telemetry.endSpan(id: validChild, status: .ok, attributes: [:], endTime: nil)
            #expect(telemetry.spans.last?.parentSpanID == 0x42)

            telemetry.extract(from: ["traceparent": validTraceparent])
            telemetry.extract(from: [:])
            let missingChild = try #require(telemetry.startSpan(name: "missing-child", kind: .internalSpan, attributes: [:], startTime: nil))
            telemetry.endSpan(id: missingChild, status: .ok, attributes: [:], endTime: nil)
            #expect(telemetry.spans.last?.parentSpanID == nil)

            for (index, traceparent) in invalidTraceparents.enumerated() {
                telemetry.extract(from: ["traceparent": validTraceparent])
                telemetry.extract(from: ["traceparent": traceparent])
                let child = try #require(telemetry.startSpan(name: "invalid-child-\(index)", kind: .internalSpan, attributes: [:], startTime: nil))
                telemetry.endSpan(id: child, status: .ok, attributes: [:], endTime: nil)
                #expect(telemetry.spans.last?.parentSpanID == nil)
            }
        }

        @Test func extractedTraceparentParentsNextSpanBeforeActiveLocalSpan() throws {
            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(enabled: true))

            let localParent = try #require(telemetry.startSpan(name: "local-parent", kind: .internalSpan, attributes: [:], startTime: nil))
            telemetry.extract(from: [
                "traceparent": "00-00000000000000000000000000000001-0000000000000042-01"
            ])
            let remoteChild = try #require(telemetry.startSpan(name: "remote-child", kind: .server, attributes: [:], startTime: nil))
            telemetry.endSpan(id: remoteChild, status: .ok, attributes: [:], endTime: nil)
            telemetry.endSpan(id: localParent, status: .ok, attributes: [:], endTime: nil)

            #expect(telemetry.spans.first { $0.name == "remote-child" }?.parentSpanID == 0x42)
        }

        @Test func websocketRequestInjectsActiveTraceContext() throws {
            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(enabled: true))
            _ = telemetry.startSpan(name: "parent", kind: .internalSpan, attributes: [:], startTime: nil)

            let request = websocketRequest(
                url: try #require(URL(string: "ws://127.0.0.1:9000/")),
                telemetry: telemetry
            )

            #expect(request.value(forHTTPHeaderField: "traceparent")?.hasPrefix("00-") == true)
        }

        @Test func activeSpanRestoresParentWhenChildEnds() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                parent = mod.startSpan("parent")
                child = mod.startSpan("child")
                mod.endSpan(child, { code = "ok" })
                status = mod.status()
                mod.endSpan(parent, { code = "ok" })
                """))

                lua_getglobal(L, "status")
                lua_getfield(L, -1, "activeSpanID")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 2)
            }
        }

        @Test func reconfigureClearsActiveAndExtractedContext() throws {
            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(enabled: true))
            let parent = telemetry.startSpan(name: "parent", kind: .internalSpan, attributes: [:], startTime: nil)
            #expect(parent != nil)

            telemetry.configure(TelemetryConfiguration(enabled: true))
            let afterActiveReset = try #require(telemetry.startSpan(name: "after-active-reset", kind: .internalSpan, attributes: [:], startTime: nil))
            telemetry.endSpan(id: afterActiveReset, status: .ok, attributes: [:], endTime: nil)

            telemetry.extract(from: [
                "traceparent": "00-00000000000000000000000000000001-0000000000000042-01"
            ])
            telemetry.configure(TelemetryConfiguration(enabled: true))
            _ = try #require(telemetry.startSpan(name: "after-remote-reset", kind: .internalSpan, attributes: [:], startTime: nil))

            let activeResetSpan = telemetry.spans.first { $0.name == "after-active-reset" }
            let remoteResetSpan = telemetry.spans.first { $0.name == "after-remote-reset" }
            #expect(activeResetSpan?.parentSpanID == nil)
            #expect(remoteResetSpan?.parentSpanID == nil)
        }

        @Test func statusIncludesFlushDiagnostics() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({
                  enabled = true,
                  attributeLimits = { maxCount = 1, maxValueLength = 32 },
                })
                span = mod.startSpan("active")
                mod.log("info", "limited", { a = "keep", b = "drop" })
                flushOK = mod.flush(1)
                status = mod.status()
                mod.endSpan(span, { code = "ok" })
                """))

                #expect(sim.status().flushCount == 1)
                #expect(sim.status().lastFlushDuration != nil)
                #expect(sim.metrics.contains {
                    $0.name == "cosmichammer.telemetry.flush.duration"
                        && $0.kind == .histogram
                        && $0.unit == "s"
                        && $0.attributes["cosmichammer.telemetry.flush.result"] == "success"
                        && $0.attributes["otel.flush.result"] == nil
                })
                #expect(sim.metrics.contains {
                    $0.name == "cosmichammer.telemetry.flush.count"
                        && $0.kind == .counter
                        && $0.value == 1
                })
                #expect(sim.metrics.contains {
                    $0.name == "cosmichammer.telemetry.spans.active"
                        && $0.kind == .gauge
                        && $0.value == 1
                })
                #expect(sim.metrics.contains {
                    $0.name == "cosmichammer.telemetry.records.dropped"
                        && $0.kind == .gauge
                })
                // The over-limit log attribute is an attribute-level drop, surfaced
                // by the dedicated attributes.dropped gauge (not records.dropped).
                #expect(sim.metrics.contains {
                    $0.name == "cosmichammer.telemetry.attributes.dropped"
                        && $0.kind == .gauge
                        && $0.value >= 1
                })

                lua_getglobal(L, "flushOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "status")
                lua_getfield(L, -1, "flushCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "lastFlushDuration")
                #expect(lua_isnumber(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func statusIncludesExporterQueueConfigurationAndFailureCounters() {
            let telemetry = SimulatedTelemetry()
            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                batch: [
                    "maxQueueSize": 1,
                    "maxExportBatchSize": 1,
                    "scheduleDelay": 2,
                ]
            ))

            telemetry.recordLog(level: "info", message: "queued", attributes: [:], timestamp: nil)
            telemetry.recordLog(level: "info", message: "dropped", attributes: [:], timestamp: nil)
            #expect(telemetry.flush(timeout: 3))

            let status = telemetry.status()
            #expect(status.exporterQueueCapacity == 1)
            #expect(status.exporterMaxExportBatchSize == 1)
            #expect(status.exporterScheduleDelay == 2)
            #expect(status.exporterTimeout == 5)
            #expect(status.backpressureDroppedRecords == 1)
            #expect(status.exporterFailureCount == 0)
            #expect(status.flushFailureCount == 0)
            #expect(status.lastFlushResult == "success")
            #expect(status.lastExportDuration != nil)
            #expect(telemetry.metrics.contains {
                $0.name == "cosmichammer.telemetry.exporter.queue.capacity"
                    && $0.kind == .gauge
                    && $0.value == 1
            })
            #expect(telemetry.metrics.contains {
                $0.name == "cosmichammer.telemetry.exporter.batch.max_size"
                    && $0.kind == .gauge
                    && $0.value == 1
            })
            #expect(telemetry.metrics.contains {
                $0.name == "cosmichammer.telemetry.exporter.schedule.delay"
                    && $0.kind == .gauge
                    && $0.value == 2
            })
            #expect(telemetry.metrics.contains {
                $0.name == "cosmichammer.telemetry.exporter.timeout"
                    && $0.kind == .gauge
                    && $0.value == 5
            })
            #expect(telemetry.metrics.contains {
                $0.name == "cosmichammer.telemetry.exporter.backpressure.dropped_records"
                    && $0.kind == .gauge
                    && $0.value == 1
            })
            #expect(telemetry.metrics.contains {
                $0.name == "cosmichammer.telemetry.exporter.failure.count"
                    && $0.kind == .gauge
                    && $0.value == 0
            })
        }

        @Test func luaStatusExposesExporterDiagnostics() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                #expect(luaEval(L, """
                mod.configure({
                  enabled = true,
                  batch = {
                    maxQueueSize = 1,
                    maxExportBatchSize = 1,
                    scheduleDelay = 2,
                  },
                })
                mod.log("info", "queued")
                mod.log("info", "dropped")
                mod.flush(3)
                status = mod.status()
                """))

                lua_getglobal(L, "status")
                lua_getfield(L, -1, "exporterQueueCapacity")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "exporterMaxExportBatchSize")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "exporterScheduleDelay")
                #expect(lua_tonumber(L, -1) == 2)
                lua_pop(L, 1)
                lua_getfield(L, -1, "backpressureDroppedRecords")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "exporterFailureCount")
                #expect(lua_tointeger(L, -1) == 0)
                lua_pop(L, 1)
                lua_getfield(L, -1, "lastFlushResult")
                #expect(String(cString: lua_tostring(L, -1)) == "success")
                lua_pop(L, 2)
            }
        }

        @Test func shutdownFlushesAndClearsActiveContext() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry

                #expect(luaEval(L, """
                mod.configure({ enabled = true })
                parent = mod.startSpan("parent")
                mod.extract({
                  traceparent = "00-00000000000000000000000000000001-0000000000000042-01",
                })
                shutdownOK = mod.shutdown(1)
                afterShutdown = mod.status()
                child = mod.startSpan("after-shutdown")
                mod.endSpan(child, { code = "ok" })
                """))

                #expect(sim.shutdownCount == 1)
                #expect(sim.flushCount == 1)
                #expect(sim.metrics.contains {
                    $0.name == "cosmichammer.telemetry.spans.active"
                        && $0.kind == .gauge
                        && $0.value == 0
                })
                let childSpan = sim.spans.first { $0.name == "after-shutdown" }
                #expect(childSpan?.parentSpanID == nil)

                lua_getglobal(L, "shutdownOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "afterShutdown")
                lua_getfield(L, -1, "activeSpanID")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeSupportsSpanObjectsBaggageAndRedaction() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                otel.setRedactor(function(key, value)
                  if key == "secret" then return nil end
                  return value
                end)
                span = otel.startSpan("facade", { attributes = { secret = "drop", kept = "yes" } })
                span:addEvent("event", { secret = "drop", kept = "yes" })
                otel.setBaggage("tenant", "blue")
                headers = otel.inject({})
                otel.extract({ baggage = "user=ada" })
                diagnostics = otel.diagnostics()
                span:endSpan({ code = "ok" })
                """))

                #expect(sim.spans.count == 1)
                #expect(sim.spans[0].attributes["secret"] == nil)
                #expect(sim.spans[0].attributes["kept"] == "yes")
                #expect(sim.events.first?.attributes["secret"] == nil)
                #expect(sim.events.first?.attributes["kept"] == "yes")

                lua_getglobal(L, "headers")
                lua_getfield(L, -1, "baggage")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                #expect(String(cString: lua_tostring(L, -1)).contains("tenant=blue"))
                lua_pop(L, 2)

                lua_getglobal(L, "diagnostics")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeStatusReturnsNativeStatusWithoutFacadeDiagnostics() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true, serviceName = "status-service" })
                otel.setBaggage("tenant", "blue")
                plainStatus = otel.status()
                richDiagnostics = otel.diagnostics()
                """))

                lua_getglobal(L, "plainStatus")
                lua_getfield(L, -1, "enabled")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)
                lua_getfield(L, -1, "serviceName")
                #expect(String(cString: lua_tostring(L, -1)) == "status-service")
                lua_pop(L, 1)
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "richDiagnostics")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeDoesNotExposeRawNativeMutators() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                rawMutatorsHidden =
                  otel.setAttributes == nil and
                  otel.endSpan ~= native.endSpan and
                  otel.addEvent ~= native.addEvent and
                  otel.recordException ~= native.recordException and
                  otel.log ~= native.log and
                  otel.metric ~= native.metric
                """))

                lua_getglobal(L, "rawMutatorsHidden")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)
            }
        }

        @Test func luaFacadeRedactorErrorsAreContainedAcrossSignals() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                otel.setRedactor(function(key, value)
                  if tostring(key):find("^bad") then
                    error("redactor boom")
                  end
                  return value
                end)
                span = otel.startSpan("redactor-fault", {
                  attributes = { badStart = "secret", good = "keep" },
                })
                span:addEvent("redacted-event", { badEvent = "secret", good = "keep" })
                span:setAttribute("badSet", "secret")
                otel.log("info", "redacted-log", { badLog = "secret", good = "keep" })
                otel.meter("redactor"):counter("redactor.counter"):add(1, { badMetric = "secret", good = "keep" })
                span:endSpan({ code = "ok" }, { badEnd = "secret", goodEnd = "done" })
                """))

                let span = sim.spans.first { $0.name == "redactor-fault" }
                #expect(span?.attributes["badStart"] == "<redaction error>")
                #expect(span?.attributes["badSet"] == "<redaction error>")
                #expect(span?.attributes["badEnd"] == "<redaction error>")
                #expect(span?.attributes["good"] == "keep")
                #expect(span?.attributes["goodEnd"] == "done")
                #expect(span?.ended == true)

                let event = sim.events.first { $0.name == "redacted-event" }
                #expect(event?.attributes["badEvent"] == "<redaction error>")
                #expect(event?.attributes["good"] == "keep")

                let log = sim.logs.first { $0.message == "redacted-log" }
                #expect(log?.attributes["badLog"] == "<redaction error>")
                #expect(log?.attributes["good"] == "keep")

                let metric = sim.metrics.first { $0.name == "redactor.counter" }
                #expect(metric?.attributes["badMetric"] == "<redaction error>")
                #expect(metric?.attributes["good"] == "keep")
            }
        }

        @Test func luaFacadeMeterInstrumentsRecordMetrics() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                otel.setRedactor(function(key, value)
                  if key == "secret" then return nil end
                  return value
                end)
                meter = otel.meter("facade-meter", "1.0")
                counter = meter:counter("facade.counter", { unit = "1" })
                updown = meter:upDownCounter("facade.updown", { unit = "items" })
                gauge = meter:gauge("facade.gauge", { unit = "ms" })
                histogram = meter:histogram("facade.histogram", { unit = "s" })
                meterMetadataOK = meter.name == "facade-meter" and meter.version == "1.0"
                instrumentMetadataOK = counter.name == "facade.counter"
                  and counter.kind == "counter"
                  and counter.unit == "1"
                  and updown.kind == "upDownCounter"
                  and gauge.kind == "gauge"
                  and histogram.kind == "histogram"
                instrumentChainOK = counter:add(1.6, { secret = "drop", kept = "yes" }) == counter
                  and updown:add(-1.6, { secret = "drop", kept = "yes" }) == updown
                  and gauge:record(3.5, { secret = "drop", kept = "yes" }) == gauge
                  and histogram:record(4.25, { secret = "drop", kept = "yes" }) == histogram
                invalidMetricNameRejected = pcall(function()
                  meter:counter("")
                end) == false and pcall(function()
                  meter:gauge()
                end) == false
                invalidMeterNameRejected = pcall(function()
                  otel.meter("")
                end) == false and pcall(function()
                  otel.meter()
                end) == false
                """))

                lua_getglobal(L, "meterMetadataOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "instrumentMetadataOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "instrumentChainOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "invalidMetricNameRejected")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "invalidMeterNameRejected")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                #expect(sim.metrics.first { $0.name == "facade.counter" }?.kind == .counter)
                #expect(sim.metrics.first { $0.name == "facade.counter" }?.value == 2)
                #expect(sim.metrics.first { $0.name == "facade.counter" }?.unit == "1")
                #expect(sim.metrics.first { $0.name == "facade.updown" }?.kind == .upDownCounter)
                #expect(sim.metrics.first { $0.name == "facade.updown" }?.value == -2)
                #expect(sim.metrics.first { $0.name == "facade.gauge" }?.kind == .gauge)
                #expect(sim.metrics.first { $0.name == "facade.gauge" }?.unit == "ms")
                #expect(sim.metrics.first { $0.name == "facade.histogram" }?.kind == .histogram)
                #expect(sim.metrics.first { $0.name == "facade.histogram" }?.value == 4.25)
                #expect(sim.metrics.allSatisfy { $0.attributes["secret"] == nil })
                #expect(sim.metrics.allSatisfy { $0.attributes["kept"] == "yes" })
            }
        }

        @Test func luaFacadeTracerMethodsStartNamedSpans() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                invalidTracerNameRejected = pcall(function()
                  otel.tracer("")
                end) == false and pcall(function()
                  otel.tracer()
                end) == false
                tracer = otel.tracer("facade-tracer", "1.0")
                invalidTracerSpanNameRejected = pcall(function()
                  tracer:startSpan("")
                end) == false and pcall(function()
                  tracer:withSpan("", function() end)
                end) == false
                span = tracer:startSpan("tracer-start")
                tracerSpanStartedOpen = span.ended == false
                tracer:withSpan("tracer-with", function(child)
                  child:setAttribute("source", "tracer")
                  child:setStatus("ok")
                end)
                tracerReturnFirst, tracerReturnGap, tracerReturnTail = tracer:withSpan("tracer-returns", function()
                  return "tracer-first", nil, "tracer-tail"
                end)
                tracerParent = tracer:startSpan("tracer-parent")
                tracerErrorOK = pcall(function()
                  tracer:withSpan("tracer-error", function(child)
                    tracerErrorChild = child
                    error("tracer boom")
                  end)
                end)
                tracerErrorRaised = tracerErrorOK == false
                tracerErrorPreservedParent = otel.activeSpan() == tracerParent.id
                tracerErrorChildEnded = tracerErrorChild.ended == true
                tracerParent:finish()
                tracerEndReturnedSelf = span:endSpan({ code = "ok" }) == span
                tracerSpanEnded = span.ended == true
                """))

                let startedSpan = sim.spans.first { $0.name == "tracer-start" }
                #expect(startedSpan?.status == .ok)
                #expect(startedSpan?.ended == true)

                lua_getglobal(L, "invalidTracerNameRejected")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "invalidTracerSpanNameRejected")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tracerSpanStartedOpen")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tracerEndReturnedSelf")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tracerSpanEnded")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                let withSpan = sim.spans.first { $0.name == "tracer-with" }
                #expect(withSpan?.attributes["source"] == "tracer")
                #expect(withSpan?.status == .ok)
                #expect(withSpan?.ended == true)

                lua_getglobal(L, "tracerReturnFirst")
                #expect(String(cString: lua_tostring(L, -1)) == "tracer-first")
                lua_pop(L, 1)

                lua_getglobal(L, "tracerReturnGap")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tracerReturnTail")
                #expect(String(cString: lua_tostring(L, -1)) == "tracer-tail")
                lua_pop(L, 1)

                let returnSpan = sim.spans.first { $0.name == "tracer-returns" }
                #expect(returnSpan?.ended == true)

                lua_getglobal(L, "tracerErrorRaised")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tracerErrorPreservedParent")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tracerErrorChildEnded")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                let errorSpan = sim.spans.first { $0.name == "tracer-error" }
                if case .error(let message) = errorSpan?.status {
                    #expect(message.contains("tracer boom"))
                } else {
                    Issue.record("tracer-error span should be marked as an error")
                }
                #expect(errorSpan?.ended == true)

                let parentSpan = sim.spans.first { $0.name == "tracer-parent" }
                #expect(parentSpan?.ended == true)
            }
        }

        @Test func luaFacadeWithSpanPreservesExplicitStatusOnSuccess() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                invalidSpanNameRejected = pcall(function()
                  otel.startSpan("")
                end) == false and pcall(function()
                  otel.withSpan("", function() end)
                end) == false
                result, gap, tail = otel.withSpan("soft-failure", function(span)
                  span:setStatus("error", "application failure")
                  return "handled", nil, "tail"
                end)
                beforeManualFinishDrops = otel.status().droppedRecords
                manualFinishResult = otel.withSpan("manual-finish", function(span)
                  finishReturnedSelf = span:finish() == span
                  duplicateFinishReturnedSelf = span:finish() == span and span:endSpan() == span and span:end_() == span
                  span:addEvent("ignored-after-finish")
                  span:recordException("ignored-after-finish")
                  span:setAttribute("ignored", true)
                  span:setStatus("error", "ignored")
                  otel.addEvent("ignored-module-after-finish", nil, span)
                  otel.recordException("ignored-module-after-finish", nil, nil, span)
                  return "finished"
                end)
                afterManualFinishDrops = otel.status().droppedRecords
                endAliasReturnedSelf = otel.withSpan("manual-end-alias", function(span)
                  return span:end_() == span
                end)
                beforeManualFinishErrorDrops = afterManualFinishDrops
                manualFinishErrorOK = pcall(function()
                  otel.withSpan("manual-finish-error", function(span)
                    span:finish()
                    error("finished failure")
                  end)
                end)
                afterManualFinishErrorDrops = otel.status().droppedRecords
                beforeModuleEndDrops = afterManualFinishErrorDrops
                moduleEndedSpan = otel.startSpan("module-ended")
                moduleEndStartedOpen = moduleEndedSpan.ended == false
                otel.endSpan(moduleEndedSpan)
                moduleEndMarkedEnded = moduleEndedSpan.ended == true
                moduleEndedSpan:addEvent("ignored-after-module-end")
                moduleEndedSpan:recordException("ignored-after-module-end")
                moduleEndedSpan:setAttribute("ignored", true)
                moduleEndedSpan:setStatus("error", "ignored")
                afterModuleEndDrops = otel.status().droppedRecords
                """))

                let span = sim.spans.first { $0.name == "soft-failure" }
                #expect(span?.status == .error("application failure"))
                #expect(span?.ended == true)

                let manuallyFinishedSpan = sim.spans.first { $0.name == "manual-finish" }
                #expect(manuallyFinishedSpan?.ended == true)

                let manuallyFinishedErrorSpan = sim.spans.first { $0.name == "manual-finish-error" }
                #expect(manuallyFinishedErrorSpan?.ended == true)

                let moduleEndedSpan = sim.spans.first { $0.name == "module-ended" }
                #expect(moduleEndedSpan?.ended == true)

                lua_getglobal(L, "invalidSpanNameRejected")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "result")
                #expect(String(cString: lua_tostring(L, -1)) == "handled")
                lua_pop(L, 1)

                lua_getglobal(L, "gap")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "tail")
                #expect(String(cString: lua_tostring(L, -1)) == "tail")
                lua_pop(L, 1)

                lua_getglobal(L, "manualFinishResult")
                #expect(String(cString: lua_tostring(L, -1)) == "finished")
                lua_pop(L, 1)

                lua_getglobal(L, "finishReturnedSelf")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "duplicateFinishReturnedSelf")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "endAliasReturnedSelf")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "beforeManualFinishDrops")
                let beforeManualFinishDrops = lua_tointeger(L, -1)
                lua_pop(L, 1)

                lua_getglobal(L, "afterManualFinishDrops")
                #expect(lua_tointeger(L, -1) == beforeManualFinishDrops)
                lua_pop(L, 1)

                lua_getglobal(L, "manualFinishErrorOK")
                #expect(lua_toboolean(L, -1) == 0)
                lua_pop(L, 1)

                lua_getglobal(L, "moduleEndStartedOpen")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "beforeManualFinishErrorDrops")
                let beforeManualFinishErrorDrops = lua_tointeger(L, -1)
                lua_pop(L, 1)

                lua_getglobal(L, "afterManualFinishErrorDrops")
                #expect(lua_tointeger(L, -1) == beforeManualFinishErrorDrops)
                lua_pop(L, 1)

                lua_getglobal(L, "moduleEndMarkedEnded")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "beforeModuleEndDrops")
                let beforeModuleEndDrops = lua_tointeger(L, -1)
                lua_pop(L, 1)

                lua_getglobal(L, "afterModuleEndDrops")
                #expect(lua_tointeger(L, -1) == beforeModuleEndDrops)
                lua_pop(L, 1)
            }
        }

        @Test func luaFacadeSetAttributeAndStatusMutateActiveSpan() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                otel.setRedactor(function(key, value)
                  if key == "secret" then return nil end
                  return value
                end)
                span = otel.startSpan("active-mutation")
                otel.setAttribute("secret", "drop")
                otel.setAttribute("kept", "yes")
                otel.setStatus("error", "failed")
                explicit = otel.startSpan("explicit-mutation")
                explicit:setAttribute("answer", 42):setStatus("ok")
                explicit:endSpan()
                span:endSpan()
                """))

                let activeSpan = sim.spans.first { $0.name == "active-mutation" }
                #expect(activeSpan?.attributes["secret"] == nil)
                #expect(activeSpan?.attributes["kept"] == "yes")
                #expect(activeSpan?.status == .error("failed"))
                #expect(activeSpan?.ended == true)

                let explicitSpan = sim.spans.first { $0.name == "explicit-mutation" }
                #expect(explicitSpan?.attributes["answer"] == "42")
                #expect(explicitSpan?.status == .ok)
                #expect(explicitSpan?.ended == true)
            }
        }

        @Test func luaFacadeHonorsDisabledBaggagePropagator() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true, propagators = { "tracecontext" } })
                otel.setBaggage("tenant", "blue")
                headers = otel.inject({ BaGgAgE = "stale=yes" })
                otel.clearBaggage()
                otel.extract({ baggage = "user=ada" })
                diagnostics = otel.diagnostics()
                """))

                lua_getglobal(L, "headers")
                lua_getfield(L, -1, "baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)
                lua_getfield(L, -1, "BaGgAgE")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "diagnostics")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeHonorsMapStylePropagatorConfig() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({
                  enabled = true,
                  propagators = { tracecontext = true, baggage = false },
                })
                span = otel.startSpan("map-propagator")
                otel.setBaggage("tenant", "blue")
                headers = otel.inject({})
                """))

                lua_getglobal(L, "headers")
                lua_getfield(L, -1, "traceparent")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                lua_pop(L, 1)
                lua_getfield(L, -1, "baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeReconfigureRestoresDefaultPropagators() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true, propagators = { tracecontext = true, baggage = false } })
                disabledSpan = otel.startSpan("restricted")
                otel.setBaggage("tenant", "blue")
                disabledHeaders = otel.inject({})
                disabledSpan:endSpan({ code = "ok" })
                otel.configure({ enabled = true })
                restoredSpan = otel.startSpan("restored")
                restoredHeaders = otel.inject({})
                restoredSpan:endSpan({ code = "ok" })
                """))

                lua_getglobal(L, "disabledHeaders")
                lua_getfield(L, -1, "traceparent")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                lua_pop(L, 1)
                lua_getfield(L, -1, "baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "restoredHeaders")
                lua_getfield(L, -1, "traceparent")
                #expect(lua_type(L, -1) == LUA_TSTRING)
                lua_pop(L, 1)
                lua_getfield(L, -1, "baggage")
                #expect(String(cString: lua_tostring(L, -1)).contains("tenant=blue"))
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeInjectReplacesStaleTraceContextHeaders() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                withoutSpan = otel.inject({
                  TraceParent = "00-00000000000000000000000000000001-0000000000000042-01",
                  TRACESTATE = "vendor=stale",
                })
                span = otel.startSpan("carrier")
                withSpan = otel.inject({
                  TraceParent = "00-00000000000000000000000000000001-0000000000000042-01",
                  TraceState = "vendor=stale",
                })
                span:endSpan({ code = "ok" })
                otel.configure({ enabled = true, propagators = { baggage = true, tracecontext = false } })
                disabled = otel.inject({
                  traceparent = "00-00000000000000000000000000000001-0000000000000042-01",
                  TrAcEsTaTe = "vendor=stale",
                })
                withoutSpanClean = withoutSpan.traceparent == nil and withoutSpan.TraceParent == nil and withoutSpan.TRACESTATE == nil
                withSpanTraceparent = withSpan.traceparent
                withSpanClean = withSpan.TraceParent == nil and withSpan.TraceState == nil
                disabledClean = disabled.traceparent == nil and disabled.TrAcEsTaTe == nil
                """))

                lua_getglobal(L, "withoutSpanClean")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "withSpanTraceparent")
                #expect(String(cString: lua_tostring(L, -1)).hasPrefix("00-"))
                lua_pop(L, 1)

                lua_getglobal(L, "withSpanClean")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "disabledClean")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)
            }
        }

        @Test func luaFacadeExtractReplacesBaggageContext() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                otel.setBaggage("tenant", "blue")
                otel.extract({})
                afterMissing = otel.diagnostics()
                otel.setBaggage("tenant", "blue")
                otel.extract({ BaGgAgE = "user=ada" })
                afterRemote = otel.diagnostics()
                remoteBaggage = otel.getBaggage()
                """))

                lua_getglobal(L, "afterMissing")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 0)
                lua_pop(L, 2)

                lua_getglobal(L, "afterRemote")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 2)

                lua_getglobal(L, "remoteBaggage")
                lua_getfield(L, -1, "user")
                #expect(String(cString: lua_tostring(L, -1)) == "ada")
                lua_pop(L, 1)
                lua_getfield(L, -1, "tenant")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeInjectReplacesStaleCarrierBaggage() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                cleared = otel.inject({ baggage = "stale=yes", Baggage = "also=stale", BAGGAGE = "upper=stale" })
                otel.setBaggage("tenant", "blue")
                replaced = otel.inject({ baggage = "stale=yes", Baggage = "also=stale", BAGGAGE = "upper=stale" })
                """))

                lua_getglobal(L, "cleared")
                lua_getfield(L, -1, "baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)
                lua_getfield(L, -1, "Baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)
                lua_getfield(L, -1, "BAGGAGE")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "replaced")
                lua_getfield(L, -1, "baggage")
                #expect(String(cString: lua_tostring(L, -1)).contains("tenant=blue"))
                lua_pop(L, 1)
                lua_getfield(L, -1, "Baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)
                lua_getfield(L, -1, "BAGGAGE")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeValidatesBaggageKeys() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                validOK = pcall(function() otel.setBaggage("tenant-id_1", "blue") end)
                invalidSpaceOK = pcall(function() otel.setBaggage("tenant id", "bad") end)
                invalidSeparatorOK = pcall(function() otel.setBaggage("tenant,id", "bad") end)
                otel.setBaggage("line", "hello\\nworld")
                otel.setBaggage("removed", "present")
                otel.setBaggage("removed", nil)
                removedValue = otel.getBaggage("removed")
                extracted = otel.extract({ baggage = "bad@key=ignored,good-key=kept,encoded=hello%2cworld%3Bnext%20value%25done" })
                otel.setBaggage("line", "hello\\nworld")
                incoming = otel.getBaggage()
                headers = otel.inject({})
                otel.setBaggage("encoded", nil)
                otel.setBaggage("good-key", nil)
                otel.setBaggage("line", nil)
                emptyHeaders = otel.inject({})
                otel.extract(headers)
                roundTripLine = otel.getBaggage("line")
                """))

                lua_getglobal(L, "validOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "invalidSpaceOK")
                #expect(lua_toboolean(L, -1) == 0)
                lua_pop(L, 1)

                lua_getglobal(L, "invalidSeparatorOK")
                #expect(lua_toboolean(L, -1) == 0)
                lua_pop(L, 1)

                lua_getglobal(L, "incoming")
                lua_getfield(L, -1, "good-key")
                #expect(String(cString: lua_tostring(L, -1)) == "kept")
                lua_pop(L, 1)
                lua_getfield(L, -1, "encoded")
                #expect(String(cString: lua_tostring(L, -1)) == "hello,world;next value%done")
                lua_pop(L, 1)
                lua_getfield(L, -1, "bad@key")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "removedValue")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "headers")
                lua_getfield(L, -1, "baggage")
                let header = String(cString: lua_tostring(L, -1))
                #expect(header.contains("encoded=hello%2Cworld%3Bnext%20value%25done"))
                #expect(header.contains("good-key=kept"))
                #expect(header.contains("line=hello%0Aworld"))
                #expect(!header.contains("hello,world;next value%done"))
                #expect(!header.contains("bad@key"))
                #expect(!header.contains("hello\nworld"))
                lua_pop(L, 2)

                lua_getglobal(L, "emptyHeaders")
                lua_getfield(L, -1, "baggage")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "roundTripLine")
                #expect(String(cString: lua_tostring(L, -1)) == "hello\nworld")
                lua_pop(L, 1)
            }
        }

        @Test func luaFacadeShutdownFlushesNativePipeline() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                span = otel.startSpan("facade-shutdown")
                shutdownOK = otel.shutdown(1)
                diagnostics = otel.diagnostics()
                """))

                #expect(sim.shutdownCount == 1)
                #expect(sim.flushCount == 1)

                lua_getglobal(L, "shutdownOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "diagnostics")
                lua_getfield(L, -1, "activeSpanID")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadePreservesLocalStateAcrossShutdownAndDisableConfigure() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                otel.setBaggage("tenant", "blue")
                otel.setRedactor(function(key, value)
                  if key == "secret" then return nil end
                  return value
                end)
                shutdownOK = otel.shutdown(1)
                afterShutdownBaggage = otel.getBaggage("tenant")
                afterShutdownDiagnostics = otel.diagnostics()
                disableOK = otel.configure({ enabled = false })
                afterDisableBaggage = otel.getBaggage("tenant")
                afterDisableDiagnostics = otel.diagnostics()
                """))

                lua_getglobal(L, "shutdownOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "disableOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "afterShutdownBaggage")
                #expect(String(cString: lua_tostring(L, -1)) == "blue")
                lua_pop(L, 1)

                lua_getglobal(L, "afterDisableBaggage")
                #expect(String(cString: lua_tostring(L, -1)) == "blue")
                lua_pop(L, 1)

                lua_getglobal(L, "afterShutdownDiagnostics")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "redactorInstalled")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 2)

                lua_getglobal(L, "afterDisableDiagnostics")
                lua_getfield(L, -1, "baggageCount")
                #expect(lua_tointeger(L, -1) == 1)
                lua_pop(L, 1)
                lua_getfield(L, -1, "redactorInstalled")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 2)
            }
        }

        @Test func luaFacadeWrapPropagatesContextIntoCoroutine() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                otel = assert(loadfile('\(luaPath)'))()
                otel.configure({ enabled = true })
                parent = otel.startSpan("parent")
                otel.setBaggage("tenant", "blue")
                wrapped = otel.wrap(function()
                  childBaggage = otel.getBaggage("tenant")
                  otel.withSpan("child", function() end)
                  return "wrapped-result", nil, "wrapped-tail"
                end)
                errorWrapped = otel.wrap(function()
                  errorBaggage = otel.getBaggage("tenant")
                  error("wrapped failure")
                end)
                co = coroutine.create(wrapped)
                parentID = parent.id
                parent:endSpan({ code = "ok" })
                otel.setBaggage("tenant", "green")
                resumeOK, wrappedResult, wrappedNil, wrappedTail = coroutine.resume(co)
                afterWrappedBaggage = otel.getBaggage("tenant")
                errorOK = pcall(errorWrapped)
                afterErrorBaggage = otel.getBaggage("tenant")
                """))

                let parentSpan = sim.spans.first { $0.name == "parent" }
                let childSpan = sim.spans.first { $0.name == "child" }
                #expect(parentSpan?.ended == true)
                #expect(childSpan?.parentSpanID == parentSpan?.id)
                #expect(childSpan?.ended == true)

                lua_getglobal(L, "childBaggage")
                #expect(String(cString: lua_tostring(L, -1)) == "blue")
                lua_pop(L, 1)

                lua_getglobal(L, "resumeOK")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "wrappedResult")
                #expect(String(cString: lua_tostring(L, -1)) == "wrapped-result")
                lua_pop(L, 1)

                lua_getglobal(L, "wrappedNil")
                #expect(lua_isnil(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "wrappedTail")
                #expect(String(cString: lua_tostring(L, -1)) == "wrapped-tail")
                lua_pop(L, 1)

                lua_getglobal(L, "afterWrappedBaggage")
                #expect(String(cString: lua_tostring(L, -1)) == "green")
                lua_pop(L, 1)

                lua_getglobal(L, "errorOK")
                #expect(lua_toboolean(L, -1) == 0)
                lua_pop(L, 1)

                lua_getglobal(L, "errorBaggage")
                #expect(String(cString: lua_tostring(L, -1)) == "blue")
                lua_pop(L, 1)

                lua_getglobal(L, "afterErrorBaggage")
                #expect(String(cString: lua_tostring(L, -1)) == "green")
                lua_pop(L, 1)
            }
        }

        @Test func luaFacadeCanSaveAndLoadConfig() {
            withModuleLoaded(luaopen_hs_libopentelemetry) { L in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                let luaPath = otelTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "'", with: "\\'")

                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settingsNative")

                #expect(luaEval(L, """
                hs = {}
                local native = mod
                package.preload["hs.libopentelemetry"] = function() return native end
                package.preload["hs.settings"] = function() return settingsNative end
                otel = assert(loadfile('\(luaPath)'))()
                config = {
                  enabled = true,
                  serviceName = "saved-service",
                  attributeLimits = { maxCount = 3 },
                }
                saved = otel.saveConfig(config)
                config.serviceName = "mutated-service"
                config.attributeLimits.maxCount = 99
                otel.configure({ enabled = false, serviceName = "changed-service" })
                loaded = otel.loadConfig()
                """))

                #expect(sim.configuration.enabled)
                #expect(sim.configuration.serviceName == "saved-service")
                #expect(sim.configuration.attributeLimits["maxCount"] == 3)

                lua_getglobal(L, "saved")
                #expect(lua_toboolean(L, -1) != 0)
                lua_pop(L, 1)

                lua_getglobal(L, "loaded")
                lua_getfield(L, -1, "serviceName")
                #expect(String(cString: lua_tostring(L, -1)) == "saved-service")
                lua_pop(L, 2)
            }
        }
    }
}

private let otelTestRepoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}()
