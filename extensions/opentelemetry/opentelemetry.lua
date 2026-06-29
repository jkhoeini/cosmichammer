--- === hs.opentelemetry ===
---
--- OpenTelemetry support for Cosmic Hammer

local native = require("hs.libopentelemetry")

local module = {}
local spanMT = {}
local baggage = {}
local activePropagators = { tracecontext = true, baggage = true }
local redactor = nil
local configSettingsKey = "hs.opentelemetry.config"
local lastConfig = nil

local nativeConfigure = native.configure

local function spanID(span)
  if type(span) == "table" then
    return span.id
  end
  return span
end

local function spanEnded(span)
  return type(span) == "table" and span.ended == true
end

local function validateName(name, label, level)
  if type(name) ~= "string" or name == "" then
    error("expected " .. label, level or 3)
  end
end

local function redactAttributes(attributes)
  if redactor == nil or type(attributes) ~= "table" then
    return attributes or {}
  end

  local redacted = {}
  for key, value in pairs(attributes) do
    local ok, newValue = pcall(redactor, key, value)
    if ok and newValue ~= nil then
      redacted[key] = newValue
    elseif not ok then
      redacted[key] = "<redaction error>"
    end
  end
  return redacted
end

local function redactOptions(options)
  -- Fast path: with no redactor installed, redactAttributes is a no-op, so there
  -- is nothing to copy. This keeps per-call allocation off the common (and
  -- disabled) paths, e.g. the require() instrumentation wrapper.
  if redactor == nil then
    return options or {}
  end
  options = options or {}
  local copy = {}
  for key, value in pairs(options) do
    copy[key] = value
  end
  copy.attributes = redactAttributes(copy.attributes)
  return copy
end

local function encodeBaggageValue(value)
  return tostring(value)
      :gsub("%%", "%%25")
      :gsub("[%c\127]", function(char)
        return string.format("%%%02X", string.byte(char))
      end)
      :gsub(",", "%%2C")
      :gsub(";", "%%3B")
      :gsub(" ", "%%20")
end

local function decodeBaggageValue(value)
  return tostring(value):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

local function validBaggageKey(key)
  return type(key) == "string" and key ~= "" and key:match("^[A-Za-z0-9!#$%%&'*+%.^_`|~%-]+$") ~= nil
end

local function baggageHeader()
  local parts = {}
  for key, value in pairs(baggage) do
    if validBaggageKey(key) then
      parts[#parts + 1] = tostring(key) .. "=" .. encodeBaggageValue(value)
    end
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function carrierHeaderValue(carrier, headerName)
  if type(carrier) ~= "table" then
    return nil
  end
  local normalized = tostring(headerName):lower()
  for key, value in pairs(carrier) do
    if tostring(key):lower() == normalized then
      return value
    end
  end
  return nil
end

local function clearCarrierHeader(carrier, headerName)
  if type(carrier) ~= "table" then
    return
  end
  local normalized = tostring(headerName):lower()
  for key in pairs(carrier) do
    if tostring(key):lower() == normalized then
      carrier[key] = nil
    end
  end
end

local function clearTraceContextHeaders(carrier)
  clearCarrierHeader(carrier, "traceparent")
  clearCarrierHeader(carrier, "tracestate")
end

local function installBaggageHeader(carrier)
  local header = baggageHeader()
  clearCarrierHeader(carrier, "baggage")
  if header ~= "" then
    carrier.baggage = header
  end
  return carrier
end

local function extractBaggageHeader(carrier)
  baggage = {}
  local header = carrierHeaderValue(carrier, "baggage")
  if type(header) ~= "string" then
    return
  end
  for item in header:gmatch("[^,]+") do
    local key, value = item:match("^%s*([^=;,%s]+)%s*=%s*([^;,%s]*)")
    if key and validBaggageKey(key) then
      baggage[key] = decodeBaggageValue(value)
    end
  end
end

local function setActivePropagators(config)
  activePropagators = {}
  local propagators = config.propagators or { "tracecontext", "baggage" }
  if type(propagators) ~= "table" then
    propagators = { "tracecontext", "baggage" }
  end
  for key, value in pairs(propagators) do
    local name = value
    if type(value) == "boolean" then
      name = value and key or nil
    end
    if name ~= nil then
      activePropagators[tostring(name):lower():gsub("%-", "")] = true
    end
  end
end

local function propagatorEnabled(name)
  return activePropagators[tostring(name):lower():gsub("%-", "")] == true
end

local function spanObject(id, name)
  if id == nil then
    return nil
  end
  return setmetatable({ id = id, name = name, ended = false }, spanMT)
end

local function copyConfig(value, seen)
  local valueType = type(value)
  if valueType ~= "table" then
    if valueType == "function" or valueType == "userdata" or valueType == "thread" then
      error("configuration contains unsupported value type: " .. valueType, 3)
    end
    return value
  end

  seen = seen or {}
  if seen[value] then
    error("configuration contains a cycle", 3)
  end
  seen[value] = true

  local copy = {}
  for key, child in pairs(value) do
    copy[copyConfig(key, seen)] = copyConfig(child, seen)
  end
  seen[value] = nil
  return copy
end

--- hs.opentelemetry.configure(config) -> bool
--- Function
--- Configures OpenTelemetry export from Lua.
---
--- Parameters:
---  * config - table containing telemetry configuration. Set `enabled = true` to activate export.
---    Optional `callbackSampleRates` maps callback names (or `"*"`) to rates from `0` to `1`.
---    Optional `attributeLimits` sets `maxCount` and `maxValueLength` for exported attributes.
---    Optional `propagators` accepts a list like `{ "tracecontext" }` or a boolean map like `{ tracecontext = true, baggage = false }`.
---
--- Returns:
---  * `true` when configuration was accepted.
function module.configure(config)
  if type(config) ~= "table" then
    error("expected config table", 2)
  end
  local configCopy = copyConfig(config)
  local ok = nativeConfigure(config)
  if ok then
    lastConfig = configCopy
    setActivePropagators(configCopy)
  end
  return ok
end

--- hs.opentelemetry.saveConfig([config]) -> bool
--- Function
--- Saves an OpenTelemetry configuration table with `hs.settings`.
---
--- Parameters:
---  * config - optional configuration table. When provided, it is applied before saving.
---
--- Returns:
---  * `true` when a configuration was saved; otherwise `false`.
function module.saveConfig(config)
  if config ~= nil then
    module.configure(config)
  end
  if lastConfig == nil then
    return false
  end
  require("hs.settings").set(configSettingsKey, copyConfig(lastConfig))
  return true
end

--- hs.opentelemetry.loadConfig() -> table | nil
--- Function
--- Loads and applies a saved OpenTelemetry configuration table from `hs.settings`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The loaded configuration table, or nil when no saved configuration exists.
function module.loadConfig()
  local config = require("hs.settings").get(configSettingsKey)
  if type(config) ~= "table" then
    return nil
  end
  module.configure(config)
  return copyConfig(config)
end

--- hs.opentelemetry.status() -> table
--- Function
--- Returns the current telemetry status counters and exporter configuration.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table describing the current telemetry configuration and counters.
function module.status()
  return native.status()
end

--- hs.opentelemetry.withSpan(name[, options], fn) -> ...
--- Function
--- Runs a Lua function inside an OpenTelemetry span.
---
--- Parameters:
---  * name - span name
---  * options - optional table containing `kind` and `attributes`
---  * fn - function to execute
---
--- Returns:
---  * The return values from `fn`.
function module.withSpan(name, options, fn)
  if type(options) == "function" and fn == nil then
    fn = options
    options = nil
  end
  if type(fn) ~= "function" then
    error("expected function", 2)
  end

  local span = module.startSpan(name, options or {})
  -- Capture the raw error separately from its traceback so the recorded
  -- exception message stays concise while the stack still carries the traceback.
  local capturedError
  local function traceHandler(err)
    capturedError = err
    return debug.traceback(err, 2)
  end
  local results = table.pack(xpcall(fn, traceHandler, span))
  if not results[1] then
    local traceback = results[2]
    local message = tostring(capturedError)
    if span and not span.ended then
      module.recordException(message, traceback, nil, span)
      module.endSpan(span, { code = "error", message = message })
    end
    error(traceback, 0)
  end

  if span then
    module.endSpan(span)
  end
  return table.unpack(results, 2, results.n)
end

--- hs.opentelemetry.wrap(fn) -> function
--- Function
--- Captures the current propagation context and returns a function that restores it while calling `fn`.
---
--- Parameters:
---  * fn - function to wrap for later execution
---
--- Returns:
---  * A wrapped function. This is useful for coroutines or APIs that store a callback before running it later. The caller's previous context is restored after the callback returns or errors.
function module.wrap(fn)
  if type(fn) ~= "function" then
    error("expected function", 2)
  end
  local carrier = module.inject({})
  return function(...)
    local previousCarrier = module.inject({})
    module.extract(carrier)
    local results = table.pack(xpcall(fn, debug.traceback, ...))
    module.extract(previousCarrier)
    if not results[1] then
      error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
  end
end

--- hs.opentelemetry.startSpan(name[, options]) -> span
--- Function
--- Starts a span and returns a span object.
---
--- Parameters:
---  * name - span name
---  * options - optional table containing `kind` and `attributes`
---
--- Returns:
---  * A span object, or `nil` when tracing is disabled.
function module.startSpan(name, options)
  validateName(name, "span name", 2)
  return spanObject(native.startSpan(name, redactOptions(options)), name)
end

--- hs.opentelemetry.endSpan(span[, status[, attributes]])
--- Function
--- Ends a span object or native span id.
---
--- Parameters:
---  * span - span object returned by `startSpan`, or native span id
---  * status - optional status table
---  * attributes - optional end attributes
---
--- Returns:
---  * None
function module.endSpan(span, status, attributes)
  if type(span) == "table" and span.ended then
    return
  end
  local id = spanID(span)
  if id ~= nil then
    native.endSpan(id, status, redactAttributes(attributes))
    if type(span) == "table" then
      span.ended = true
    end
  end
end

--- hs.opentelemetry.tracer(name[, version]) -> table
--- Function
--- Returns a lightweight tracer facade for API symmetry.
---
--- Parameters:
---  * name - tracer name
---  * version - optional tracer version
---
--- Returns:
---  * A table with `startSpan` and `withSpan` methods.
function module.tracer(name, version)
  validateName(name, "tracer name", 2)
  local tracer = {
    name = name,
    version = version,
  }

  function tracer:startSpan(spanName, options)
    return module.startSpan(spanName, options)
  end

  function tracer:withSpan(spanName, options, fn)
    return module.withSpan(spanName, options, fn)
  end

  return tracer
end

--- hs.opentelemetry.meter(name[, version]) -> table
--- Function
--- Returns a lightweight meter facade for counters, gauges, and histograms.
---
--- Parameters:
---  * name - meter name
---  * version - optional meter version
---
--- Returns:
---  * A table with metric instrument factory methods.
function module.meter(name, version)
  validateName(name, "meter name", 2)
  local meter = { name = name, version = version }

  local function instrument(kind, metricName, opts)
    validateName(metricName, "metric name", 3)
    opts = opts or {}
    local metricInstrument = {
      name = metricName,
      kind = kind,
      unit = opts.unit,
    }

    function metricInstrument:add(value, attributes)
      native.metric(metricName, value, {
        kind = kind,
        unit = opts.unit,
        attributes = redactAttributes(attributes),
      })
      return self
    end

    function metricInstrument:record(value, attributes)
      native.metric(metricName, value, {
        kind = kind,
        unit = opts.unit,
        attributes = redactAttributes(attributes),
      })
      return self
    end

    return metricInstrument
  end

  function meter:counter(metricName, opts) return instrument("counter", metricName, opts) end
  function meter:upDownCounter(metricName, opts) return instrument("upDownCounter", metricName, opts) end
  function meter:gauge(metricName, opts) return instrument("gauge", metricName, opts) end
  function meter:histogram(metricName, opts) return instrument("histogram", metricName, opts) end
  return meter
end

--- hs.opentelemetry.setAttribute(key, value)
--- Function
--- Sets an attribute on the active span.
---
--- Parameters:
---  * key - attribute key
---  * value - attribute value
---
--- Returns:
---  * None
function module.setAttribute(key, value)
  native.setAttributes(redactAttributes({ [key] = value }))
end

--- hs.opentelemetry.setStatus(code[, message])
--- Function
--- Sets the status on the active span.
---
--- Parameters:
---  * code - status code, usually `ok`, `error`, or `unset`
---  * message - optional status message
---
--- Returns:
---  * None
function module.setStatus(code, message)
  native.setStatus({ code = code, message = message })
end

--- hs.opentelemetry.activeSpan() -> number | nil
--- Function
--- Returns the native id of the current active span.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The active span id, or nil.
function module.activeSpan()
  return native.status().activeSpanID
end

--- hs.opentelemetry.addEvent(name[, attributes[, span]])
--- Function
--- Adds an event to the active span or a supplied span.
---
--- Parameters:
---  * name - event name
---  * attributes - optional attributes table
---  * span - optional span object or native span id
---
--- Returns:
---  * None
function module.addEvent(name, attributes, span)
  if spanEnded(span) then
    return
  end
  native.addEvent(name, redactAttributes(attributes), spanID(span))
end

--- hs.opentelemetry.recordException(message[, stack[, attributes[, span]]])
--- Function
--- Records an exception event on the active span or supplied span.
---
--- Parameters:
---  * message - exception message
---  * stack - optional stack trace
---  * attributes - optional attributes table
---  * span - optional span object or native span id
---
--- Returns:
---  * None
function module.recordException(message, stack, attributes, span)
  if spanEnded(span) then
    return
  end
  native.recordException(message, stack, redactAttributes(attributes), spanID(span))
end

--- hs.opentelemetry.log(level, message[, attributes])
--- Function
--- Emits an OpenTelemetry log record.
---
--- Parameters:
---  * level - log level
---  * message - log message
---  * attributes - optional attributes table
---
--- Returns:
---  * None
function module.log(level, message, attributes)
  attributes = attributes or {}
  if attributes["log.source"] == "hs.logger" and not native.status().captureLogger then
    return
  end
  if attributes["log.source"] == "hs._logmessage" then
    local capturePrint = tostring(native.status().capturePrint or "off"):lower()
    if capturePrint == "off" or capturePrint == "false" or capturePrint == "none" then
      return
    end
  end
  native.log(level, message, redactAttributes(attributes))
end

--- hs.opentelemetry.metric(name, value[, options])
--- Function
--- Records a metric value.
---
--- Parameters:
---  * name - metric name
---  * value - numeric value
---  * options - optional table containing `kind`, `unit`, and `attributes`
---
--- Returns:
---  * None
function module.metric(name, value, options)
  options = redactOptions(options)
  native.metric(name, value, options)
end

--- hs.opentelemetry.inject(headers) -> table
--- Function
--- Injects trace context and baggage into a carrier table.
---
--- Parameters:
---  * headers - carrier table
---
--- Returns:
---  * A carrier table with propagation headers.
function module.inject(headers)
  local input = headers or {}
  clearTraceContextHeaders(input)
  local carrier = native.inject(input)
  if not propagatorEnabled("tracecontext") then
    clearTraceContextHeaders(carrier)
  end
  if propagatorEnabled("baggage") then
    carrier = installBaggageHeader(carrier)
  else
    clearCarrierHeader(carrier, "baggage")
  end
  return carrier
end

--- hs.opentelemetry.extract(headers)
--- Function
--- Extracts trace context and baggage from a carrier table.
---
--- Parameters:
---  * headers - carrier table
---
--- Returns:
---  * None
function module.extract(headers)
  native.extract(headers or {})
  if propagatorEnabled("baggage") then
    extractBaggageHeader(headers or {})
  end
end

--- hs.opentelemetry.flush([timeout]) -> bool
--- Function
--- Flushes pending telemetry without shutting down the active telemetry pipeline.
---
--- Parameters:
---  * timeout - optional timeout in seconds
---
--- Returns:
---  * `true` when flush completed successfully.
function module.flush(timeout)
  return native.flush(timeout)
end

--- hs.opentelemetry.shutdown([timeout]) -> bool
--- Function
--- Flushes pending telemetry and shuts down the active telemetry pipeline.
---
--- Parameters:
---  * timeout - optional timeout in seconds
---
--- Returns:
---  * `true` when shutdown completed successfully.
function module.shutdown(timeout)
  return native.shutdown(timeout)
end

--- hs.opentelemetry.setBaggage(key, value)
--- Function
--- Sets or removes a baggage item.
---
--- Parameters:
---  * key - baggage key
---  * value - baggage value, or nil to remove
---
--- Returns:
---  * None
function module.setBaggage(key, value)
  if not validBaggageKey(key) then
    error("invalid baggage key", 2)
  end
  baggage[key] = value
end

--- hs.opentelemetry.getBaggage([key]) -> string | table | nil
--- Function
--- Gets one baggage item or a copy of all baggage.
---
--- Parameters:
---  * key - optional baggage key
---
--- Returns:
---  * The baggage value, all baggage as a table, or nil.
function module.getBaggage(key)
  if key ~= nil then
    return baggage[key]
  end
  local copy = {}
  for k, v in pairs(baggage) do
    copy[k] = v
  end
  return copy
end

--- hs.opentelemetry.clearBaggage()
--- Function
--- Clears all local baggage items.
---
--- Parameters:
---  * None
---
--- Returns:
---  * None
function module.clearBaggage()
  baggage = {}
end

--- hs.opentelemetry.diagnostics() -> table
--- Function
--- Returns status plus Lua facade diagnostics.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A diagnostics table.
function module.diagnostics()
  local status = native.status()
  local baggageCount = 0
  for _ in pairs(baggage) do
    baggageCount = baggageCount + 1
  end
  status.baggageCount = baggageCount
  status.redactorInstalled = redactor ~= nil
  return status
end

--- hs.opentelemetry.setRedactor([fn])
--- Function
--- Installs or clears the Lua attribute redactor.
---
--- Parameters:
---  * fn - optional function called as `fn(key, value)`; return nil to drop the attribute
---
--- Returns:
---  * None
function module.setRedactor(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("expected function or nil", 2)
  end
  redactor = fn
end

function spanMT:addEvent(name, attributes)
  if self.ended then
    return self
  end
  module.addEvent(name, attributes, self)
  return self
end

function spanMT:recordException(message, stack, attributes)
  if self.ended then
    return self
  end
  module.recordException(message, stack, attributes, self)
  return self
end

function spanMT:setAttribute(key, value)
  if self.ended then
    return self
  end
  native.setAttributes(redactAttributes({ [key] = value }), spanID(self))
  return self
end

function spanMT:setStatus(code, message)
  if self.ended then
    return self
  end
  native.setStatus({ code = code, message = message }, spanID(self))
  return self
end

function spanMT:endSpan(status, attributes)
  module.endSpan(self, status, attributes)
  return self
end

spanMT.end_ = spanMT.endSpan
spanMT.finish = spanMT.endSpan
spanMT.__index = spanMT

hs.opentelemetry = module

return module
