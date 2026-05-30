import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class WebviewConversionTests {
        @Test func testWebviewSupportConstructorsReturnUserdata() {
            let result = runLua("""
            (function()
                local webview = require("hs.webview")
                local suffix = tostring({}):gsub("%W", "")

                local toolbar = webview.toolbar.new("conversion" .. suffix, {
                    { id = "item", label = "Item" },
                })
                if type(toolbar) ~= "userdata" then
                    return "toolbar.new returned " .. type(toolbar) .. ": " .. tostring(toolbar)
                end

                local datastore = webview.datastore.newPrivate()
                if type(datastore) ~= "userdata" then
                    return "datastore.newPrivate returned " .. type(datastore) .. ": " .. tostring(datastore)
                end

                local usercontent = webview.usercontent.new("port" .. suffix)
                if type(usercontent) ~= "userdata" then
                    return "usercontent.new returned " .. type(usercontent) .. ": " .. tostring(usercontent)
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test(.skipInHeadless) func testWebviewNewAcceptsDatastoreAndUserContent() {
            let result = runLua("""
            (function()
                local webview = require("hs.webview")
                local suffix = tostring({}):gsub("%W", "")
                local datastore = webview.datastore.newPrivate()
                local usercontent = webview.usercontent.new("port" .. suffix)
                local view = webview.new({ x = 0, y = 0, w = 120, h = 80 }, {
                    datastore = datastore,
                }, usercontent)

                if type(view) ~= "userdata" then
                    return "webview.new returned " .. type(view) .. ": " .. tostring(view)
                end
                if view:privateBrowsing() ~= true then
                    view:delete()
                    return "webview did not use the private datastore"
                end
                if type(view:url({ URL = "about:blank", HTTPMethod = "GET" })) ~= "userdata" then
                    view:delete()
                    return "webview:url did not accept request table"
                end

                view:delete()
                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testUserContentScriptsRoundTripAsTables() {
            let result = runLua("""
            (function()
                local webview = require("hs.webview")
                local suffix = tostring({}):gsub("%W", "")
                local usercontent = webview.usercontent.new("port" .. suffix)
                usercontent:injectScript({
                    source = "window.__cosmicHammer = 1",
                    injectionTime = "documentEnd",
                    mainFrame = false,
                })

                local scripts = usercontent:userScripts()
                if type(scripts) ~= "table" then
                    return "userScripts returned " .. type(scripts)
                end
                if type(scripts[1]) ~= "table" then
                    return "script returned " .. type(scripts[1]) .. ": " .. tostring(scripts[1])
                end
                if scripts[1].source ~= "window.__cosmicHammer = 1" then
                    return "unexpected source: " .. tostring(scripts[1].source)
                end
                if scripts[1].injectionTime ~= "documentEnd" then
                    return "unexpected injectionTime: " .. tostring(scripts[1].injectionTime)
                end
                if scripts[1].forMainFrameOnly ~= false then
                    return "unexpected forMainFrameOnly: " .. tostring(scripts[1].forMainFrameOnly)
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }

        @Test func testToolbarItemDetailsReturnNestedTablesAndUserdata() {
            let result = runLua("""
            (function()
                local webview = require("hs.webview")
                local suffix = tostring({}):gsub("%W", "")
                local toolbar = webview.toolbar.new("conversionDetails" .. suffix, {
                    { id = "item", label = "Item", tooltip = "Tip", tag = 7 },
                })
                toolbar:insertItem("item", 1)

                local details = toolbar:itemDetails("item")
                if type(details) ~= "table" then
                    return "itemDetails returned " .. type(details) .. ": " .. tostring(details)
                end
                if details.id ~= "item" then
                    return "unexpected item id: " .. tostring(details.id)
                end
                if details.label ~= "Item" then
                    return "unexpected label: " .. tostring(details.label)
                end
                if type(details.toolbar) ~= "userdata" then
                    return "nested toolbar returned " .. type(details.toolbar) .. ": " .. tostring(details.toolbar)
                end

                return "ok"
            end)()
            """)

            #expect(result == "ok")
        }
    }
}
