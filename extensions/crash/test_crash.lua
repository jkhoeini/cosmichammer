hs.crash = require("hs.crash")

function testResidentSize()
local value = hs.crash.residentSize()
assertIsNumber(value)
return success()
end

function testThrowTheWorld()
local ok, err = pcall(hs.crash.throwObjCException, "foo", "bar")
if ok then
  error("expected throwObjCException to raise an error")
end
return tostring(err)
end
