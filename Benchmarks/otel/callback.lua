local function callback_body(value)
  return value + 1
end

function run(iterations)
  local checksum = 0
  for i = 1, iterations do
    checksum = checksum + callback_body(i)
  end
  return {
    operations = iterations,
    checksum = checksum,
  }
end

return {
  run = run,
}
