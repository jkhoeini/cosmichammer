import Foundation
import CLua
import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ObjectConversionRegressionTests {
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

        @Test func testStyledtextTableConstructorAndConcatReturnUserdata() {
            let result = runLua("""
                local styledtext = require('hs.styledtext')
                local fromTable = styledtext.new({
                    'table',
                    {
                        starts = 1,
                        ends = 5,
                        attributes = { color = { red = 0, green = 1, blue = 0, alpha = 1 } },
                    },
                })
                local base = styledtext.new('base')
                local left = 'prefix ' .. base
                local right = base .. ' suffix'
                local attrs = fromTable:asTable()[2].attributes
                return type(fromTable) .. ':' .. fromTable:getString() .. ':' ..
                       type(attrs.color) .. ':' ..
                       type(left) .. ':' .. left:getString() .. ':' ..
                       type(right) .. ':' .. right:getString()
                """)
            #expect(result == "userdata:table:table:userdata:prefix base:userdata:base suffix")
        }

        @Test func testPasteboardObjectConversionsRoundTrip() {
            let result = runLua("""
                local image = require('hs.image')
                local pasteboard = require('hs.pasteboard')
                local styledtext = require('hs.styledtext')

                local pb = pasteboard.uniquePasteboard()
                local ok, value = pcall(function()
                    local img = image.imageFromName('NSApplicationIcon')
                    local imageOK = pasteboard.writeObjects(img, pb)
                    local gotImage = pasteboard.readImage(pb)

                    local st = styledtext.new('clip', { color = { red = 1, green = 0, blue = 0, alpha = 1 } })
                    local textOK = pasteboard.writeObjects(st, pb)
                    local gotText = pasteboard.readStyledText(pb)

                    return tostring(imageOK) .. ':' .. type(gotImage) .. ':' ..
                           tostring(textOK) .. ':' .. type(gotText) .. ':' ..
                           gotText:getString()
                end)
                pasteboard.deletePasteboard(pb)
                if not ok then error(value) end
                return value
                """)
            #expect(result == "true:userdata:true:userdata:clip")
        }

        @Test func testPasteboardUrlTableAndReadAllStyledtext() {
            let result = runLua("""
                local pasteboard = require('hs.pasteboard')
                local styledtext = require('hs.styledtext')

                local pb = pasteboard.uniquePasteboard()
                local ok, value = pcall(function()
                    local badUrlOK = pcall(function()
                        pasteboard.writeObjects({ url = {} }, pb)
                    end)
                    local urlOK = pasteboard.writeObjects({ url = 'https://example.com/' }, pb)
                    local gotURL = pasteboard.readURL(pb)

                    local first = styledtext.new('one')
                    local second = styledtext.new('two')
                    local textOK = pasteboard.writeObjects({ first, second }, pb)
                    local allText = pasteboard.readStyledText(pb, true)

                    return tostring(badUrlOK) .. ':' ..
                           tostring(urlOK) .. ':' .. type(gotURL) .. ':' ..
                           tostring(textOK) .. ':' .. #allText .. ':' ..
                           type(allText[1]) .. ':' .. allText[1]:getString() .. ':' ..
                           type(allText[2]) .. ':' .. allText[2]:getString()
                end)
                pasteboard.deletePasteboard(pb)
                if not ok then error(value) end
                return value
                """)
            #expect(result == "false:true:string:true:2:userdata:one:userdata:two")
        }

        @Test func testPasteboardArchiverColorRoundTrip() {
            let result = runLua("""
                local pasteboard = require('hs.pasteboard')

                local pb = pasteboard.uniquePasteboard()
                local ok, value = pcall(function()
                    local uti = 'org.cosmichammer.test.color'
                    local writeOK = pasteboard.writeArchiverDataForUTI(pb, uti, { red = 0.2, green = 0.4, blue = 0.6, alpha = 0.8 })
                    local color = pasteboard.readArchiverDataForUTI(pb, uti)
                    return tostring(writeOK) .. ':' .. type(color) .. ':' ..
                           string.format('%.1f', color.green) .. ':' ..
                           string.format('%.1f', color.alpha)
                end)
                pasteboard.deletePasteboard(pb)
                if not ok then error(value) end
                return value
                """)
            #expect(result == "true:table:0.4:0.8")
        }

        @Test func testIPCConstructorsReturnUserdata() {
            let name = "cosmic-hammer-test-\(UUID().uuidString)"
            let result = runLua("""
                local ipc = require('hs.libipc')
                local name = '\(name)'
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
            if let parts, parts.count == 6 {
                #expect(parts[0] == "userdata")
                #expect(parts[1] == name)
                #expect(parts[2] == "false")
                #expect(parts[3] == "userdata")
                #expect(parts[4] == parts[1])
                #expect(parts[5] == "true")
            } else {
                #expect(parts?.count == 6, "Lua result: \(result ?? "nil")")
            }
        }

        @Test func testNetworkPingSetterReturnsSameUserdata() {
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

        @Test func testBonjourBrowserSetterReturnsSameUserdata() {
            let result = runLua("""
                local bonjour = require('hs.libbonjour')
                local browser = bonjour.new()
                local same = browser:includesPeerToPeer(true)
                return table.concat({
                    type(browser),
                    type(same),
                    tostring(same == browser),
                    tostring(browser:includesPeerToPeer()),
                }, ':')
                """)
            #expect(result == "userdata:userdata:true:true")
        }

        @Test func testBonjourServiceConstructorsAndMethodsUseUserdata() {
            let name = "bonjour-service-test-\(UUID().uuidString)"
            let remoteName = "bonjour-remote-test-\(UUID().uuidString)"
            let result = runLua("""
                local service = require('hs.libbonjourservice')
                local localService = service.new('\(name)', '_http._tcp.', 54321, 'local.')
                local same = localService:includesPeerToPeer(true)
                local remoteService = service.remote('\(remoteName)', '_ssh._tcp.', 'local.')
                local output = table.concat({
                    type(localService),
                    localService:name(),
                    localService:type(),
                    localService:domain(),
                    tostring(localService:port()),
                    type(same),
                    tostring(same == localService),
                    type(remoteService),
                    remoteService:name(),
                    remoteService:type(),
                    remoteService:domain(),
                    tostring(remoteService:port()),
                }, ':')
                localService:stop()
                remoteService:stop()
                return output
                """)
            #expect(result == [
                "userdata",
                name,
                "_http._tcp.",
                "local.",
                "54321",
                "userdata",
                "true",
                "userdata",
                remoteName,
                "_ssh._tcp.",
                "local.",
                "-1",
            ].joined(separator: ":"))
        }

        @Test func testBonjourNetServicePushInitializesServiceUserdata() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }

            let service = NetService(
                domain: "local.",
                type: "_http._tcp.",
                name: "bonjour-push-test-\(UUID().uuidString)"
            )

            #expect(pushNSNetService(L, service) == 1)
            #expect(luaL_testudata(L, -1, "hs.bonjour.service") != nil)
            let firstPointer = lua_topointer(L, -1)

            #expect(pushNSNetService(L, service) == 1)
            #expect(luaL_testudata(L, -1, "hs.bonjour.service") != nil)
            #expect(lua_topointer(L, -1) == firstPointer)
        }
    }
}
