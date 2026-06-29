function run(iterations)
  local checksum = 0
  for i = 1, iterations do
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
