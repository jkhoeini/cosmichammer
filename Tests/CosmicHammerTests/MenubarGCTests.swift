import Testing
import Cocoa
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class MenubarGCTests {

        // MARK: - GC safety: menubaritem_gc must not crash

        /// Create a menubar item, call delete(), nil the ref, force GC.
        /// Before fix: lua_call from within __gc corrupts the allocator.
        /// After fix: menubar_delete is called directly as Swift — no lua_call.
        @Test func menubarDeleteThenGCDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    local item = mod.new(false)
                    item:delete()
                    item = nil
                    collectgarbage()
                    collectgarbage()
                """), "menubar delete then GC should not crash")
            }
        }

        /// Create a menubar item, nil the ref, force GC (no explicit delete).
        /// The GC finalizer itself must clean up without lua_call.
        @Test func menubarGCWithoutDeleteDoesNotCrash() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    local item = mod.new(false)
                    item = nil
                    collectgarbage()
                    collectgarbage()
                """), "menubar GC without explicit delete should not crash")
            }
        }

        // MARK: - tostring safety after delete

        /// After delete(), tostring should return a "(deleted)" marker
        /// instead of force-unwrapping nil.
        @Test func menubarToStringAfterDeleteReturnsDeletedMarker() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let result = luaEvalString(L, """
                    local item = mod.new(false)
                    item:delete()
                    return tostring(item)
                """)
                #expect(result != nil, "tostring after delete should return a string")
                if let result = result {
                    #expect(result.contains("(deleted)"),
                            "tostring after delete should contain '(deleted)', got: \(result)")
                }
            }
        }

        // MARK: - mb_dynamicMenuDelegates nil safety

        /// Verify that mb_erase_menu_delegate does not crash when
        /// mb_dynamicMenuDelegates is nil (which happens when the module-level
        /// __gc fires before individual item __gc finalizers).
        @Test func menubarDynamicMenuDelegatesNilSafe() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                // Create an empty NSMenu and call mb_erase_menu_delegate
                // with mb_dynamicMenuDelegates set to nil to simulate
                // module GC having run first.
                // Before fix: force-unwrap of nil IUO crashes.
                // After fix: optional chaining is a no-op.
                let menu = NSMenu(title: "test")
                // Access the global var through a helper to satisfy Swift 6.
                menubarGCTest_eraseMenuDelegateWithNilDelegates(L, menu)
                // If we reach here, the nil guard works.
            }
        }

        @Test func menubarClickCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                adjustMenubarClickCallbackCount(-1_000, L: L)
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local item = mod.new(false)
                    item:setClickCallback(function() end)
                    item:setClickCallback(nil)
                    item:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.menubar.click.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 0])
            }
        }

        @Test func menubarDynamicMenuCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                adjustMenubarDynamicMenuCallbackCount(-1_000, L: L)
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local item = mod.new(false)
                    item:setMenu(function() return {} end)
                    item:setMenu(nil)
                    item:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.menubar.dynamic_menu.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 0])
            }
        }

        @Test func menubarMenuItemCallbackActiveGauge() {
            withModuleLoaded(luaopen_hs_libmenubar) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                adjustMenubarMenuItemCallbackCount(-1_000, L: L)
                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, """
                    local item = mod.new(false)
                    item:setMenu({
                        { title = "A", fn = function() end },
                    })
                    item:setMenu(nil)
                    item:delete()
                """))

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.menubar.menu_item.callback.active" }
                    .map(\.value)
                #expect(gaugeValues == [1, 0])
            }
        }
    }
}
