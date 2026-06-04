import CLua
import Foundation
import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class LuaBootLifecycle {
        @Test func setupReceivesNamedBootContextAndReturnsLifecycleRefs() throws {
            try withLuaState { L in
                let setupPath = try writeTemporarySetup("""
                local context = ...
                assert(type(context) == "table", "expected context table")
                assert(context.extensionsPath == "/bundle/extensions")
                assert(context.configFileDisplayPath == "~/.cosmic-hammer/init.lua")
                assert(context.configFilePath == "/tmp/cosmic/init.lua")
                assert(context.configDir == "/tmp/cosmic")
                assert(context.docsJSONPath == "/bundle/docs.json")
                assert(context.hasInitFile == true)
                assert(context.autoloadExtensions == false)

                return {
                  runString = function(input) return input .. ":" .. context.configDir end,
                  completionsForInputString = function() return {} end,
                }
                """)

                let refs = try LuaBoot.runSetup(
                    L,
                    setupPath: setupPath,
                    context: testBootContext(hasInitFile: true, autoloadExtensions: false)
                )

                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refs.evalFunctionRef))
                lua_pushstring(L, "ok")
                #expect(lua_pcall(L, 1, 1, 0) == LUA_OK)
                #expect(String(cString: lua_tostring(L, -1)) == "ok:/tmp/cosmic")
                lua_pop(L, 1)
            }
        }

        @Test func oldTwoFunctionSetupReturnIsInvalidBeforeRefsAreCreated() throws {
            try withLuaState { L in
                let setupPath = try writeTemporarySetup("""
                return function() end, function() end
                """)

                do {
                    _ = try LuaBoot.runSetup(
                        L,
                        setupPath: setupPath,
                        context: testBootContext()
                    )
                    Issue.record("old positional setup return unexpectedly succeeded")
                } catch let error as LuaBoot.Error {
                    #expect(error.description.contains("lifecycle table"))
                    #expect(lua_gettop(L) == 0)
                }
            }
        }

        @Test func partialLifecycleTableIsInvalidBeforeRefsAreCreated() throws {
            try withLuaState { L in
                let setupPath = try writeTemporarySetup("""
                return { runString = function() end }
                """)

                do {
                    _ = try LuaBoot.runSetup(
                        L,
                        setupPath: setupPath,
                        context: testBootContext()
                    )
                    Issue.record("partial lifecycle setup return unexpectedly succeeded")
                } catch let error as LuaBoot.Error {
                    #expect(error.description.contains("runString and completionsForInputString"))
                    #expect(lua_gettop(L) == 0)
                }
            }
        }

        @Test func missingSetupFileFailsWithoutLeavingStackValues() throws {
            try withLuaState { L in
                do {
                    _ = try LuaBoot.runSetup(
                        L,
                        setupPath: "/tmp/cosmic-hammer-missing-\(UUID().uuidString).lua",
                        context: testBootContext()
                    )
                    Issue.record("missing setup unexpectedly succeeded")
                } catch let error as LuaBoot.Error {
                    #expect(error.description.contains("Unable to load setup.lua"))
                    #expect(lua_gettop(L) == 0)
                }
            }
        }

        @Test func coresetupDoesNotInstallLazyLoaderWhenAutoloadIsFalse() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, _ in
                #expect(luaEvalBool(L, "return hs._extensions == nil") == true)
                #expect(luaEvalBool(L, "return getmetatable(hs) == nil") == true)
            }
        }

        @Test func coresetupReloadInvokesShutdownCallback() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, _ in
                #expect(luaEvalBool(L, """
                fired = false
                hs.shutdownCallback = function() fired = true end
                hs.reload()
                return fired
                """) == true)
            }
        }

        @Test func coresetupKeepsConfigDirAsNamedContextField() throws {
            let configDir = "/tmp/Cosmic Hammer Config O'Hare"
            try withMinimalCoresetupBoot(
                autoloadExtensions: false,
                configDir: configDir
            ) { L, _ in
                #expect(luaEvalString(L, "return hs.configdir") == configDir)
                #expect(luaEvalBool(L, "return package.path:find(hs.configdir, 1, true) ~= nil") == true)
            }
        }

        @Test func bootPreloadAliasesResolveToConfiguredTargets() throws {
            try withLuaState { L in
                let resourceRoot = try writeMinimalBootResources()
                defer { try? FileManager.default.removeItem(at: resourceRoot) }

                let extensionsPath = resourceRoot.appendingPathComponent("extensions").path
                let extensionsEsc = extensionsPath.replacingOccurrences(of: "'", with: "\\'")
                let script = """
                package.path = '\(extensionsEsc)/?.lua;' ..
                               '\(extensionsEsc)/?/init.lua;' ..
                               package.path

                local boot = require('hs._boot')
                assert(#boot.preloadAliases > 0, 'expected preload aliases')

                for _, alias in ipairs(boot.preloadAliases) do
                  local target = alias[2]
                  package.preload[target] = function() return { target = target } end
                end

                boot.installPreloadAliases()

                for _, alias in ipairs(boot.preloadAliases) do
                  local public, target = alias[1], alias[2]
                  assert(type(package.preload[public]) == 'function', public .. ' was not installed')
                  local loaded = require(public)
                  assert(loaded.target == target, public .. ' resolved to wrong target')
                end
                """

                #expect(luaEval(L, script) == true)
            }
        }
    }
}

private let bootTestRepoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}()

private func testBootContext(
    hasInitFile: Bool = false,
    autoloadExtensions: Bool = true,
    configDir: String = "/tmp/cosmic"
) -> LuaBoot.Context {
    LuaBoot.Context(
        extensionsPath: "/bundle/extensions",
        configFileDisplayPath: "~/.cosmic-hammer/init.lua",
        configFilePath: "\(configDir)/init.lua",
        configDir: configDir,
        docsJSONPath: "/bundle/docs.json",
        hasInitFile: hasInitFile,
        autoloadExtensions: autoloadExtensions
    )
}

private func writeTemporarySetup(_ contents: String) throws -> String {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cosmic-hammer-boot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("setup.lua")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file.path
}

private func withMinimalCoresetupBoot(
    autoloadExtensions: Bool,
    configDir: String = "/tmp/cosmic",
    body: (UnsafeMutablePointer<lua_State>, LuaBoot.LifecycleReferences) throws -> Void
) throws {
    try withLuaState { L in
        let resourceRoot = try writeMinimalBootResources()
        defer { try? FileManager.default.removeItem(at: resourceRoot) }
        try installMinimalCoresetupDependencies(L)
        let refs = try LuaBoot.runSetup(
            L,
            setupPath: bootTestRepoRoot.appendingPathComponent("CosmicHammer/setup.lua").path,
            context: LuaBoot.Context(
                extensionsPath: resourceRoot.appendingPathComponent("extensions").path,
                configFileDisplayPath: "\(configDir)/init.lua",
                configFilePath: "\(configDir)/init.lua",
                configDir: configDir,
                docsJSONPath: resourceRoot.appendingPathComponent("docs.json").path,
                hasInitFile: false,
                autoloadExtensions: autoloadExtensions
            )
        )
        lua_settop(L, 0)
        try body(L, refs)
    }
}

private func writeMinimalBootResources() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cosmic-hammer-coresetup-\(UUID().uuidString)")
    let hsDir = root.appendingPathComponent("extensions/hs")
    try FileManager.default.createDirectory(at: hsDir, withIntermediateDirectories: true)

    for file in ["_boot.lua", "_coresetup.lua"] {
        try FileManager.default.copyItem(
            at: bootTestRepoRoot.appendingPathComponent("extensions/_coresetup/\(file)"),
            to: hsDir.appendingPathComponent(file)
        )
    }

    try "{}".write(
        to: root.appendingPathComponent("docs.json"),
        atomically: true,
        encoding: .utf8
    )

    return root
}

private func installMinimalCoresetupDependencies(_ L: UnsafeMutablePointer<lua_State>) throws {
    let setup = """
    local noop = function() end
    hs = {
      _exit = function() end,
      _logmessage = noop,
      processInfo = {
        bundleID = 'test.bundle',
        bundlePath = '/tmp/Test.app',
        executablePath = '/tmp/Test.app/Contents/MacOS/Test',
        frameworksPath = '/tmp/Test.app/Contents/Frameworks',
        processID = 1,
        resourcePath = '/tmp/Test.app/Contents/Resources',
        version = 'test',
      },
      focus = noop,
      openConsole = noop,
      _notify = noop,
      reload = function()
        if type(hs.shutdownCallback) == 'function' then hs.shutdownCallback() end
      end,
    }

    local log = {
      e = noop, ef = noop,
      w = noop, wf = noop,
      i = noop, ["if"] = noop,
      d = noop, df = noop,
      v = noop, vf = noop,
    }

    package.preload['hs.crash'] = function()
      return { crashLog = noop, crashKV = noop }
    end
    package.preload['hs.math'] = function()
      return { randomFloat = function() return 0.5 end, minFloat = 0.000001 }
    end
    package.preload['hs.fnutils'] = function()
      return {
        ifilter = function(items, predicate)
          local out = {}
          for _, item in ipairs(items) do
            if predicate(item) then out[#out + 1] = item end
          end
          return out
        end,
        imap = function(items, mapper)
          local out = {}
          for i, item in ipairs(items) do out[i] = mapper(item) end
          return out
        end,
        split = function(value, separator)
          local out = {}
          for part in string.gmatch(value, '([^' .. separator .. ']+)') do
            out[#out + 1] = part
          end
          return out
        end,
      }
    end
    package.preload['hs.host'] = function()
      return { uuid = function() return 'uuid' end }
    end
    package.preload['hs.timer'] = function()
      return { doAfter = function() return { stop = noop } end }
    end
    package.preload['hs.doc'] = function() return {} end
    package.preload['hs.logger'] = function()
      return { new = function() return log end }
    end
    package.preload['hs.notify'] = function()
      return { register = noop, show = noop }
    end
    """

    guard luaEval(L, setup) else {
        let message = lua_tostring(L, -1).map { String(cString: $0) } ?? "unable to install fake dependencies"
        lua_settop(L, 0)
        throw LuaBoot.Error.runtimeFailed(message)
    }
    lua_settop(L, 0)
}
