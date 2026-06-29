local otel = hs.opentelemetry

otel.setRedactor(function(key, value)
  local lowered = tostring(key):lower()
  if lowered:find("token", 1, true) or lowered:find("password", 1, true) then
    return nil
  end
  return value
end)

otel.configure({
  enabled = true,
  serviceName = "cosmichammer-local",
  exporter = "console",
  protocol = "http/protobuf",
  endpoint = "http://localhost:4318",
  traces = true,
  logs = true,
  metrics = true,
  captureLogger = true,
  capturePrint = "off",
  callbackSampleRates = {
    ["hs.eventtap"] = 0.01,
    ["hs.sqlite3.exec"] = 0.1,
  },
  attributeLimits = {
    maxCount = 64,
    maxValueLength = 4096,
  },
  resourceAttributes = {
    ["deployment.environment.name"] = "local",
  },
  batch = {
    scheduleDelay = 2,
    maxQueueSize = 2048,
    maxExportBatchSize = 256,
  },
})

-- Optional local OTLP/gRPC collector configuration:
-- otel.configure({
--   enabled = true,
--   serviceName = "cosmichammer-local",
--   exporter = "otlp",
--   protocol = "grpc",
--   endpoint = "http://localhost:4317",
--   traces = true,
--   logs = true,
--   metrics = true,
-- })

otel.setBaggage("automation.owner", "local-user")

local log = hs.logger.new("otel-sample", "debug")
local meter = otel.meter("sample")
local runs = meter:counter("cosmichammer.sample.runs", { unit = "1" })

otel.withSpan("sample-startup", {
  attributes = {
    ["cosmichammer.automation.name"] = "otel-sample",
  },
}, function(span)
  log.i("OpenTelemetry sample startup")
  span:addEvent("startup.ready")
  runs:add(1, { result = "success" })
end)

_G.otelSampleHeartbeatTimer = hs.timer.doEvery(60, function()
  otel.withSpan("sample-heartbeat", function(span)
    span:addEvent("heartbeat")
    otel.log("info", "heartbeat", { source = "opentelemetry-init.lua" })
  end)
end)
