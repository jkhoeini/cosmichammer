import Testing
import Foundation
import AppKit
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite("DST Pasteboard Watcher Integration") final class DSTPasteboardWatcherIntegrationTests {

        // MARK: - Swift-level: Clock + Pasteboard + Timer cross-subsystem

        @Test func watcherDetectsChangeAfterTimerFires() {
            // Set up a simulated environment with accessible harness
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard as! SimulatedPasteboard

            // Create a watcher directly at the Swift level
            var callbackFired = false
            var detectedChangeCount = 0

            let timer = env.clock.createTimer(interval: 0.25, repeats: true) {
                let current = pb.changeCount
                if current != detectedChangeCount {
                    detectedChangeCount = current
                    callbackFired = true
                }
            }
            timer.schedule()

            // No change yet — timer should fire but detect no change
            harness.advanceTime(by: 0.3)
            #expect(!callbackFired)

            // Now change pasteboard contents
            _ = pb.setString("hello world", forType: "public.utf8-plain-text")
            #expect(pb.changeCount == 1)

            // Advance past the next poll interval
            harness.advanceTime(by: 0.3)
            #expect(callbackFired)
            #expect(detectedChangeCount == 1)
        }

        @Test func watcherDoesNotFireWhenPasteboardUnchanged() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard as! SimulatedPasteboard

            var fireCount = 0
            var lastSeen = pb.changeCount

            let timer = env.clock.createTimer(interval: 0.25, repeats: true) {
                let current = pb.changeCount
                if current != lastSeen {
                    lastSeen = current
                    fireCount += 1
                }
            }
            timer.schedule()

            // Advance several polling intervals without changing pasteboard
            harness.advanceTime(by: 2.0)
            #expect(fireCount == 0)
        }

        @Test func watcherDetectsMultipleChanges() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard as! SimulatedPasteboard

            var detectedValues: [String] = []
            var lastSeen = pb.changeCount

            let timer = env.clock.createTimer(interval: 0.25, repeats: true) {
                let current = pb.changeCount
                if current != lastSeen {
                    lastSeen = current
                    if let s = pb.string(forType: "public.utf8-plain-text") {
                        detectedValues.append(s)
                    }
                }
            }
            timer.schedule()

            // First change
            _ = pb.setString("first", forType: "public.utf8-plain-text")
            harness.advanceTime(by: 0.3)

            // Second change
            _ = pb.setString("second", forType: "public.utf8-plain-text")
            harness.advanceTime(by: 0.3)

            // Third change
            _ = pb.setString("third", forType: "public.utf8-plain-text")
            harness.advanceTime(by: 0.3)

            #expect(detectedValues == ["first", "second", "third"])
        }

        @Test func watcherStopsAfterTimerInvalidated() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard as! SimulatedPasteboard

            var fireCount = 0
            var lastSeen = pb.changeCount

            let timer = env.clock.createTimer(interval: 0.25, repeats: true) {
                let current = pb.changeCount
                if current != lastSeen {
                    lastSeen = current
                    fireCount += 1
                }
            }
            timer.schedule()

            _ = pb.setString("before stop", forType: "public.utf8-plain-text")
            harness.advanceTime(by: 0.3)
            #expect(fireCount == 1)

            // Invalidate the timer (watcher stopped)
            timer.invalidate()

            // Change pasteboard again — should not be detected
            _ = pb.setString("after stop", forType: "public.utf8-plain-text")
            harness.advanceTime(by: 0.5)
            #expect(fireCount == 1)
        }

        @Test func watcherIgnoresPasteboardFaultDuringPoll() {
            var faults = FaultConfig()
            faults.pasteboardUnavailable = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let pb = env.pasteboard as! SimulatedPasteboard

            var fireCount = 0
            var lastSeen = pb.changeCount

            let timer = env.clock.createTimer(interval: 0.25, repeats: true) {
                let current = pb.changeCount
                if current != lastSeen {
                    lastSeen = current
                    fireCount += 1
                }
            }
            timer.schedule()

            // setString returns false under fault, changeCount stays at 0
            let result = pb.setString("test", forType: "public.utf8-plain-text")
            #expect(!result)
            #expect(pb.changeCount == 0)

            harness.advanceTime(by: 0.5)
            #expect(fireCount == 0)
        }

        // MARK: - HSPasteboardTimer Swift-level (no Lua callback, just verifying schedule fix)

        @Test func hsPasteboardTimerSchedulesOnStart() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let timer = HSPasteboardTimer()
            timer.pasteboard = env.pasteboard
            timer.clock = env.clock

            timer.start()

            #expect(timer.isRunning)
            #expect(timer.timerHandle != nil)
            #expect(timer.timerHandle?.isScheduled == true)
        }

        @Test func hsPasteboardTimerStopInvalidatesTimer() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let timer = HSPasteboardTimer()
            timer.pasteboard = env.pasteboard
            timer.clock = env.clock

            timer.start()
            #expect(timer.isRunning)

            timer.stop()
            #expect(!timer.isRunning)
            #expect(timer.timerHandle == nil)
        }

        @Test func hsPasteboardTimerTracksChangeCount() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard as! SimulatedPasteboard

            let timer = HSPasteboardTimer()
            timer.pasteboard = env.pasteboard
            timer.clock = env.clock

            // Set initial content before starting watcher
            _ = pb.setString("initial", forType: "public.utf8-plain-text")

            timer.start()

            // changeCount should be captured at start
            #expect(timer.changeCount == pb.changeCount)
        }

        // MARK: - Lua-level integration: watcher.new through Lua API

        /// Helper: create a Lua state with simulated environment and current-state
        /// tracking set up so that HSPasteboardTimer.pollPasteboard() can call
        /// lua_getCurrentState() and lua_isStateGenerationValid().
        /// Returns (L, harness) so tests can advance time.
        private func withPasteboardWatcherLuaState(
            _ body: (UnsafeMutablePointer<lua_State>, SimulatorHarness, SimulatedPasteboard) throws -> Void
        ) rethrows {
            globalEnvLock.lock()
            let L = luaL_newstate()!
            luaL_openlibs(L)
            let harness = SimulatorHarness(seed: 42)
            let simEnv = harness.createEnvironment()
            let pb = simEnv.pasteboard as! SimulatedPasteboard
            environmentAttach(L, simEnv)
            environmentSetGlobal(simEnv)

            // Register L as the "current" Lua state so pollPasteboard() can find it
            let prevState = lua_getCurrentState()
            lua_setCurrentState(L)
            lua_bumpStateGeneration()

            defer {
                lua_setCurrentState(prevState)
                environmentClearGlobal()
                environmentDetach(L)
                lua_close(L)
                globalEnvLock.unlock()
            }

            _ = luaopen_hs_libpasteboardwatcher(L)
            lua_setglobal(L, "pbwatcher")

            try body(L, harness, pb)
        }

        @Test func luaPasteboardWatcherNewCreatesRunningWatcher() {
            withPasteboardWatcherLuaState { L, _, _ in
                let ok = luaEval(L, """
                    _watcher = pbwatcher.new(function(contents) end)
                """)
                #expect(ok, "Lua watcher creation should succeed")

                let running = luaEvalBool(L, "return _watcher:running()")
                #expect(running == true)
            }
        }

        @Test func luaPasteboardWatcherActiveGauge() {
            withPasteboardWatcherLuaState { L, _, _ in
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                let ok = luaEval(L, """
                    _watcher = pbwatcher.new(function(contents) end)
                    _watcher:start()
                    _watcher:stop()
                    _watcher:stop()
                """)
                #expect(ok)

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.pasteboard.watcher.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        @Test func luaPasteboardWatcherFiresCallbackOnChange() {
            withPasteboardWatcherLuaState { L, harness, pb in
                let ok = luaEval(L, """
                    _callbackCount = 0
                    _lastContent = nil
                    _watcher = pbwatcher.new(function(contents)
                        _callbackCount = _callbackCount + 1
                        _lastContent = contents
                    end)
                """)
                #expect(ok, "Lua watcher creation should succeed")

                // Change pasteboard contents via the simulated pasteboard
                _ = pb.setString("hello from test", forType: "public.utf8-plain-text")

                // Advance time past the default polling interval (0.25s)
                harness.advanceTime(by: 0.3)

                // Verify callback was invoked
                let count = luaEvalInt(L, "return _callbackCount")
                #expect(count == 1, "Watcher callback should fire once after pasteboard change")

                let content = luaEvalString(L, "return _lastContent")
                #expect(content == "hello from test", "Callback should receive the pasteboard content")
            }
        }

        @Test func luaPasteboardWatcherDoesNotFireWithoutChange() {
            withPasteboardWatcherLuaState { L, harness, _ in
                let ok = luaEval(L, """
                    _callbackCount = 0
                    _watcher = pbwatcher.new(function(contents)
                        _callbackCount = _callbackCount + 1
                    end)
                """)
                #expect(ok)

                // Advance time without changing pasteboard
                harness.advanceTime(by: 1.0)

                let count = luaEvalInt(L, "return _callbackCount")
                #expect(count == 0, "Watcher should not fire when pasteboard hasn't changed")
            }
        }

        @Test func luaPasteboardWatcherStopPreventsCallback() {
            withPasteboardWatcherLuaState { L, harness, pb in
                let ok = luaEval(L, """
                    _callbackCount = 0
                    _watcher = pbwatcher.new(function(contents)
                        _callbackCount = _callbackCount + 1
                    end)
                """)
                #expect(ok)

                // Stop the watcher
                #expect(luaEval(L, "_watcher:stop()"))

                // Change pasteboard and advance time
                _ = pb.setString("should not detect", forType: "public.utf8-plain-text")
                harness.advanceTime(by: 0.5)

                let count = luaEvalInt(L, "return _callbackCount")
                #expect(count == 0, "Stopped watcher should not fire callback")
            }
        }

        @Test func luaPasteboardWatcherDetectsMultipleChanges() {
            withPasteboardWatcherLuaState { L, harness, pb in
                let ok = luaEval(L, """
                    _callbackCount = 0
                    _contents = {}
                    _watcher = pbwatcher.new(function(contents)
                        _callbackCount = _callbackCount + 1
                        _contents[#_contents + 1] = contents or "nil"
                    end)
                """)
                #expect(ok)

                // First change + poll
                _ = pb.setString("alpha", forType: "public.utf8-plain-text")
                harness.advanceTime(by: 0.3)

                // Second change + poll
                _ = pb.setString("beta", forType: "public.utf8-plain-text")
                harness.advanceTime(by: 0.3)

                let count = luaEvalInt(L, "return _callbackCount")
                #expect(count == 2, "Watcher should detect both pasteboard changes")

                let first = luaEvalString(L, "return _contents[1]")
                let second = luaEvalString(L, "return _contents[2]")
                #expect(first == "alpha")
                #expect(second == "beta")
            }
        }
    }
}
