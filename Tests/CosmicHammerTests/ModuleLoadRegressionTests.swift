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
    }
}
