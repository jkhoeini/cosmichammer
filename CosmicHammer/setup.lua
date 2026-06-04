local context = ...

if type(context) ~= "table" then
  error("setup.lua expected one boot context table", 2)
end

local function stringField(name)
  local value = context[name]
  if type(value) ~= "string" then
    error("boot context field " .. name .. " must be string, got " .. type(value), 2)
  end
  return value
end

local modpath = stringField("extensionsPath")
local configdir = stringField("configDir")
local userruntime = os.getenv("HOME") .. "/.local/share/cosmic-hammer/site"

local paths = {
  configdir .. "/?.lua",
  configdir .. "/?/init.lua",
  configdir .. "/Spoons/?.spoon/init.lua",
  package.path,
  modpath .. "/?.lua",
  modpath .. "/?/init.lua",
  userruntime .. "/?.lua",
  userruntime .. "/?/init.lua",
  userruntime .. "/Spoons/?.spoon/init.lua",
}

local cpaths = {
  configdir .. "/?.dylib",
  configdir .. "/?.so",
  package.cpath,
  userruntime .. "/lib/?.dylib",
  userruntime .. "/lib/?.so",
}

package.path = table.concat(paths, ";")
package.cpath = table.concat(cpaths, ";")

print("-- package.path: " .. package.path)
print("-- package.cpath: " .. package.cpath)

local boot = require("hs._boot")
context = boot.validateContext(context)
boot.installPreloadAliases()

return require("hs._coresetup").setup(context)
