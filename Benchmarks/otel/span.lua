function run(iterations)
  local checksum = 0
  for i = 1, iterations do
    local span = otel.startSpan("benchmark.span", {
      kind = "internal",
      attributes = {
        ["benchmark.iteration.mod"] = i % 16,
      },
    })
    if span then
      otel.addEvent("benchmark.step", { ["benchmark.step"] = i % 4 }, span)
      otel.endSpan(span, { code = "ok" })
      checksum = checksum + span
    else
      checksum = checksum + i
    end
  end
  return {
    operations = iterations,
    checksum = checksum,
  }
end

return {
  run = run,
}
