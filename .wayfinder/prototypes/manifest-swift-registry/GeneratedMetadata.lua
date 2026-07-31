-- PROTOTYPE — generated key-only loader metadata. Delete with the prototype.
local M = {}
M.nativeModules = {
  ["hs.libprototype_callback"] = true,
  ["hs.libprototype_nested"] = true,
  ["hs.libprototype_simple"] = true,
  ["hs.libprototype_userdata"] = true,
}
M.nativeModuleList = {
  "hs.libprototype_callback",
  "hs.libprototype_nested",
  "hs.libprototype_simple",
  "hs.libprototype_userdata",
}
M.luaModules = {
  ["hs.prototypecallback"] = { source = "Lua/hs/prototypecallback.lua", bundlePath = "prototypecallback.lua" },
  ["hs.prototypenested"] = { source = "Lua/hs/prototypenested.lua", bundlePath = "prototypenested.lua" },
  ["hs.prototypesimple"] = { source = "Lua/hs/prototypesimple.lua", bundlePath = "prototypesimple.lua" },
  ["hs.prototypeuserdata"] = { source = "Lua/hs/prototypeuserdata.lua", bundlePath = "prototypeuserdata.lua" },
}
M.preloadAliases = {
  { "hs.prototype.callback", "hs.libprototype_callback" },
  { "hs.prototype.nested", "hs.libprototype_nested" },
  { "hs.prototype.simple", "hs.libprototype_simple" },
  { "hs.prototype.userdata", "hs.libprototype_userdata" },
}
M.lazyExtensions = {
  ["prototypecallback"] = true,
  ["prototypenested"] = true,
  ["prototypesimple"] = true,
  ["prototypeuserdata"] = true,
}
return M
