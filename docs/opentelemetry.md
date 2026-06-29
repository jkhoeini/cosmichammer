# OpenTelemetry

Cosmic Hammer exposes OpenTelemetry through the always-available `hs.opentelemetry` Lua table. Telemetry is disabled by default and only exports after explicit Lua configuration.

## Minimal Local Setup

Use the console exporter first when developing automation:

```lua
hs.opentelemetry.configure({
  enabled = true,
  serviceName = "cosmichammer-local",
  exporter = "console",
  traces = true,
  logs = true,
  metrics = true,
  callbackSampleRates = {
    ["hs.eventtap"] = 0.01,
    ["hs.sqlite3.progressHandler"] = 0,
  },
  attributeLimits = {
    maxCount = 64,
    maxValueLength = 4096,
  },
})
```

For a local OTLP collector:

```lua
hs.opentelemetry.configure({
  enabled = true,
  serviceName = "cosmichammer-local",
  exporter = "otlp",
  protocol = "http/protobuf",
  endpoint = "http://localhost:4318",
})
```

`endpoint` is expanded to `/v1/traces`, `/v1/logs`, and `/v1/metrics` for OTLP HTTP/protobuf. Use `tracesEndpoint`, `logsEndpoint`, or `metricsEndpoint` to override individual HTTP signal destinations.

The current build also supports SDK-backed OTLP/gRPC. gRPC endpoints use host/port service addresses such as `http://localhost:4317` for plaintext local collectors or `https://collector.example:4317` for TLS. Path-bearing gRPC endpoints are rejected with a deterministic diagnostic because gRPC does not use `/v1/*` URL paths.

Use `headers = { ["x-api-key"] = "..." }` for OTLP HTTP headers or gRPC metadata. `compression` defaults to `gzip`; set it to `deflate` or to `none`/`identity`/`off`/`false` to control request compression.

```lua
hs.opentelemetry.configure({
  enabled = true,
  serviceName = "cosmichammer-local",
  exporter = "otlp",
  protocol = "grpc",
  endpoint = "http://localhost:4317",
  traces = true,
  logs = true,
  metrics = true,
})
```

Run the opt-in local collector check with:

```sh
COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 just otel-grpc-integration
```

The script starts a pinned OpenTelemetry Collector image on this machine using `Tests/Fixtures/otel-collector-grpc.yaml`, runs only `OpenTelemetryGRPCIntegrationTests`, and checks the collector file exporter for trace, log, and metric records. It is not part of `just verify`. If the default ports are busy, set `COSMIC_HAMMER_OTEL_GRPC_PORT` or `COSMIC_HAMMER_OTEL_COLLECTOR_HEALTH_PORT`.

`propagators` defaults to `{ "tracecontext", "baggage" }`. Set it to a smaller list, `{}`, or a boolean map like `{ tracecontext = true, baggage = false }` to control which propagation headers `hs.opentelemetry.inject()` and `extract()` use.

`captureLogger = false` suppresses automatic `hs.logger` / native logger message export. `capturePrint = "off"` suppresses automatic `print()` / `hs._logmessage` export; set it to another value only when you want print output exported as logs.

`hs.opentelemetry.setBaggage(key, value)` accepts W3C token-style baggage keys; keys containing whitespace, commas, semicolons, or other invalid separators are rejected, and malformed incoming baggage keys are ignored during extraction. Baggage values are percent-encoded when injected so separators and control characters do not appear raw in outbound headers.

Use `hs.opentelemetry.saveConfig(config)` to apply and persist a Lua configuration table with `hs.settings`, then call `hs.opentelemetry.loadConfig()` from `init.lua` to restore it. Explicit Lua config remains the source of truth; persistence is only a convenience for user-managed preferences.

## Local LGTM Stack

For local trace/log/metric inspection without signing up for an external collector, run Grafana's all-in-one LGTM image:

```sh
docker run --rm -p 3000:3000 -p 4317:4317 -p 4318:4318 --name cosmichammer-lgtm grafana/otel-lgtm:latest
```

Then configure Cosmic Hammer for OTLP HTTP:

```lua
hs.opentelemetry.configure({
  enabled = true,
  serviceName = "cosmichammer-local",
  exporter = "otlp",
  protocol = "http/protobuf",
  endpoint = "http://localhost:4318",
  traces = true,
  logs = true,
  metrics = true,
})
```

Open Grafana at `http://localhost:3000`. Use Tempo for traces, Loki for logs, and Prometheus/Mimir-compatible metrics panels for runtime metrics. Call `hs.opentelemetry.flush(5)` before stopping the container so buffered records are exported.

Use `hs.opentelemetry.shutdown([timeout])` when a test or reload workflow needs to flush and terminate the telemetry pipeline explicitly.

## API Shape

```lua
local otel = hs.opentelemetry

otel.setRedactor(function(key, value)
  if key:find("token") or key:find("password") then return nil end
  return value
end)

otel.setBaggage("automation", "window-rules")

local rulesApplied = otel.meter("window-rules"):counter("window_rules_applied", { unit = "1" })

otel.withSpan("apply-window-rules", {
  attributes = { ["rule.count"] = 12 },
}, function(span)
  span:setAttribute("rules.target", "frontmost")
  span:addEvent("rules.selected", { count = 12 })
  rulesApplied:add(12, { result = "success" })
  span:setStatus("ok")
end)

local deferred = otel.wrap(function()
  otel.withSpan("deferred-window-work", function()
    -- Runs later, but still links back to the span that created `deferred`.
    -- The caller's previous context is restored after this function returns or errors.
  end)
end)
coroutine.resume(coroutine.create(deferred))
```

Span helpers such as `otel.startSpan(...)`, `otel.withSpan(...)`, and tracer-created spans require non-empty span names. Span object methods return the span object for fluent use, including `span:endSpan()`, `span:finish()`, and `span:end_()`. Span objects expose `span.ended`, which starts as `false` and flips to `true` after the span ends. Once a span object has ended, later span-object events, exceptions, attributes, and status updates are ignored so cleanup paths do not create duplicate dropped-record diagnostics.

Tracer and meter facades require non-empty instrumentation names, for example `otel.tracer("window-rules")` and `otel.meter("window-rules")`.

Meter instruments returned by `meter:counter(...)`, `meter:upDownCounter(...)`, `meter:gauge(...)`, and `meter:histogram(...)` require a non-empty metric name and expose lightweight `name`, `kind`, and `unit` fields for debugging Lua telemetry setup. Instrument `:add(...)` and `:record(...)` methods return the instrument object for fluent use.

Counters and up/down counters record integer values: fractional inputs are rounded (`counter:add(0.4)` records `0`), and counters clamp negative inputs to `0`. Gauges and histograms record the value as a double (histograms clamp negatives to `0`). Use gauges or histograms when you need fractional magnitudes.

## Automatic Instrumentation

Current automatic coverage includes:

- Lua runtime boot/shutdown and existing `CHTrace` intervals.
- Lua lifecycle metrics for init duration, init count, reload count, and shutdown count.
- Telemetry runtime metrics for flush duration, flush count, active spans, and dropped records.
- Active timer, hotkey, task, websocket connection, IPC local port, network ping echo request, network ping process, AX observer watcher, Bonjour browser, Bonjour service monitor, Bonjour service publish, Bonjour service resolve, canvas mouse callback, canvas dragging callback, chooser callback, dialog color callback, dialog webview alert callback, location watcher, menubar click callback, menubar dynamic menu callback, menubar menu item callback, notify userdata, osascript execution, Razer discovery callback, Razer button callback, sharing callback, sound callback, SQLite hook callback, SQLite SQL function callback, serial device watcher, Stream Deck discovery callback, Stream Deck button callback, Stream Deck encoder callback, Stream Deck screen callback, uielement watcher, webview usercontent callback, webview toolbar callback, webview window callback, webview navigation callback, webview policy callback, webview SSL callback, webview `evaluateJavaScript` callback, pathwatcher, pasteboard watcher, application watcher, screen watcher, spaces watcher, caffeinate watcher, filesystem volume watcher, distributed notification watcher, keycodes watcher, battery watcher, wifi watcher, network reachability watcher, network configuration watcher, audiodevice watcher, USB watcher, host locale observer, HTTP server listener, and camera device watcher gauge metrics.
- `print`, `hs.logger`, and native `HSLogger` records.
- Timer, hotkey, and task callbacks; timer callbacks inherit the active trace context captured when the timer is scheduled. For user-managed coroutines or deferred functions, wrap the function with `hs.opentelemetry.wrap(fn)` while the parent span is active; the wrapped function restores the caller's previous context after it returns or errors.
- `hs.task` execution spans with trace context injected into child process environment.
- `hs.window` UI automation action spans for mutating operations like raise, close, minimize, zoom, and geometry changes.
- `hs` CLI evaluations as server spans; when the CLI inherits `traceparent` or `baggage`, those headers are sent to the app before command evaluation.
- `hs.http` client spans with W3C `traceparent` injection.
- `hs.httpserver` request spans with W3C `traceparent` extraction.
- AppleScript permission enablement audit logs, plus accessibility, screen recording, microphone, and camera permission check audit logs.

## Automatic Semantic Attributes

Automatic instrumentation uses OpenTelemetry semantic convention names where available, and prefixes Cosmic Hammer-specific dimensions with `cosmichammer.*` to keep them distinct from standard attributes.

- Process spans use `process.executable.path`, `process.args_count`, `process.working_directory`, and `process.exit.code`. Shell-only details use `cosmichammer.process.command.length`, `cosmichammer.process.shell.user_env`, and `cosmichammer.process.exit.type`.
- Lua runtime spans use `cosmichammer.lua.module`, `cosmichammer.lua.source`, `cosmichammer.lua.command.length`, `cosmichammer.lua.config.has_init`, `cosmichammer.lua.setup.path`, and `cosmichammer.lua.completion.prefix.length`.
- CLI and IPC spans use `cosmichammer.cli.instance_id` and `cosmichammer.ipc.message_id`.
- Permission audit logs use `cosmichammer.permission.name`, `cosmichammer.permission.enabled`, `cosmichammer.permission.status`, and `cosmichammer.permission.prompted`.
- Window automation spans use `cosmichammer.ui.system`, `cosmichammer.ui.action`, `cosmichammer.ui.action.success`, and `cosmichammer.window.id`.
- HTTP client/server spans use standard HTTP, URL, server, and client attributes such as `http.request.method`, `http.response.status_code`, `url.full`, `url.scheme`, `url.path`, `server.address`, `server.port`, `client.address`, and `client.port`. Error spans include `error.type` when Cosmic Hammer can classify the failure.

## Privacy And Cardinality

Keep telemetry opt-in in user config. Do not export secrets, full file contents, access tokens, or high-cardinality metric attributes. Use `hs.opentelemetry.setRedactor(fn)` for user-provided attributes and prefer low-cardinality metric labels like `result`, `kind`, or `extension`.

Trace attributes may include URLs and paths because they are useful during debugging; metric attributes should not. When in doubt, place detailed values on span events after redaction, not on metrics.

## Performance Notes

The disabled path is designed to be cheap. When enabled, spans and logs are batched by the OpenTelemetry SDK. Very high-frequency callbacks such as `hs.eventtap` and SQLite engine hooks are wrapped but sampled out by default; opt in with `callbackSampleRates`, where `1.0` records every callback, `0.01` records roughly one in 100 callbacks, and `0` disables spans for that callback.

Use `hs.opentelemetry.flush([timeout])` before shutting down external collectors in local tests. A flush records `cosmichammer.telemetry.flush.duration`, `cosmichammer.telemetry.flush.count`, `cosmichammer.telemetry.spans.active`, `cosmichammer.telemetry.records.dropped`, and `cosmichammer.telemetry.attributes.dropped`.

`records.dropped` (and the `droppedRecords` status counter) count whole spans, events, exceptions, logs, or metrics that could not be recorded — for example events on an already-ended span, or records shed under exporter backpressure. Attribute-level drops from `attributeLimits` (attributes beyond `maxCount` and values truncated past `maxValueLength`) are counted separately as `attributes.dropped` (and the `droppedAttributes` status counter) so ordinary attribute limiting does not inflate the dropped-records signal.

`hs.opentelemetry.status()` returns native exporter configuration and counters, including `lastFlushResult`, `lastShutdownResult`, `lastExporterFailureKind`, `exporterFailureCount`, `flushFailureCount`, `shutdownFailureCount`, `backpressureDroppedRecords`, `exporterQueueCapacity`, `exporterMaxExportBatchSize`, `exporterScheduleDelay`, `exporterTimeout`, and `lastExportDuration`. `lastExportDuration` is the duration of the last explicit flush/export cycle. `exporterQueueDepth` is currently `nil`: the Swift OpenTelemetry SDK does not expose true processor queue depth through public API, so Cosmic Hammer reports configured capacity and observable failure/backpressure stats instead of guessing. `hs.opentelemetry.diagnostics()` adds Lua facade details like baggage count and whether a redactor is installed.

## OTEL Benchmarks

The benchmark runner is an opt-in SwiftPM executable product, `OTELBenchmarks`. It creates a fresh Lua state, attaches the deterministic simulator environment, registers the native OTEL module as `otel`, and runs checked-in Lua workloads from `Benchmarks/otel/`. Script loading happens outside the measured loop; each sample reports raw `ns/op`, empty-loop baseline-adjusted `ns/op`, RSS deltas, and telemetry counters.

Use release builds for numbers that matter:

```sh
just bench-otel
just bench-otel disabled 25000 7
just bench-otel-smoke
just bench-otel-full
```

The lower-level runner is useful while iterating on a specific workload:

```sh
SDK_PATH="$(xcrun --show-sdk-path)"
swift run -c release -Xlinker -F -Xlinker "$SDK_PATH/System/Library/PrivateFrameworks" OTELBenchmarks --suite smoke --iterations 10000 --samples 5 --output pretty
swift run -c release -Xlinker -F -Xlinker "$SDK_PATH/System/Library/PrivateFrameworks" OTELBenchmarks --suite all --iterations 50000 --samples 10 --output json
```

Suites are `smoke`, `baseline`, `disabled`, `enabled`, `callbacks`, and `all`. Use `--telemetry simulated` for deterministic simulator-backed numbers and `--telemetry production` for local SDK-path spot checks. JSON-producing recipes write under `build/otel-benchmarks/` so local runs can be compared or archived without becoming pass/fail checks.

Benchmark numbers are advisory. Treat regressions as a prompt to investigate rather than an automatic product failure. For macOS noise, record power mode, thermal state, background load, Spotlight indexing, and whether the machine was on battery. Prefer medians and p90 over a single run.

## Local Verification

The default local verification gate remains `just verify`. It covers generated files, docs linting, app build, and deterministic Swift tests. OTEL's deterministic simulator-backed tests should stay in that default path; slower or infrastructure-backed OTEL checks are explicit local opt-ins.

Focused OTEL commands:

```sh
just otel-test
just otel-conformance
OTEL_BENCHMARK_TESTS=1 just otel-benchmark
OTEL_COLLECTOR_TESTS=1 just otel-collector-test
OTEL_STRESS_TESTS=1 just otel-stress-test
COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 just otel-grpc-integration
just otel-local-checks
```

Policy:

- `just verify` is the only default local gate and should stay stable for normal contributors.
- `just otel-test` is focused deterministic coverage for OTEL functional behavior and benchmark support smoke checks.
- `just otel-conformance` runs deterministic W3C tracecontext/baggage conformance and OTLP golden export tests.
- `just bench-otel-smoke`, `OTEL_BENCHMARK_TESTS=1 just otel-benchmark`, and `just bench-otel-full` are advisory local performance checks that write JSON under `build/otel-benchmarks/`.
- `OTEL_COLLECTOR_TESTS=1 just otel-collector-test` runs the local Docker-backed collector integration check.
- `COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 just otel-grpc-integration` starts a local collector and runs the gRPC integration suite.
- `OTEL_STRESS_TESTS=1 just otel-stress-test` is opt-in until reload/lifecycle stress runtime and flake rates are known.
- `just otel-local-checks` runs `just verify`, focused OTEL tests, and conformance smoke by default; benchmark, collector, stress, and gRPC integration checks run only when their environment opt-ins are set.

## Troubleshooting

- If no records appear in Grafana, confirm `hs.opentelemetry.diagnostics().enabled == true` and that `exporter` is `otlp`.
- If `lastExportError` is set for HTTP/protobuf, check the collector endpoint, port `4318`, and `/v1/*` paths. For gRPC, check port `4317`, use `http://host:port` or `https://host:port`, and do not include `/v1/*` paths.
- If high-frequency callbacks are missing, check `callbackSampleRates`; `hs.eventtap` and SQLite engine hooks are sampled out by default.
- If logs appear without expected trace correlation, confirm the work runs inside `hs.opentelemetry.withSpan(...)` or one of the automatically instrumented callbacks.
- If shutdown drops recent records, call `hs.opentelemetry.flush(5)` before stopping the collector or reloading the config.
