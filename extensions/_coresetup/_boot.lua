local metadata = require("hs._loader_metadata")

local M = {}

M.loaderMetadata = metadata
M.preloadAliases = metadata.preloadAliases

local function requireField(context, name, expectedType)
  local value = context[name]
  if type(value) ~= expectedType then
    error(string.format("boot context field %s must be %s, got %s", name, expectedType, type(value)), 3)
  end
  return value
end

function M.validateContext(context)
  if type(context) ~= "table" then
    error("setup.lua expected one boot context table", 3)
  end

  requireField(context, "extensionsPath", "string")
  requireField(context, "configFileDisplayPath", "string")
  requireField(context, "configFilePath", "string")
  requireField(context, "configDir", "string")
  requireField(context, "docsJSONPath", "string")
  requireField(context, "hasInitFile", "boolean")
  requireField(context, "autoloadExtensions", "boolean")

  return context
end

function M.installPreloadAliases()
  local preload = function(m) return function() return require(m) end end

  for _, alias in ipairs(M.preloadAliases) do
    package.preload[alias[1]] = preload(alias[2])
  end
end

return M
