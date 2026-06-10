import AppKit
import AVFoundation
import Foundation
import CLua
import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class ObjectConversionRegressionTests {
        private func luaStringLiteral(_ value: String) -> String {
            "'" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n") + "'"
        }

        private func makeSilentSoundFile() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cosmic-hammer-sound-\(UUID().uuidString)")
                .appendingPathExtension("caf")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 800)!
            buffer.frameLength = 800
            try file.write(from: buffer)
            return url
        }

        private func withLibNotifyState(_ body: (UnsafeMutablePointer<lua_State>) throws -> Void) rethrows {
            try withLuaState { L in
                let top = lua_gettop(L)
                #expect(luaopen_hs_libnotify(L) == 1)
                lua_settop(L, top)
                defer {
                    nt_debugCleanupModule(L)
                }
                try body(L)
            }
        }

        private func withBootstrappedLua(
            requiring modules: [String],
            _ body: (UnsafeMutablePointer<lua_State>) throws -> Void
        ) rethrows {
            bootstrapLuaForTesting()
            for module in modules {
                _ = runLua("require('\(module)')")
            }
            let L = lua_getCurrentState()!
            let top = lua_gettop(L)
            defer { lua_settop(L, top) }
            try body(L)
        }

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

        @Test func testNotifyConstructorsAndImageMethodsUseUserdata() {
            let result = runLua("""
                local notify = require('hs.libnotify')
                local image = require('hs.image')
                local n = notify._new('notify-test')
                local sameTitle = n:title('Title')
                local sameSubtitle = n:subTitle('Subtitle')
                local sameText = n:informativeText('Body')
                local sameNilImage = n:_contentImage(nil)
                local img = image.imageFromName('NSApplicationIcon')
                local sameImage = n:_contentImage(img)
                local gotImage = n:_contentImage()
                local scheduled = notify.scheduledNotifications()
                local delivered = notify.deliveredNotifications()
                return table.concat({
                    type(n),
                    type(sameTitle),
                    tostring(sameTitle == n),
                    tostring(sameSubtitle == n),
                    tostring(sameText == n),
                    n:title(),
                    n:subTitle(),
                    n:informativeText(),
                    tostring(sameNilImage == n),
                    tostring(sameImage == n),
                    type(gotImage),
                    type(scheduled),
                    type(delivered),
                    tostring(n == n),
                    tostring(n):match('^hs.notify') and 'tostring' or 'bad',
                }, ':')
                """)
            #expect(result == [
                "userdata",
                "userdata",
                "true",
                "true",
                "true",
                "Title",
                "Subtitle",
                "Body",
                "true",
                "true",
                "userdata",
                "table",
                "table",
                "true",
                "tostring",
            ].joined(separator: ":"))
        }

        @Test func testNotifyArrayPushesUserdataElements() {
            withLibNotifyState { L in
                let first = NSUserNotification()
                first.title = "first"
                let second = NSUserNotification()
                second.title = "second"

                nt_pushNotificationArray(L, [first, second])
                #expect(lua_istable(L, -1) != 0)
                #expect(lua_rawlen(L, -1) == 2)

                lua_rawgeti(L, -1, 1)
                #expect(luaL_testudata(L, -1, nt_USERDATA_TAG) != nil)
                #expect(nt_getNotification(L, -1).title == "first")
                lua_pop(L, 1)

                lua_rawgeti(L, -1, 2)
                #expect(luaL_testudata(L, -1, nt_USERDATA_TAG) != nil)
                #expect(nt_getNotification(L, -1).title == "second")
                lua_pop(L, 1)
            }
        }

        @Test func testNotifyUserdataGcRemovesSelfRefRecord() throws {
            try withLibNotifyState { L in
                let gus = "notify-gc-test-\(UUID().uuidString)"
                let userInfo = NSMutableDictionary(dictionary: [
                    KEY_ID: gus,
                    KEY_SELFREFCOUNT: 0,
                ])
                nt_debugSetSpecificsRecord(gus, userInfo)

                let notification = NSUserNotification()
                notification.userInfo = [KEY_ID: gus]

                #expect(nt_pushNSUserNotification(L, notification) == 1)
                #expect(nt_debugSelfRefCount(gus) == 1)
                #expect(nt_pushNSUserNotification(L, notification) == 1)
                #expect(nt_debugSelfRefCount(gus) == 2)

                try #expect(nt_userdata_gc(L) == 0)
                #expect(nt_debugSelfRefCount(gus) == 1)
                lua_remove(L, 1)

                try #expect(nt_userdata_gc(L) == 0)
                #expect(!nt_debugHasSpecificsRecord(gus))
            }
        }

        @Test func testSoundFileConstructorAndMethodsUseUserdata() throws {
            let soundURL = try makeSilentSoundFile()
            defer { try? FileManager.default.removeItem(at: soundURL) }

            let soundPath = luaStringLiteral(soundURL.path)
            let soundName = luaStringLiteral("cosmic-hammer-sound-\(UUID().uuidString)")
            let result = runLua("""
                local sound = require('hs.sound')
                local s = sound.getByFile(\(soundPath))
                if s == nil then return 'nil' end
                local sameVolume = s:volume(0.25)
                local sameLoop = s:loopSound(true)
                local sameTime = s:currentTime(0)
                local sameName = s:name(\(soundName))
                local currentName = s:name()
                local sameDevice = s:device(nil)
                local sameCallback = s:setCallback(function() end)
                local sameNilCallback = s:setCallback(nil)
                local sameClearName = s:name(nil)
                return table.concat({
                    type(s),
                    type(sameVolume),
                    tostring(sameVolume == s),
                    tostring(sameLoop == s),
                    tostring(sameTime == s),
                    tostring(sameName == s),
                    type(currentName),
                    tostring(sameDevice == s),
                    tostring(sameCallback == s),
                    tostring(sameNilCallback == s),
                    tostring(sameClearName == s),
                    type(s:duration()),
                    type(s:isPlaying()),
                    tostring(s == s),
                    tostring(s):match('^hs.sound') and 'tostring' or 'bad',
                }, ':')
                """)
            #expect(result == [
                "userdata",
                "userdata",
                "true",
                "true",
                "true",
                "true",
                "string",
                "true",
                "true",
                "true",
                "true",
                "number",
                "boolean",
                "true",
                "tostring",
            ].joined(separator: ":"))
        }

        @Test func testCameraAllCamerasReturnsTypedUserdataWhenAvailable() {
            let result = runLua("""
                local camera = require('hs.camera')
                local cameras = camera.allCameras()
                if #cameras == 0 then
                    return 'empty'
                end
                local cam = cameras[1]
                local output = table.concat({
                    'camera',
                    type(cam),
                    type(cam:uid()),
                    type(cam:connectionID()),
                    type(cam:name()),
                    type(cam:isInUse()),
                    type(cam:isPropertyWatcherRunning()),
                    tostring(cam == cam),
                    tostring(cam):match('^hs.camera') and 'tostring' or 'bad',
                }, ':')
                cameras = nil
                cam = nil
                collectgarbage('collect')
                collectgarbage('collect')
                return output
                """)
            if result == "empty" {
                #expect(result == "empty")
            } else {
                let parts = result?.split(separator: ":").map(String.init)
                if let parts, parts.count == 9 {
                    #expect(parts[0] == "camera")
                    #expect(parts[1] == "userdata")
                    #expect(["string", "nil"].contains(parts[2]))
                    #expect(parts[3] == "number")
                    #expect(["string", "nil"].contains(parts[4]))
                    #expect(parts[5] == "boolean")
                    #expect(parts[6] == "boolean")
                    #expect(parts[7] == "true")
                    #expect(parts[8] == "tostring")
                } else {
                    #expect(parts?.count == 9, "Lua result: \(result ?? "nil")")
                }
            }
        }

        @Test func testChooserConstructorAndSettersUseUserdata() {
            let result = runLua("""
                local chooser = require('hs.chooser')
                local c = chooser.new(function() end)
                local sameChoices = c:choices({ { text = 'plain' } })
                local sameFg = c:fgColor({ red = 0.1, green = 0.2, blue = 0.3, alpha = 0.4 })
                local fg = c:fgColor()
                local sameSub = c:subTextColor({ red = 0.5, green = 0.6, blue = 0.7, alpha = 0.8 })
                local sub = c:subTextColor()
                return table.concat({
                    type(c),
                    type(sameChoices),
                    tostring(sameChoices == c),
                    type(sameFg),
                    tostring(sameFg == c),
                    type(fg),
                    string.format('%.1f', fg.green),
                    type(sameSub),
                    tostring(sameSub == c),
                    type(sub),
                    string.format('%.1f', sub.alpha),
                    tostring(c == c),
                    tostring(c):match('^hs.chooser') and 'tostring' or 'bad',
                }, ':')
                """)
            #expect(result == [
                "userdata",
                "userdata",
                "true",
                "userdata",
                "true",
                "table",
                "0.2",
                "userdata",
                "true",
                "table",
                "0.8",
                "true",
                "tostring",
            ].joined(separator: ":"))
        }

        @Test func testChooserChoiceConversionPreservesImageAndStyledtext() throws {
            try withBootstrappedLua(requiring: ["hs.image", "hs.styledtext", "hs.chooser"]) { L in
                #expect(luaL_dostring(L, """
                    local image = require('hs.image')
                    local styledtext = require('hs.styledtext')
                    return {
                        {
                            text = styledtext.new('main'),
                            subText = styledtext.new('sub'),
                            image = image.imageFromName('NSApplicationIcon'),
                            plain = 'value',
                        },
                    }
                    """) == LUA_OK)

                let choices = try #require(lua_toChooserChoices(L, at: -1))
                #expect(choices.count == 1)
                let choice = try #require(choices.object(at: 0) as? NSDictionary)
                #expect((choice["text"] as? NSAttributedString)?.string == "main")
                #expect((choice["subText"] as? NSAttributedString)?.string == "sub")
                #expect(choice["image"] is NSImage)
                #expect(choice["plain"] as? String == "value")

                pushChooserChoice(L, choice)
                #expect(lua_type(L, -1) == LUA_TTABLE)

                lua_getfield(L, -1, "text")
                #expect(toNSAttributedString(L, at: -1)?.string == "main")
                lua_pop(L, 1)

                lua_getfield(L, -1, "subText")
                #expect(toNSAttributedString(L, at: -1)?.string == "sub")
                lua_pop(L, 1)

                lua_getfield(L, -1, "image")
                #expect(toNSImage(L, at: -1) != nil)
                lua_pop(L, 1)
            }
        }

        @Test func testChooserDynamicChoicesCallbackPreservesTypedValues() throws {
            try withBootstrappedLua(requiring: ["hs.image", "hs.styledtext", "hs.chooser"]) { L in
                let chooser = HSChooser(refTable: LUA_NOREF, completionCallbackRef: LUA_NOREF)
                #expect(luaL_dostring(L, """
                    local image = require('hs.image')
                    local styledtext = require('hs.styledtext')
                    return function()
                        return {
                            {
                                text = styledtext.new('dynamic'),
                                image = image.imageFromName('NSApplicationIcon'),
                            },
                        }
                    end
                    """) == LUA_OK)

                chooser.choicesCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
                defer {
                    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, chooser.choicesCallbackRef)
                    chooser.choicesCallbackRef = LUA_NOREF
                }

                let choices = try #require(chooser.getChoices())
                #expect(choices.count == 1)
                let choice = try #require(choices.object(at: 0) as? NSDictionary)
                #expect((choice["text"] as? NSAttributedString)?.string == "dynamic")
                #expect(choice["image"] is NSImage)
            }
        }

        @Test func testSharingURLAndShareTypesAcceptTypedItems() {
            let result = runLua("""
                local sharing = require('hs.sharing')
                local image = require('hs.image')
                local styledtext = require('hs.styledtext')

                local url = sharing.URL('https://example.com/path')
                local fileURL = sharing.URL('/tmp/cosmic-hammer-sharing.txt', true)
                local items = {
                    url,
                    image.imageFromName('NSApplicationIcon'),
                    styledtext.new('share'),
                    'plain text',
                }
                local ok, services = pcall(function()
                    return sharing.shareTypesFor(items)
                end)

                return table.concat({
                    type(url),
                    tostring(url.__luaSkinType),
                    tostring(url.url),
                    type(fileURL),
                    tostring(fileURL.__luaSkinType),
                    type(fileURL.filePath),
                    tostring(ok),
                    type(services),
                }, ':')
                """)
            #expect(result == [
                "table",
                "NSURL",
                "https://example.com/path",
                "table",
                "NSURL",
                "string",
                "true",
                "table",
            ].joined(separator: ":"))
        }

        @Test func testSharingServiceMethodsUseUserdataAndNilAlternateImage() {
            let result = runLua("""
                local sharing = require('hs.sharing')
                local service = sharing.newShare(sharing.builtinSharingServices.composeEmail)
                if service == nil then return 'missing' end

                local sameSubject = service:subject('Cosmic Hammer')
                local sameRecipients = service:recipients({ 'test@example.com' })
                local sameCallback = service:callback(function() end)
                local sameClear = service:callback(nil)
                local canShare = service:canShareItems({ sharing.URL('https://example.com/') })
                local image = service:image()
                local alternate = service:alternateImage()

                return table.concat({
                    type(service),
                    type(sameSubject),
                    tostring(sameSubject == service),
                    tostring(sameRecipients == service),
                    tostring(sameCallback == service),
                    tostring(sameClear == service),
                    type(canShare),
                    type(image),
                    type(alternate),
                    type(service:serviceName()),
                    tostring(service == service),
                    tostring(service):match('^hs.sharing') and 'tostring' or 'bad',
                }, ':')
                """)
            if result == "missing" {
                #expect(result == "missing")
            } else {
                #expect(result == [
                    "userdata",
                    "userdata",
                    "true",
                    "true",
                    "true",
                    "true",
                    "boolean",
                    "userdata",
                    "nil",
                    "string",
                    "true",
                    "tostring",
                ].joined(separator: ":"))
            }
        }

        @Test func testSharingItemPushPreservesTypedValues() throws {
            try withBootstrappedLua(requiring: ["hs.image", "hs.styledtext", "hs.sharing"]) { L in
                let url = try #require(NSURL(string: "https://example.com/share"))
                let image = NSImage(size: NSSize(width: 16, height: 16))
                let styledText = NSAttributedString(string: "styled share")

                pushSharingItems(L, [url, image, styledText, "plain"])
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(lua_rawlen(L, -1) == 4)

                lua_rawgeti(L, -1, 1)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(lua_getfield(L, -1, "__luaSkinType") == LUA_TSTRING)
                #expect(String(cString: lua_tostring(L, -1)!) == "NSURL")
                lua_pop(L, 2)

                lua_rawgeti(L, -1, 2)
                #expect(toNSImage(L, at: -1) != nil)
                lua_pop(L, 1)

                lua_rawgeti(L, -1, 3)
                #expect(toNSAttributedString(L, at: -1)?.string == "styled share")
                lua_pop(L, 1)

                lua_rawgeti(L, -1, 4)
                #expect(lua_tostringValue(L, at: -1) == "plain")
                lua_pop(L, 1)
            }
        }

        @Test func testSerialPushHelperProducesTypedUserdata() throws {
            try withBootstrappedLua(requiring: ["hs.serial"]) { L in
                let serialPort = HSSerialPort()
                #expect(pushHSSerialPort(L, serialPort) == 1)
                #expect(luaL_testudata(L, -1, "hs.serial") != nil)
                #expect(lua_toAnyObject(L, at: -1) as? HSSerialPort === serialPort)
                lua_pop(L, 1)
            }
        }

        @Test func testRazerModuleHardwareTolerantDeviceLookup() {
            let result = runLua("""
                local razer = require('hs.razer')
                local ok, err = pcall(function()
                    razer.init(function() end)
                end)
                if not ok then return 'init-error:' .. tostring(err) end
                local count = razer.numDevices()
                local dev = razer.getDevice(1)
                return table.concat({
                    type(count),
                    dev == nil and 'nil' or type(dev),
                }, ':')
                """)
            let parts = result?.split(separator: ":").map(String.init)
            if let parts, parts.count == 2 {
                #expect(parts[0] == "number")
                #expect(["nil", "userdata"].contains(parts[1]))
            } else {
                #expect(parts?.count == 2, "Lua result: \(result ?? "nil")")
            }
        }

        @Test func testStreamDeckModuleHardwareTolerantDeviceLookup() {
            let result = runLua("""
                local streamdeck = require('hs.streamdeck')
                local ok, err = pcall(function()
                    streamdeck.init(function() end)
                end)
                if not ok then return 'init-error:' .. tostring(err) end
                local count = streamdeck.numDevices()
                local dev = streamdeck.getDevice(1)
                return table.concat({
                    type(count),
                    dev == nil and 'nil' or type(dev),
                }, ':')
                """)
            let parts = result?.split(separator: ":").map(String.init)
            if let parts, parts.count == 2 {
                #expect(parts[0] == "number")
                #expect(["nil", "userdata"].contains(parts[1]))
            } else {
                #expect(parts?.count == 2, "Lua result: \(result ?? "nil")")
            }
        }
    }
}
