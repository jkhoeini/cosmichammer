import Foundation
import CLua
@testable import HSSwiftExtensions

@_silgen_name("MJLuaAlloc")
func MJLuaAlloc()

@_silgen_name("HSExtensionsRegisterAll")
private func HSExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>?)

private let repoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CosmicHammerTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root
}()

/// Minimal getObjectMetatable for the test environment.
private let test_getObjectMetatable: lua_CFunction = { L in
    luaL_checktype(L, 1, LUA_TSTRING)
    let name = lua_tostring(L, 1)
    luaL_getmetatable(L, name)
    if lua_istable(L, -1) != 0 {
        lua_getfield(L, -1, "__type")
        if lua_isnil(L, -1) != 0, let name = name {
            lua_pop(L, 1)
            lua_pushstring(L, name)
            lua_setfield(L, -2, "__type")
        } else {
            lua_pop(L, 1)
        }
    }
    return 1
}

@MainActor private var luaBootstrapped = false

private func doLuaString(_ L: UnsafeMutablePointer<lua_State>, _ s: String) -> Int32 {
    let load = luaL_loadstring(L, s)
    if load != 0 { return load }
    return lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil)
}

@MainActor
func luaRunString(_ code: String) -> String? {
    bootstrapLuaForTesting()
    let L = lua_getCurrentState()!
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
            let s = String(cString: luaL_tolstring(L, idx, nil))
            lua_settop(L, lua_gettop(L) - 1)
            return s
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

    let appResources = repoRoot.appendingPathComponent("build/Cosmic Hammer.app/Contents/Resources")
    let extensionsPath = appResources.appendingPathComponent("extensions").path
    let docsPath = appResources.appendingPathComponent("docs.json").path
    let testResources = repoRoot.appendingPathComponent("Tests/CosmicHammerTests").path
    let testConfigDir = repoRoot.appendingPathComponent(".build/test-config").path
    let setupLua = repoRoot.appendingPathComponent("CosmicHammer/setup.lua").path

    guard FileManager.default.fileExists(atPath: extensionsPath) else {
        fatalError("Built extensions not found at \(extensionsPath) — run `just build` first")
    }
    try? FileManager.default.createDirectory(
        atPath: testConfigDir,
        withIntermediateDirectories: true
    )

    MJLuaAlloc()

    let L = lua_getCurrentState()!

    // Create the "hs" global table with essential core functions
    var corelib: [luaL_Reg] = [
        luaL_Reg(name: strdup("getObjectMetatable"), func: test_getObjectMetatable),
        luaL_Reg(name: nil, func: nil),
    ]
    lua_createtable(L, 0, Int32(corelib.count - 1))
    luaL_setfuncs(L, &corelib, 0)
    lua_setglobal(L, "hs")

    installLuaSkinCompatibilityGlobals(L)
    HSExtensionsRegisterAll(L)

    let srcExtensions = repoRoot.appendingPathComponent("extensions").path
    let extEsc = extensionsPath.replacingOccurrences(of: "'", with: "\\'")
    let docsEsc = docsPath.replacingOccurrences(of: "'", with: "\\'")
    let srcExtEsc = srcExtensions.replacingOccurrences(of: "'", with: "\\'")
    let testEsc = testResources.replacingOccurrences(of: "'", with: "\\'")
    let setupEsc = setupLua.replacingOccurrences(of: "'", with: "\\'")
    let rootEsc = repoRoot.path.replacingOccurrences(of: "'", with: "\\'")
    let resourceEsc = appResources.path.replacingOccurrences(of: "'", with: "\\'")
    let configEsc = testConfigDir.replacingOccurrences(of: "'", with: "\\'")
    let processID = ProcessInfo.processInfo.processIdentifier
    let luaSetup = """
    package.path = '\(testEsc)/?.lua;' ..
                   '\(extEsc)/?.lua;' ..
                   '\(extEsc)/?/init.lua;' ..
                   '\(extEsc)/hs/?/init.lua;' ..
                   '\(extEsc)/hs/?.lua;' ..
                   package.path

    local preload = function(m) return function() return require(m) end end
    for line in io.lines('\(setupEsc)') do
        local public, target = line:match([=[^%s*package%.preload%[['"]([^'"]+)['"]%]%s*=%s*preload%s*['"]([^'"]+)['"]]=])
        if public and target then package.preload[public] = preload(target) end
    end

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

    local noop = function() end
    hs.luaSkinLog = {
        level = 1,
        setLogLevel = noop,
        getLogLevel = function() return 'info' end,
        e = noop, ef = noop,
        w = noop, wf = noop,
        i = noop, ["if"] = noop,
        d = noop, df = noop,
        v = noop, vf = noop,
    }
    hs.handleLogMessage = noop

    hs.configdir = '\(configEsc)'
    hs.docstrings_json_file = '\(docsEsc)'
    hs.processInfo = {
        bundleID = 'org.hammerspoon.Hammerspoon',
        bundlePath = '\(rootEsc)/build/Cosmic Hammer.app',
        executablePath = '\(rootEsc)/.build/debug/Cosmic Hammer',
        frameworksPath = '\(rootEsc)/build/Cosmic Hammer.app/Contents/Frameworks',
        processID = \(processID),
        resourcePath = '\(resourceEsc)',
        version = 'test',
    }
    hs._exit = function() end
    os.exit = hs._exit
    hs.accessibilityState = function() return true end
    hs.cleanUTF8forConsole = function(value) return value end
    hs.focus = noop
    hs.openConsole = noop
    hs._notify = noop
    local toggles = { autoLaunch = false, consoleOnTop = false, dockIcon = true, menuIcon = true }
    hs.autoLaunch = function(value)
        if value ~= nil then toggles.autoLaunch = not not value end
        return toggles.autoLaunch
    end
    hs.consoleOnTop = function(value)
        if value ~= nil then toggles.consoleOnTop = not not value end
        return toggles.consoleOnTop
    end
    hs.dockIcon = function(value)
        if value ~= nil then toggles.dockIcon = not not value end
        return toggles.dockIcon
    end
    hs.menuIcon = function(value)
        if value ~= nil then toggles.menuIcon = not not value end
        return toggles.menuIcon
    end
    hs.reload = function()
        if type(hs.shutdownCallback) == 'function' then hs.shutdownCallback() end
    end

    hs._extensions = {}
    local hsDir = '\(extEsc)/hs'
    for entry in lfs.dir(hsDir) do
        if entry ~= '.' and entry ~= '..' then
            local name = entry:match('^(.+)%.lua$') or entry
            if not name:find('_') then
                hs._extensions[name] = true
            end
        end
    end

    hs = setmetatable(hs or {}, {
        __index = function(self, key)
            if hs._extensions[key] ~= nil then
                local mod = require('hs.' .. key)
                rawset(self, key, mod)
                return mod
            end
            return nil
        end
    })

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
