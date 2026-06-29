function run(iterations)
  local checksum = 0
  for i = 1, iterations do
    local carrier = {
      traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      baggage = "automation=benchmark,iteration=" .. tostring(i % 32),
    }
    otel.extract(carrier)
    local injected = otel.inject({})
    checksum = checksum + #(injected.traceparent or "") + #(injected.baggage or "")
  end
  return {
    operations = iterations,
    checksum = checksum,
  }
end

return {
  run = run,
}
