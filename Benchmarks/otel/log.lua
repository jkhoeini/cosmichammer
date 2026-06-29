function run(iterations)
  local checksum = 0
  for i = 1, iterations do
    otel.log("info", "benchmark.log", {
      ["benchmark.kind"] = "log",
      ["benchmark.iteration.mod"] = i % 16,
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
