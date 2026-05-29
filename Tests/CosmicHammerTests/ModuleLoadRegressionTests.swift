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
    }
}
