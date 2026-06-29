function run(iterations)
  local checksum = 0
  for i = 1, iterations do
    otel.metric("benchmark.metric", 1, {
      kind = "counter",
      unit = "1",
      attributes = {
        result = "ok",
        bucket = tostring(i % 8),
      },
    })
    checksum = checksum + i
  end
  return {
    operations = iterations,
    checksum = checksum,
  }
end

return {
  run = run,
}
