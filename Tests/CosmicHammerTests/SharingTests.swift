import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Sharing {
        @Test func testSharingLoadsWithBuiltinConstants() {
            let result = runLua("""
            (function()
                local ok, mod = pcall(require, 'hs.sharing')
                if not ok then return 'require failed: ' .. tostring(mod) end

                local writeOK = pcall(function()
                    mod.builtinSharingServices.composeEmail = 'modified'
                end)

                return table.concat({
                    type(mod),
                    type(mod.builtinSharingServices),
                    tostring(writeOK),
                    tostring(mod.builtinSharingServices.composeEmail ~= nil),
                }, ':')
            end)()
            """)

            #expect(result == "table:table:false:true")
        }
    }
}
