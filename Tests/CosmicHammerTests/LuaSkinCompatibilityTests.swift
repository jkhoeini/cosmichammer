import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class LuaSkinCompatibility {
        @Test func testCompatibilityGlobalIsInstalled() {
            let result = runLua("type(ls) .. ':' .. type(ls.makeConstantsTable)")

            #expect(result == "table:function")
        }

        @Test func testConstantsTablesAreReadOnlyAndIterable() {
            let result = runLua("""
            (function()
                local constants = ls.makeConstantsTable({
                    'one',
                    'two',
                    first = 'alpha',
                    second = 'beta',
                    nested = { child = 'value' },
                })

                local writeOK = pcall(function()
                    constants.first = 'modified'
                end)
                local nestedWriteOK = pcall(function()
                    constants.nested.child = 'modified'
                end)

                local count = 0
                for _ in pairs(constants) do count = count + 1 end

                return table.concat({
                    constants.first,
                    constants.alpha,
                    constants.nested.child,
                    constants.nested.value,
                    tostring(writeOK),
                    tostring(nestedWriteOK),
                    tostring(#constants),
                    table.concat(constants, ','),
                    tostring(count == 5),
                }, ':')
            end)()
            """)

            #expect(result == "alpha:first:value:child:false:false:2:one,two:true")
        }
    }
}
