import CLua
import Foundation
import Lua

private let prototypeRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func luaErrorMessage(_ state: LuaState) -> String {
    lua_tostring(state, -1).map(String.init(cString:)) ?? "unknown Lua error"
}

private func runScript(_ state: LuaState, _ script: String) {
    let base = lua_gettop(state)
    guard luaL_loadstring(state, script) == LUA_OK else {
        fatalError(luaErrorMessage(state))
    }
    guard lua_pcall(state, 0, 0, 0) == LUA_OK else {
        fatalError(luaErrorMessage(state))
    }
    precondition(lua_gettop(state) == base)
}

guard let state = luaL_newstate() else { fatalError("luaL_newstate failed") }
defer { lua_close(state) }
luaL_openlibs(state)

registerBundledLuaModules(in: state)

let metadataPath = prototypeRoot.appendingPathComponent("GeneratedMetadata.lua").path
let loadResult = luaL_loadfilex(state, (metadataPath as NSString).fileSystemRepresentation, nil)
guard loadResult == LUA_OK, lua_pcall(state, 0, 1, 0) == LUA_OK else {
    fatalError(luaErrorMessage(state))
}
lua_setglobal(state, "_prototypeMetadata")

_ = prototypeRoot.path.withCString { path in
    lua_pushstring(state, path)
}
lua_setglobal(state, "_prototypeRoot")

runScript(state, #"""
local metadata = _prototypeMetadata
package.path = _prototypeRoot .. "/Lua/?.lua;" .. package.path

local expected = {
  "hs.libprototype_callback",
  "hs.libprototype_nested",
  "hs.libprototype_simple",
  "hs.libprototype_userdata",
}
assert(#metadata.nativeModuleList == #expected)
for i, name in ipairs(expected) do
  assert(metadata.nativeModuleList[i] == name)
  assert(metadata.nativeModules[name] == true)
  assert(type(package.preload[name]) == "function")
end
assert(metadata.nativeModules["prototypeNestedChildFactory"] == nil)

local preloadCount = 0
for name in pairs(package.preload) do
  if name:match("^hs%.libprototype_") then preloadCount = preloadCount + 1 end
end
assert(preloadCount == #expected)

for _, alias in ipairs(metadata.preloadAliases) do
  package.preload[alias[1]] = function() return require(alias[2]) end
end

hs = {}
setmetatable(hs, {
  __index = function(target, key)
    if metadata.lazyExtensions[key] then
      local module = require("hs." .. key)
      rawset(target, key, module)
      return module
    end
  end,
})

assert(require("hs.prototype.simple").answer == 42)
assert(require("hs.prototype.callback").kind == "callback")
assert(require("hs.prototype.userdata").new(3):value() == 3)
assert(require("hs.prototype.nested").child.answer == 9)

assert(type(hs.prototypesimple) == "table" and hs.prototypesimple.answer == 42)
assert(type(hs.prototypeuserdata) == "table")
local userdata = hs.prototypeuserdata.new(7)
assert(type(userdata) == "userdata" and userdata:value() == 7)
assert(hs.prototypecallback.invoke(function(value) return value * 2 end, 21) == 42)
assert(hs.prototypenested.child.answer == 9)

local lazyCount = 0
for _ in pairs(metadata.lazyExtensions) do lazyCount = lazyCount + 1 end
assert(lazyCount == 4)

_prototypeOrder = table.concat(metadata.nativeModuleList, ",")
_prototypeEvidence = "preload=4/4 aliases=4/4 lazy=4/4 simple=42 userdata=7 callback=42 nested=9 stack=balanced"
"""#)

lua_getglobal(state, "_prototypeOrder")
let order = lua_tostring(state, -1).map(String.init(cString:))!
lua_pop(state, 1)
lua_getglobal(state, "_prototypeEvidence")
let evidence = lua_tostring(state, -1).map(String.init(cString:))!
lua_pop(state, 1)
precondition(lua_gettop(state) == 0)

#if PROTOTYPE_DEBUG
let configuration = "debug"
#else
let configuration = "release"
#endif
print("configuration=\(configuration) order=\(order) \(evidence)")
