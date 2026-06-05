import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ModuleLoadRegression {
        @Test func testNestedSetupAliasesLoadInTestBootstrap() {
            let result = runLua("""
            (function()
                local aliases = {
                    "hs.drawing.color",
                    "hs.host.locale",
                    "hs.network.host",
                    "hs.webview.toolbar",
                    "hs.doc.markdown",
                }

                for _, name in ipairs(aliases) do
                    local ok, mod = pcall(require, name)
                    if not ok then return name .. ": " .. tostring(mod) end
                    if type(mod) ~= "table" then return name .. " returned " .. type(mod) end
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testLoaderMetadataIsAvailableInTestBootstrap() {
            let result = runLua("""
            (function()
                local metadata = require("hs._loader_metadata")
                if metadata.aliasTargets["hs.doc.hsdocs"] ~= "hs.hsdocs" then return "missing hsdocs alias" end
                if metadata.luaModules["hs.hsdocs"].bundlePath ~= "hs/hsdocs/init.lua" then return "missing hsdocs copy path" end
                if metadata.nativeModules["hs.libwebviewdatastore"].symbol ~= "luaopen_hs_libwebviewdatastore" then return "missing webview datastore native key" end
                if metadata.lazyExtensions.alert ~= true then return "missing alert lazy extension" end
                if metadata.lazyExtensions.drawing_color ~= nil then return "compat module should not be lazy" end
                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testManifestNativePreloadsAreRegistered() {
            let result = runLua("""
            (function()
                local metadata = require("hs._loader_metadata")
                if type(metadata.nativeModuleList) ~= "table" then return "missing native module list" end

                local seen = {}
                local checked = 0
                for _, entry in ipairs(metadata.nativeModuleList) do
                    local name = entry.name
                    if type(name) ~= "string" or name == "" then
                        return "invalid native preload name"
                    end
                    if type(entry.symbol) ~= "string" or entry.symbol == "" then
                        return name .. " missing symbol"
                    end
                    if seen[name] then return "duplicate native preload " .. name end
                    seen[name] = true

                    local indexed = metadata.nativeModules[name]
                    if type(indexed) ~= "table" then return name .. " missing indexed metadata" end
                    if indexed.symbol ~= entry.symbol then return name .. " symbol mismatch" end
                    if type(package.preload[name]) ~= "function" then
                        return name .. " missing package.preload registration"
                    end
                    checked = checked + 1
                end

                local indexedCount = 0
                for _ in pairs(metadata.nativeModules) do indexedCount = indexedCount + 1 end
                if checked == 0 then return "no native preloads checked" end
                if indexedCount ~= checked then
                    return "native preload list/index mismatch: " .. tostring(checked) .. "/" .. tostring(indexedCount)
                end
                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testConstantsTableWrappersLoadReadOnlyTables() {
            let result = runLua("""
            (function()
                local checks = {
                    { name = "hs.hash", field = "types" },
                    { name = "hs.image", field = "systemImageNames" },
                    { name = "hs.sharing", field = "builtinSharingServices" },
                }

                for _, check in ipairs(checks) do
                    local ok, mod = pcall(require, check.name)
                    if not ok then return check.name .. ": " .. tostring(mod) end

                    local constants = mod[check.field]
                    if type(constants) ~= "table" then
                        return check.name .. "." .. check.field .. " is " .. type(constants)
                    end

                    local writeOK = pcall(function()
                        constants.__cosmicHammerMutationProbe = true
                    end)
                    if writeOK then
                        return check.name .. "." .. check.field .. " accepted mutation"
                    end
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testDocRegisterJSONFileRejectsNilWithoutCrashing() {
            let result = runLua("""
            (function()
                local ok, doc = pcall(require, "hs.doc")
                if not ok then return "require failed: " .. tostring(doc) end

                local callOK, err = pcall(doc.registerJSONFile, nil)
                if callOK then return "accepted nil" end
                return type(err)
            end)()
            """)

            #expect(result == "string")
        }

        @Test func testApplicationLoadsWhenSpotlightNameSearchesAreEnabled() {
            let result = runLua("""
            (function()
                local settings = require("hs.settings")
                settings.set("HSenableSpotlightForNameSearches", true)
                package.loaded["hs.application"] = nil
                rawset(hs, "application", nil)

                local ok, app = pcall(require, "hs.application")
                if ok then app.enableSpotlightForNameSearches(false) end
                settings.set("HSenableSpotlightForNameSearches", false)
                if not ok then return tostring(app) end
                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testSpotlightNewReturnsUsableUserdata() {
            let result = runLua("""
            (function()
                local spotlight = require("hs.spotlight")
                local watcher = spotlight.new()

                if type(watcher) ~= "userdata" then
                    return "new returned " .. type(watcher)
                end
                if type(watcher.queryString) ~= "function" then
                    return "queryString is " .. type(watcher.queryString)
                end

                local ok, err = pcall(function()
                    watcher:queryString([[kMDItemContentType = "com.apple.application-bundle"]])
                           :callbackMessages("didUpdate", "inProgress")
                           :setCallback(function() end)
                           :stop()
                end)
                if not ok then return tostring(err) end
                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testSpeechConstructorsReturnUserdata() {
            let result = runLua("""
            (function()
                local speech = require("hs.speech")
                local synth = speech.new()
                if type(synth) ~= "userdata" then
                    return "speech.new returned " .. type(synth)
                end
                if type(synth.speak) ~= "function" then
                    return "speech:speak is " .. type(synth.speak)
                end

                local listener = speech.listener
                if type(listener.new) ~= "function" then
                    return "listener.new is " .. type(listener.new)
                end
                local recognizer = listener.new()
                if recognizer ~= nil and type(recognizer) ~= "userdata" then
                    return "listener.new returned " .. type(recognizer)
                end
                if recognizer ~= nil then
                    if type(recognizer.commands) ~= "function" then
                        return "listener:commands is " .. type(recognizer.commands)
                    end
                    recognizer:delete()
                end
                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }
    }
}
