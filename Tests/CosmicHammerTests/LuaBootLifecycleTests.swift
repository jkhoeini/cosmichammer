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
                assert(context.configFileDisplayPath == "/tmp/cosmic/init.lua")
                assert(context.configFilePath == "/tmp/cosmic/init.lua")
                assert(context.configDir == "/tmp/cosmic")
                assert(context.dataDir == "/tmp/cosmic/data")
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

        @Test func coresetupInstallsOpenTelemetryGlobal() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, _ in
                #expect(luaEvalBool(L, """
                return type(hs.opentelemetry) == 'table'
                  and type(hs.opentelemetry.configure) == 'function'
                  and type(hs.opentelemetry.saveConfig) == 'function'
                  and type(hs.opentelemetry.loadConfig) == 'function'
                  and type(hs.opentelemetry.status) == 'function'
                  and type(hs.opentelemetry.diagnostics) == 'function'
                  and type(hs.opentelemetry.shutdown) == 'function'
                  and type(hs.opentelemetry.activeSpan) == 'function'
                  and type(hs.opentelemetry.setAttribute) == 'function'
                  and type(hs.opentelemetry.setStatus) == 'function'
                  and type(hs.opentelemetry.wrap) == 'function'
                  and hs.opentelemetry.status().enabled == false
                  and hs.opentelemetry.shutdown() == true
                  and hs.opentelemetry.activeSpan() == nil
                  and hs.opentelemetry.saveConfig({ enabled = true }) == false
                  and hs.opentelemetry.loadConfig() == nil
                  and hs.opentelemetry.wrap(function() return "ok" end)() == "ok"
                  and pcall(function() hs.opentelemetry.wrap("bad") end) == false
                  and pcall(function() hs.opentelemetry.startSpan("") end) == false
                  and pcall(function() hs.opentelemetry.withSpan("", function() end) end) == false
                  and (function()
                    local span = hs.opentelemetry.startSpan("noop-start")
                    local ok = span.id ~= nil
                      and span.name == "noop-start"
                      and span.ended == false
                      and hs.opentelemetry.activeSpan() == span.id
                    hs.opentelemetry.endSpan()
                    ok = ok and hs.opentelemetry.activeSpan() == span.id
                    hs.opentelemetry.endSpan(span.id)
                    return ok and span.ended == true and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and (function()
                    local parent = hs.opentelemetry.startSpan("noop-parent")
                    local child = hs.opentelemetry.startSpan("noop-child")
                    local ok = hs.opentelemetry.activeSpan() == child.id
                    child:endSpan()
                    ok = ok and hs.opentelemetry.activeSpan() == parent.id
                    parent:endSpan()
                    return ok and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and (function()
                    local parent = hs.opentelemetry.startSpan("noop-parent-ended-first")
                    local child = hs.opentelemetry.startSpan("noop-child-ended-second")
                    local ok = hs.opentelemetry.activeSpan() == child.id
                    parent:endSpan()
                    ok = ok and hs.opentelemetry.activeSpan() == child.id
                    child:endSpan()
                    return ok and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and hs.opentelemetry.withSpan("noop", function(span)
                    return span.name == "noop"
                      and hs.opentelemetry.activeSpan() == span.id
                      and hs.opentelemetry.status().activeSpanID == span.id
                      and hs.opentelemetry.diagnostics().activeSpanID == span.id
                      and span:setAttribute("key", "value"):setStatus("ok") == span
                  end) == true
                  and (function()
                    local first, gap, tail = hs.opentelemetry.withSpan("noop-returns", function()
                      return "first", nil, "tail"
                    end)
                    return first == "first" and gap == nil and tail == "tail"
                  end)()
                  and hs.opentelemetry.withSpan("noop-finish", function(span)
                    return span:finish() == span
                      and span:finish() == span
                      and span:endSpan() == span
                      and span:end_() == span
                      and span.ended == true
                      and hs.opentelemetry.activeSpan() == nil
                      and hs.opentelemetry.status().activeSpanID == nil
                  end) == true
                  and hs.opentelemetry.withSpan("noop-end-alias", function(span)
                    return span:end_() == span
                  end) == true
                  and hs.opentelemetry.status().activeSpanID == nil
                  and hs.opentelemetry.diagnostics().activeSpanID == nil
                  and hs.opentelemetry.activeSpan() == nil
                  and (function()
                    local span = hs.opentelemetry.startSpan("noop-shutdown")
                    return hs.opentelemetry.activeSpan() == span.id
                      and hs.opentelemetry.shutdown() == true
                      and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and (function()
                    local ok = pcall(function()
                      hs.opentelemetry.withSpan("noop-error", function()
                        error("boom")
                      end)
                    end)
                    return ok == false and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and hs.opentelemetry.withSpan("noop-parent-error", function(parent)
                    local ok = pcall(function()
                      hs.opentelemetry.withSpan("noop-child-error", function()
                        error("child boom")
                      end)
                    end)
                    return ok == false and hs.opentelemetry.activeSpan() == parent.id
                  end) == true
                  and hs.opentelemetry.activeSpan() == nil
                  and hs.opentelemetry.tracer("noop-tracer", "1.0").name == "noop-tracer"
                  and hs.opentelemetry.tracer("noop-tracer", "1.0").version == "1.0"
                  and pcall(function() hs.opentelemetry.tracer("") end) == false
                  and pcall(function() hs.opentelemetry.tracer() end) == false
                  and (function()
                    local tracer = hs.opentelemetry.tracer("noop")
                    return pcall(function() tracer:startSpan("") end) == false
                      and pcall(function() tracer:withSpan("", function() end) end) == false
                  end)()
                  and (function()
                    local span = hs.opentelemetry.tracer("noop"):startSpan("tracer-start")
                    local ok = span.name == "tracer-start"
                      and span.ended == false
                      and hs.opentelemetry.activeSpan() == span.id
                      and span:endSpan() == span
                    return ok and span.ended == true and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and hs.opentelemetry.tracer("noop"):withSpan("child", function(span)
                    span:addEvent("event"):recordException("ignored"):finish()
                    return "traced"
                  end) == "traced"
                  and (function()
                    local first, gap, tail = hs.opentelemetry.tracer("noop"):withSpan("child-returns", function()
                      return "tracer-first", nil, "tracer-tail"
                    end)
                    return first == "tracer-first" and gap == nil and tail == "tracer-tail"
                  end)()
                  and (function()
                    local tracer = hs.opentelemetry.tracer("noop")
                    local parent = tracer:startSpan("tracer-parent-error")
                    local childSpan
                    local ok = pcall(function()
                      tracer:withSpan("tracer-child-error", function(child)
                        childSpan = child
                        error("tracer child boom")
                      end)
                    end)
                    local preservedParent = hs.opentelemetry.activeSpan() == parent.id
                    parent:finish()
                    return ok == false
                      and childSpan.ended == true
                      and preservedParent
                      and hs.opentelemetry.activeSpan() == nil
                  end)()
                  and hs.opentelemetry.tracer("noop"):withSpan("child-with-options", { attributes = { ok = true } }, function(span)
                    return span:setAttribute("ok", true) == span
                  end) == true
                  and hs.opentelemetry.meter("noop-meter", "2.0").name == "noop-meter"
                  and hs.opentelemetry.meter("noop-meter", "2.0").version == "2.0"
                  and pcall(function() hs.opentelemetry.meter("") end) == false
                  and pcall(function() hs.opentelemetry.meter() end) == false
                  and (function()
                    local meter = hs.opentelemetry.meter("noop-meter", "2.0")
                    local counter = meter:counter("noop.counter", { unit = "1" })
                    local updown = meter:upDownCounter("noop.updown", { unit = "items" })
                    local gauge = meter:gauge("noop.gauge", { unit = "ms" })
                    local histogram = meter:histogram("noop.histogram", { unit = "s" })
                    return counter.name == "noop.counter"
                      and counter.kind == "counter"
                      and counter.unit == "1"
                      and counter:add(1) == counter
                      and updown.kind == "upDownCounter"
                      and updown:add(-1) == updown
                      and gauge.kind == "gauge"
                      and gauge:record(1) == gauge
                      and histogram.kind == "histogram"
                      and histogram:record(1) == histogram
                      and pcall(function() meter:counter("") end) == false
                      and pcall(function() meter:gauge() end) == false
                  end)()
                """) == true)
            }
        }

        @Test func noopFacadeMatchesRealOpenTelemetrySurface() throws {
            // The _coresetup fallback facade duplicates the public surface of the
            // real extensions/opentelemetry/opentelemetry.lua module. Guard against
            // drift: every public function on the real module must also exist on
            // the noop fallback that boots when the module fails to load.
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, _ in
                let luaPath = bootTestRepoRoot
                    .appendingPathComponent("extensions/opentelemetry/opentelemetry.lua")
                    .path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                #expect(luaEvalBool(L, """
                local noopKeys = {}
                for name, value in pairs(hs.opentelemetry) do
                  if type(value) == 'function' then noopKeys[name] = true end
                end

                local nativeShim = {}
                for _, name in ipairs({
                  'configure', 'status', 'startSpan', 'endSpan', 'setAttributes',
                  'setStatus', 'addEvent', 'recordException', 'log', 'metric',
                  'inject', 'extract', 'flush', 'shutdown',
                }) do
                  nativeShim[name] = function() end
                end
                nativeShim.status = function() return {} end
                nativeShim.inject = function(carrier) return carrier or {} end
                package.loaded['hs.libopentelemetry'] = nativeShim
                package.preload['hs.libopentelemetry'] = function() return nativeShim end

                local realModule = assert(loadfile('\(luaPath)'))()
                local missing = {}
                for name, value in pairs(realModule) do
                  if type(value) == 'function' and not noopKeys[name] then
                    missing[#missing + 1] = name
                  end
                end
                return #missing == 0
                """) == true)
            }
        }

        @Test func coresetupInstallsLazyExtensionsFromLoaderMetadata() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: true) { L, _ in
                #expect(luaEvalBool(L, "return hs._extensions.alert == true") == true)
                #expect(luaEvalBool(L, "return hs._extensions.drawing_color == nil") == true)
            }
        }

        @Test func coresetupWrapsRequireWithTelemetry() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, _ in
                installLuaTelemetryRecorder(L)
                #expect(luaEvalBool(L, """
                package.preload["test.module"] = function()
                  return { ok = true }
                end
                local loaded = require("test.module")
                return loaded.ok == true
                  and telemetrySpans[1].name == "lua.require"
                  and telemetrySpans[1].attributes["cosmichammer.lua.module"] == "test.module"
                  and telemetrySpans[1].status.code == "ok"
                """) == true)
            }
        }

        @Test func lazyExtensionLoadingCreatesParentAndRequireSpans() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: true) { L, _ in
                installLuaTelemetryRecorder(L)
                #expect(luaEvalBool(L, """
                package.preload["hs.alert"] = function()
                  return { show = function() end }
                end
                local alert = hs.alert
                return alert ~= nil
                  and telemetrySpans[1].name == "hs.extension.lazy_load"
                  and telemetrySpans[2].name == "lua.require"
                  and telemetrySpans[2].attributes["cosmichammer.lua.module"] == "hs.alert"
                  and telemetrySpans[1].status.code == "ok"
                  and telemetrySpans[2].status.code == "ok"
                """) == true)
            }
        }

        @Test func consoleEvaluationRecordsTelemetrySpan() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, refs in
                installLuaTelemetryRecorder(L)
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refs.evalFunctionRef))
                lua_pushstring(L, "1 + 1")
                #expect(lua_pcall(L, 1, 1, 0) == LUA_OK)
                #expect(String(cString: lua_tostring(L, -1)) == "2")
                lua_pop(L, 1)

                #expect(luaEvalBool(L, """
                return telemetrySpans[#telemetrySpans].name == "console.evaluate"
                  and telemetrySpans[#telemetrySpans].attributes["cosmichammer.lua.source"] == "console"
                  and telemetrySpans[#telemetrySpans].attributes["cosmichammer.lua.command.length"] == 5
                  and telemetrySpans[#telemetrySpans].status.code == "ok"
                """) == true)
            }
        }

        @Test func hsExecuteRecordsTelemetrySpanWithoutCommandText() throws {
            try withMinimalCoresetupBoot(autoloadExtensions: false) { L, _ in
                installLuaTelemetryRecorder(L)
                #expect(luaEvalBool(L, """
                local output, status, exitType, rc = hs.execute("printf ok", false)
                local span = telemetrySpans[#telemetrySpans]
                return output == "ok"
                  and status == true
                  and exitType == "exit"
                  and rc == 0
                  and span.name == "hs.execute"
                  and span.attributes["cosmichammer.process.command.length"] == 9
                  and span.attributes["cosmichammer.process.shell.user_env"] == false
                  and span.attributes["process.exit.code"] == 0
                  and span.attributes["cosmichammer.process.exit.type"] == "exit"
                  and span.attributes["process.command"] == nil
                  and span.status.code == "ok"
                """) == true)
            }
        }

        @Test func loaderMetadataIsBootAliasSource() throws {
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
                local metadata = require('hs._loader_metadata')

                assert(boot.preloadAliases == metadata.preloadAliases, 'boot aliases must be generated metadata')
                assert(metadata.aliasTargets['hs.doc.markdown'] == 'hs.libmarkdown')
                assert(metadata.luaModules['hs.hsdocs'].bundlePath == 'hs/hsdocs/init.lua')
                assert(metadata.nativeModules['hs.libmarkdown'].symbol == 'luaopen_hs_libmarkdown')
                assert(metadata.lazyExtensions.alert == true)
                assert(metadata.lazyExtensions.drawing_color == nil)
                """

                #expect(luaEval(L, script) == true)
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
        configFileDisplayPath: "\(configDir)/init.lua",
        configFilePath: "\(configDir)/init.lua",
        configDir: configDir,
        dataDir: "\(configDir)/data",
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
                dataDir: "\(configDir)/data",
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
    try FileManager.default.copyItem(
        at: bootTestRepoRoot.appendingPathComponent("extensions/_coresetup/_loader_metadata.lua"),
        to: hsDir.appendingPathComponent("_loader_metadata.lua")
    )

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

private func installLuaTelemetryRecorder(_ L: UnsafeMutablePointer<lua_State>) {
    #expect(luaEval(L, """
    telemetrySpans = {}
    telemetryExceptions = {}
    hs.opentelemetry = {
      startSpan = function(name, options)
        local span = {
          name = name,
          attributes = (options and options.attributes) or {},
          status = { code = "unset" },
        }
        telemetrySpans[#telemetrySpans + 1] = span
        return span
      end,
      endSpan = function(span, status, attributes)
        if span then
          span.status = status or { code = "unset" }
          for key, value in pairs(attributes or {}) do
            span.attributes[key] = value
          end
        end
      end,
      recordException = function(message, stack, attributes, span)
        local item = { message = message, stack = stack, attributes = attributes or {}, span = span }
        telemetryExceptions[#telemetryExceptions + 1] = item
        if span then span.exception = message end
      end,
      withSpan = function(name, options, fn)
        if type(options) == "function" and fn == nil then
          fn = options
          options = nil
        end
        local span = hs.opentelemetry.startSpan(name, options)
        local ok, result = pcall(fn, span)
        if ok then
          hs.opentelemetry.endSpan(span, { code = "ok" })
          return result
        end
        hs.opentelemetry.recordException(tostring(result), nil, nil, span)
        hs.opentelemetry.endSpan(span, { code = "error", message = tostring(result) })
        error(result, 0)
      end,
    }
    """))
    lua_settop(L, 0)
}
