import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Window {
        init() throws { try loadLuaModule("test_window") }

        @Test func testNewFormatWindowUserdataUielementMethodsDoNotCrash() {
            let result = runLua("""
                local _ = hs.window
                hs.application.launchOrFocusByBundleID("com.apple.safari")
                local app = hs.application.applicationsForBundleID("com.apple.safari")[1]
                if app == nil then return "no app" end
                local wins = app:allWindows()
                if #wins == 0 then return "no windows" end
                local w = wins[1]
                local ok, err = pcall(function() return w:isWindow() end)
                if not ok then return "crash: " .. tostring(err) end
                return "ok"
            """)
            #expect(result == "ok",
                    "uielement method on new-format window userdata must not crash: \(result ?? "nil")")
        }

        @Test func testNewFormatWindowUserdataEqualityDoesNotCrash() {
            let result = runLua("""
                local _ = hs.window
                hs.application.launchOrFocusByBundleID("com.apple.safari")
                local app = hs.application.applicationsForBundleID("com.apple.safari")[1]
                if app == nil then return "no app" end
                local wins = app:allWindows()
                if #wins == 0 then return "no windows" end
                local w1 = wins[1]
                local w2 = wins[1]
                local ok, err = pcall(function() return w1 == w2 end)
                if not ok then return "crash: " .. tostring(err) end
                return "ok"
            """)
            #expect(result == "ok",
                    "equality on new-format window userdata must not crash: \(result ?? "nil")")
        }

        @Test func testWindowActionsRecordTelemetrySpans() {
            bootstrapLuaForTesting()
            let L = lua_getCurrentState()!
            let sim = environmentGet(L).telemetry as! SimulatedTelemetry
            sim.configure(TelemetryConfiguration(enabled: true))
            let initialSpanCount = sim.spans.count

            let result = runLua("""
                local window = require("hs.libwindow")
                local windows = window._allWindows()
                local w = windows[1]
                if w == nil then return "no windows" end
                w:raise()
                w:_setTopLeft({ x = 123, y = 456 })
                return "ok"
            """)

            #expect(result == "ok")
            let newSpans = Array(sim.spans.dropFirst(initialSpanCount))
            let raiseSpan = newSpans.first { $0.name == "hs.window.raise" }
            let moveSpan = newSpans.first { $0.name == "hs.window.setTopLeft" }
            #expect(raiseSpan?.attributes["cosmichammer.ui.action"] == "raise")
            #expect(raiseSpan?.attributes["cosmichammer.ui.action.success"] == "true")
            #expect(raiseSpan?.attributes["cosmichammer.window.id"] != nil)
            #expect(raiseSpan?.attributes["process.pid"] != nil)
            #expect(raiseSpan?.attributes["ui.action"] == nil)
            #expect(raiseSpan?.attributes["window.id"] == nil)
            #expect(raiseSpan?.ended == true)
            #expect(moveSpan?.attributes["cosmichammer.ui.action"] == "setTopLeft")
            #expect(moveSpan?.attributes["cosmichammer.ui.action.success"] == "true")
            #expect(moveSpan?.ended == true)
            #expect(sim.metrics.allSatisfy {
                $0.attributes["cosmichammer.window.id"] == nil
                    && $0.attributes["process.pid"] == nil
            })
            #expect(sim.logs.allSatisfy {
                $0.attributes["cosmichammer.window.id"] == nil
                    && $0.attributes["process.pid"] == nil
            })
        }

        @Test func testAllWindows() { runLuaTest() }
        @Test(.skipInHeadless) func testDesktop() { runLuaTest() }
        @Test(.skipInHeadless) func testOrderedWindows() { runLuaTest() }
        @Test func testFocusedWindow() { runLuaTest() }
        @Test(.skipInHeadless) func testSnapshots() { runLuaTest() }
        @Test func testTitle() { runLuaTest() }
        @Test(.skipInHeadless) func testRoles() { runLuaTest() }
        @Test func testTopLeft() { runLuaTest() }
        @Test(.skipInHeadless) func testSize() { runLuaTest() }
        @Test(.skipInHeadless) func testMinimize() { runLuaTest() }
        @Test func testPID() { runLuaTest() }
        @Test func testApplication() { runLuaTest() }
        @Test(.requiresRealOS) func testTabs() { runLuaTest() }
        @Test(.skipInHeadless) func testClose() { runLuaTest() }
        @Test(.skipInHeadless) func testFullscreen() { runLuaTest() }

        @Test(.skipInHeadless) func testFullscreenOne() {
            luaTestWithCheckAndTimeout(5, setup: "testFullscreenOneSetup()", check: "testFullscreenOneResult()")
        }

        @Test func testFullscreenTwo() {
            luaTestWithCheckAndTimeout(5, setup: "testFullscreenTwoSetup()", check: "testFullscreenTwoResult()")
        }
    }
}
