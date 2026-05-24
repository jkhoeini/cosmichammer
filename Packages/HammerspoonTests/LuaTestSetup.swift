import Foundation
import LuaSkin

@_silgen_name("MJLuaAlloc")
func MJLuaAlloc()

@_silgen_name("HSExtensionsRegisterAll")
private func HSExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>?)

private let repoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HammerspoonTests/
        .deletingLastPathComponent()  // Packages/
        .deletingLastPathComponent()  // repo root
}()

private nonisolated(unsafe) var luaBootstrapped = false

private func doLuaString(_ L: UnsafeMutablePointer<lua_State>, _ s: String) -> Int32 {
    let load = luaL_loadstring(L, s)
    if load != 0 { return load }
    return lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil)
}

@MainActor
func luaRunString(_ code: String) -> String? {
    bootstrapLuaForTesting()
    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!
    let top = lua_gettop(L)

    let firstResult = top + 1
    var result: String?

    func readResult(_ idx: Int32) -> String? {
        switch lua_type(L, idx) {
        case LUA_TSTRING, LUA_TNUMBER:
            var len: Int = 0
            if let s = lua_tolstring(L, idx, &len), len > 0 {
                return String(cString: s)
            }
            return ""
        case LUA_TBOOLEAN:
            return lua_toboolean(L, idx) != 0 ? "true" : "false"
        case LUA_TNIL:
            return nil
        default:
            return String(cString: luaL_tolstring(L, idx, nil))
        }
    }

    if doLuaString(L, "return " + code) == LUA_OK {
        if lua_gettop(L) >= firstResult {
            result = readResult(firstResult)
        }
    } else {
        lua_settop(L, top)
        if doLuaString(L, code) == LUA_OK {
            if lua_gettop(L) >= firstResult {
                result = readResult(firstResult)
            }
        } else {
            result = readResult(-1)
        }
    }

    lua_settop(L, top)
    return result
}

@MainActor
func bootstrapLuaForTesting() {
    guard !luaBootstrapped else { return }
    luaBootstrapped = true

    let appResources = repoRoot.appendingPathComponent("build/Hammerspoon.app/Contents/Resources")
    let extensionsPath = appResources.appendingPathComponent("extensions").path
    let testResources = repoRoot.appendingPathComponent("Packages/HammerspoonTests").path

    guard FileManager.default.fileExists(atPath: extensionsPath) else {
        fatalError("Built extensions not found at \(extensionsPath) — run `just build` first")
    }

    LuaSkin.resourceSearchPath = appResources.path
    MJLuaAlloc()

    let skin = LuaSkin.shared(with: nil) as! LuaSkin
    let L = skin.l!

    var corelib: [luaL_Reg] = [luaL_Reg(name: nil, func: nil)]
    skin.registerLibrary("core", functions: &corelib, metaFunctions: nil)
    lua_setglobal(L, "hs")

    HSExtensionsRegisterAll(L)

    let srcExtensions = repoRoot.appendingPathComponent("extensions").path
    let extEsc = extensionsPath.replacingOccurrences(of: "'", with: "\\'")
    let srcExtEsc = srcExtensions.replacingOccurrences(of: "'", with: "\\'")
    let testEsc = testResources.replacingOccurrences(of: "'", with: "\\'")
    let luaSetup = """
    package.path = '\(testEsc)/?.lua;' ..
                   '\(extEsc)/?.lua;' ..
                   '\(extEsc)/?/init.lua;' ..
                   '\(extEsc)/hs/?/init.lua;' ..
                   '\(extEsc)/hs/?.lua;' ..
                   package.path

    -- Add each source extension subdirectory so test_*.lua files can be found
    local lfs = require('hs.fs')
    for entry in lfs.dir('\(srcExtEsc)') do
        if entry ~= '.' and entry ~= '..' then
            local path = '\(srcExtEsc)/' .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == 'directory' then
                package.path = path .. '/?.lua;' .. package.path
            end
        end
    end

    hs = setmetatable(hs or {}, {
        __index = function(self, key)
            if key:sub(1,1) == '_' then return nil end
            local ok, mod = pcall(require, 'hs.' .. key)
            if ok then rawset(self, key, mod) return mod end
            return nil
        end
    })

    hs._extensions = {}
    local hsDir = '\(extEsc)/hs'
    for entry in lfs.dir(hsDir) do
        if entry ~= '.' and entry ~= '..' then
            local name = entry:match('^(.+)%.lua$') or entry
            if name:sub(1,1) ~= '_' then
                hs._extensions[name] = true
            end
        end
    end

    require('lsunit')
    """
    let result = doLuaString(L, luaSetup)
    if result != LUA_OK {
        var len: Int = 0
        let err = lua_tolstring(L, -1, &len).flatMap { String(cString: $0) } ?? "unknown"
        NSLog("Lua test setup error: %@", err)
        lua_settop(L, lua_gettop(L) - 1)
    }
    lua_settop(L, 0)
}
