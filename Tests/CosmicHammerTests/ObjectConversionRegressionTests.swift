import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ObjectConversionRegression {
        @Test func testImageConstructorsReturnUserdata() {
            let result = runLua("""
                local image = require('hs.image')
                local img = image.imageFromName('NSApplicationIcon')
                return type(img)
                """)
            #expect(result == "userdata")
        }

        @Test func testColorTablesConvertThroughExplicitHelper() {
            let result = runLua("""
                local color = require('hs.drawing.color')
                local c = color.asRGB({ red = 0.25, green = 0.5, blue = 0.75, alpha = 0.5 })
                return type(c) .. ':' .. string.format('%.2f', c.red) .. ':' .. string.format('%.2f', c.alpha)
                """)
            #expect(result == "table:0.25:0.50")
        }

        @Test func testStyledtextObjectAndAttributeTablesRoundTrip() {
            let result = runLua("""
                local styledtext = require('hs.styledtext')
                local st = styledtext.new('hello', {
                    font = { name = 'Helvetica', size = 12 },
                    color = { red = 0.25, green = 0.5, blue = 0.75, alpha = 1 },
                    paragraphStyle = { alignment = 'center' },
                })
                local t = st:asTable()
                return type(st) .. ':' .. st:getString() .. ':' ..
                       type(t[2].attributes.font) .. ':' ..
                       type(t[2].attributes.color) .. ':' ..
                       type(t[2].attributes.paragraphStyle)
                """)
            #expect(result == "userdata:hello:table:table:table")
        }

        @Test func testPasteboardObjectConversionsRoundTrip() {
            let result = runLua("""
                local image = require('hs.image')
                local pasteboard = require('hs.pasteboard')
                local styledtext = require('hs.styledtext')

                local pb = pasteboard.uniquePasteboard()
                local img = image.imageFromName('NSApplicationIcon')
                local imageOK = pasteboard.writeObjects(img, pb)
                local gotImage = pasteboard.readImage(pb)

                local st = styledtext.new('clip', { color = { red = 1, green = 0, blue = 0, alpha = 1 } })
                local textOK = pasteboard.writeObjects(st, pb)
                local gotText = pasteboard.readStyledText(pb)

                pasteboard.deletePasteboard(pb)
                return tostring(imageOK) .. ':' .. type(gotImage) .. ':' ..
                       tostring(textOK) .. ':' .. type(gotText) .. ':' ..
                       gotText:getString()
                """)
            #expect(result == "true:userdata:true:userdata:clip")
        }

        @Test func testNetworkPingReturnsSameUserdataFromSetter() {
            let result = runLua("""
                local ping = require('hs.network.ping')
                local p = ping.echoRequest('127.0.0.1')
                local same = p:seeAllUnexpectedPackets(true)
                return table.concat({
                    type(p),
                    type(same),
                    tostring(same == p),
                    p:hostName(),
                }, ':')
                """)

            #expect(result == "userdata:userdata:true:127.0.0.1")
        }

        @Test func testBonjourObjectsReturnUserdataFromConstructorsAndSetters() {
            let result = runLua("""
                local bonjour = require('hs.bonjour')
                local browser = bonjour.new()
                local sameBrowser = browser:includesPeerToPeer(false)
                local service = bonjour.service.remote('example', '_http._tcp.', 'local.')
                local sameService = service:includesPeerToPeer(false)
                return table.concat({
                    type(browser),
                    tostring(sameBrowser == browser),
                    type(service),
                    tostring(sameService == service),
                    service:name(),
                }, ':')
                """)

            #expect(result == "userdata:true:userdata:true:example")
        }

        @Test func testIPCConstructorsReturnUserdata() {
            let result = runLua("""
                local ipc = require('hs.ipc')
                local name = 'cosmic-hammer-test-' .. tostring(math.random(1000000))
                local localPort = ipc.localPort(name, function(data) return data end)
                local remotePort = ipc.remotePort(name)
                local output = table.concat({
                    type(localPort),
                    localPort:name(),
                    tostring(localPort:isRemote()),
                    type(remotePort),
                    remotePort:name(),
                    tostring(remotePort:isRemote()),
                }, ':')
                localPort:delete()
                remotePort:delete()
                return output
                """)

            let parts = result?.split(separator: ":").map(String.init)
            #expect(parts?.count == 6)
            #expect(parts?[0] == "userdata")
            #expect(parts?[1].hasPrefix("cosmic-hammer-test-") == true)
            #expect(parts?[2] == "false")
            #expect(parts?[3] == "userdata")
            #expect(parts?[4] == parts?[1])
            #expect(parts?[5] == "true")
        }

        @Test func testNotifyConstructorAndSetterReturnUserdata() {
            let result = runLua("""
                local notify = require('hs.notify')
                local note = notify.new({ title = 'before' })
                local same = note:title('after')
                return table.concat({
                    type(note),
                    type(same),
                    tostring(same == note),
                    note:title(),
                }, ':')
                """)

            #expect(result == "userdata:userdata:true:after")
        }

        @Test func testSharingURLReturnsURLTable() {
            let result = runLua("""
                local sharing = require('hs.sharing')
                local url = sharing.URL('https://example.com/path')
                return table.concat({
                    type(url),
                    tostring(url.__luaSkinType),
                    tostring(url.url),
                    tostring(url.filePath == nil),
                }, ':')
                """)

            #expect(result == "table:NSURL:https://example.com/path:true")
        }
    }
}
