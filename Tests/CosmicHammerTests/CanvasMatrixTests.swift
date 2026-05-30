import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class CanvasMatrixTests {
        @Test func testMatrixConstructorsReturnChainableTypedTables() {
            let result = runLua("""
            (function()
                local matrix = require("hs.canvas.matrix")
                local m = matrix.translate(10, 20):scale(2, 3):append(matrix.identity())
                local mt = getmetatable(m)

                if type(m) ~= "table" then return "matrix is " .. type(m) end
                if type(mt) ~= "table" then return "metatable is " .. type(mt) end
                if mt.__type ~= "hs.canvas.matrix" then return "type is " .. tostring(mt.__type) end
                if type(m.scale) ~= "function" then return "scale is " .. type(m.scale) end
                if m.m11 ~= 2 or m.m22 ~= 3 or m.tX ~= 10 or m.tY ~= 20 then
                    return string.format("unexpected matrix %.1f %.1f %.1f %.1f", m.m11, m.m22, m.tX, m.tY)
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }
    }
}
