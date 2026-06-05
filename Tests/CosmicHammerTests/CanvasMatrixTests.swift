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

        @Test func testMatrixMethodsAcceptPlainTables() {
            let result = runLua("""
            (function()
                local matrix = require("hs.canvas.matrix")
                local base = { m11 = 1, m12 = 0, m21 = 0, m22 = 1, tX = 3, tY = 4 }
                local scale = { m11 = 2, m12 = 0, m21 = 0, m22 = 5, tX = 0, tY = 0 }
                local appended = matrix.append(base, scale)
                local prepended = matrix.prepend(base, scale)

                if getmetatable(appended).__type ~= "hs.canvas.matrix" then return "append type" end
                if getmetatable(prepended).__type ~= "hs.canvas.matrix" then return "prepend type" end
                if type(appended.translate) ~= "function" then return "append not chainable" end
                if appended.m11 ~= 2 or appended.m22 ~= 5 or appended.tX ~= 6 or appended.tY ~= 20 then
                    return string.format("bad append %.1f %.1f %.1f %.1f", appended.m11, appended.m22, appended.tX, appended.tY)
                end
                if prepended.m11 ~= 2 or prepended.m22 ~= 5 or prepended.tX ~= 3 or prepended.tY ~= 4 then
                    return string.format("bad prepend %.1f %.1f %.1f %.1f", prepended.m11, prepended.m22, prepended.tX, prepended.tY)
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testMatrixMissingFieldsDefaultToIdentity() {
            let result = runLua("""
            (function()
                local matrix = require("hs.canvas.matrix")
                local m = matrix.append({ tX = 7 }, {})

                if getmetatable(m).__type ~= "hs.canvas.matrix" then return "type" end
                if m.m11 ~= 1 or m.m12 ~= 0 or m.m21 ~= 0 or m.m22 ~= 1 or m.tX ~= 7 or m.tY ~= 0 then
                    return string.format("unexpected %.1f %.1f %.1f %.1f %.1f %.1f", m.m11, m.m12, m.m21, m.m22, m.tX, m.tY)
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }
    }
}
