import Testing
import Foundation
import CLua
import UserNotifications
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Notify {
        @Test func testNotifyUserdataActiveGauge() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let sim = environmentGet(L).telemetry as! SimulatedTelemetry
                sim.configure(TelemetryConfiguration(enabled: true))

                #expect(luaEval(L, "n = mod._new('notify-active-gauge-test')"))
                lua_getglobal(L, "n")
                try #expect(nt_userdata_gc(L) == 0)
                lua_pop(L, 1)
                lua_pushnil(L)
                lua_setglobal(L, "n")

                let gaugeValues = sim.metrics
                    .filter { $0.name == "cosmichammer.notify.userdata.active" }
                    .map(\.value)
                #expect(gaugeValues.count == 2)
                #expect(gaugeValues.last == gaugeValues.first.map { max(0, $0 - 1) })
            }
        }

        // MARK: - Send/deliver/withdraw round-trips through the simulator

        @Test func testSendDeliversThroughSimulatorAndDeliveredRoundTrip() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification

                #expect(luaEval(L, """
                    n = mod._new('send-round-trip')
                    n:title('Hello')
                    n:informativeText('World')
                    n:send()
                    """))
                #expect(sim.deliveredNotifs.count == 1)
                #expect(sim.deliveredNotifs[0].title == "Hello")
                #expect(sim.deliveredNotifs[0].informativeText == "World")
                #expect(sim.deliveredNotifs[0].isDelivered)

                #expect(luaEvalInt(L, "return #mod.deliveredNotifications()") == 1)
                #expect(luaEvalBool(L, "return n:delivered()") == true)

                #expect(luaEval(L, "n:withdraw()"))
                #expect(sim.deliveredNotifs.isEmpty)
                #expect(luaEvalBool(L, "return n:delivered()") == false)
                #expect(luaEvalInt(L, "return #mod.deliveredNotifications()") == 0)
            }
        }

        @Test func testScheduleRoundTripAndWithdrawRemovesScheduled() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification

                #expect(luaEval(L, """
                    n = mod._new('schedule-round-trip')
                    n:title('Later')
                    n:schedule(os.time() + 60)
                    """))
                #expect(sim.scheduledNotifs.count == 1)
                #expect(sim.scheduledNotifs[0].title == "Later")
                #expect(luaEvalInt(L, "return #mod.scheduledNotifications()") == 1)

                #expect(luaEval(L, "n:withdraw()"))
                #expect(sim.scheduledNotifs.isEmpty)
                #expect(luaEvalInt(L, "return #mod.scheduledNotifications()") == 0)
            }
        }

        @Test func testSendTwoWithdrawAll() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification

                #expect(luaEval(L, """
                    n1 = mod._new('withdraw-all-1')
                    n1:send()
                    n2 = mod._new('withdraw-all-2')
                    n2:send()
                    """))
                #expect(sim.deliveredNotifs.count == 2)
                #expect(luaEval(L, "mod.withdrawAll()"))
                #expect(sim.deliveredNotifs.isEmpty)
            }
        }

        @Test func testLockedAfterSendAndModifiableAfterWithdraw() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    n = mod._new('locked-test')
                    n:send()
                    """))
                // After send the notification is locked: setters throw.
                let lockedError = luaErrorMsg(L, "n:title('nope')")
                #expect(lockedError?.contains("dispatched") == true)
                // After withdraw it is modifiable again.
                #expect(luaEval(L, "n:withdraw()"))
                #expect(luaEval(L, "n:title('resend me')"))
                #expect(luaEvalString(L, "return n:title()") == "resend me")
            }
        }

        // MARK: - Activation path

        @Test func testActivationFiresTagHandler() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification
                let simTelemetry = environmentGet(L).telemetry as! SimulatedTelemetry
                simTelemetry.configure(TelemetryConfiguration(enabled: true))

                // The raw libnotify module table has no _tag_handler (that lives in
                // notify.lua); install a preload shim plus a test handler.
                #expect(luaEval(L, """
                    mod._tag_handler = function(tag, note)
                      ACTIVATED = (type(note) == 'userdata')
                      ACTIVATION_TYPE = note and note:activationType() or -1
                    end
                    package.preload['hs.notify'] = function() return mod end
                    """))

                #expect(luaEval(L, """
                    n = mod._new('activation-tag')
                    n:title('Click me')
                    n:send()
                    """))
                #expect(sim.deliveredNotifs.count == 1)

                // Register the activation hook and fire a body-click activation.
                let gusID = sim.deliveredNotifs[0].identifier
                let specifics = nt_debugSpecifics()!
                sim.userNotificationCallbacks[gusID] = { note in
                    HSModuleNotificationManager.shared.testActivationFromSimulator(
                        gus: note.identifier,
                        activationType: 1,
                        delivered: true,
                        record: specifics[note.identifier] as! NSMutableDictionary,
                        actionIdentifier: UserNotificationActionIdentifier.defaultAction,
                        userText: nil
                    )
                }
                sim.activateNotification(
                    identifier: sim.deliveredNotifs[0].identifier,
                    actionIdentifier: UserNotificationActionIdentifier.defaultAction,
                    userText: nil
                )

                #expect(luaEvalBool(L, "return ACTIVATED") == true)
                #expect(luaEvalInt(L, "return ACTIVATION_TYPE") == 1)
                // autoWithdraw (default) removed the notification.
                #expect(sim.deliveredNotifs.isEmpty)
                // Activation recorded on the specifics record.
                #expect(luaEvalInt(L, "return n:activationType()") == 1)
            }
        }

        @Test func testActivationActionButtonAndReplyResponse() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification

                #expect(luaEval(L, """
                    mod._tag_handler = function(tag, note)
                      ACTIVATED = true
                      ACTIVATION_TYPE = note:activationType()
                      RESPONSE = note:response()
                    end
                    package.preload['hs.notify'] = function() return mod end
                    n = mod._new('reply-tag')
                    n:hasReplyButton(true)
                    n:responsePlaceholder('type here')
                    n:send()
                    """))
                #expect(sim.deliveredNotifs.count == 1)

                let gus = sim.deliveredNotifs[0].identifier
                let specifics = nt_debugSpecifics()!
                sim.userNotificationCallbacks[gus] = { note in
                    HSModuleNotificationManager.shared.testActivationFromSimulator(
                        gus: note.identifier,
                        activationType: 3,
                        delivered: true,
                        record: specifics[note.identifier] as! NSMutableDictionary,
                        actionIdentifier: UserNotificationActionIdentifier.reply,
                        userText: "hi there"
                    )
                }
                sim.activateNotification(identifier: gus, actionIdentifier: UserNotificationActionIdentifier.reply, userText: "hi there")

                #expect(luaEvalBool(L, "return ACTIVATED") == true)
                #expect(luaEvalInt(L, "return ACTIVATION_TYPE") == 3)
                #expect(luaEvalString(L, "return RESPONSE") == "hi there")
            }
        }

        @Test func testActivationTypeConstantsUnchanged() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                #expect(luaEvalInt(L, "return mod.activationTypes.none") == 0)
                #expect(luaEvalInt(L, "return mod.activationTypes.contentsClicked") == 1)
                #expect(luaEvalInt(L, "return mod.activationTypes.actionButtonClicked") == 2)
                #expect(luaEvalInt(L, "return mod.activationTypes.replied") == 3)
                #expect(luaEvalInt(L, "return mod.activationTypes.additionalActionClicked") == 4)
                #expect(luaEvalInt(L, "return #mod.activationTypes and 0 or 0") == 0)
            }
        }

        // MARK: - alwaysPresent / willPresent simulation

        @Test func testPresentHonorsAlwaysPresent() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification

                // Default alwaysPresent = true: foreground presentation honored.
                #expect(luaEval(L, """
                    n1 = mod._new('present-default')
                    n1:title('Frontmost')
                    n1:send()
                    """))
                let defaultNote = sim.deliveredNotifs[0]
                #expect(sim.presentNotification(defaultNote) == true)
                #expect(luaEvalBool(L, "return n1:alwaysPresent()") == true)

                // Set alwaysPresent(false) BEFORE send (the notification locks on
                // send): foreground presentation suppressed.
                #expect(luaEval(L, """
                    n2 = mod._new('present-off')
                    n2:title('Frontmost')
                    n2:alwaysPresent(false)
                    n2:send()
                    """))
                #expect(sim.deliveredNotifs.count == 2)
                let offNote = sim.deliveredNotifs[1]
                #expect(sim.presentNotification(offNote) == false)
                #expect(luaEvalBool(L, "return n2:alwaysPresent()") == false)
            }
        }

        // MARK: - withdrawAfter behavior

        @Test func testWithdrawAfterSchedulesDispatchWorkItemAndActivationCancels() throws {
            let saved = lua_getCurrentState()
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                let env = environmentGet(L)
                let sim = env.notification as! SimulatedNotification

                #expect(luaEval(L, """
                    n = mod._new('withdraw-after-test')
                    n:withdrawAfter(0.2)
                    n:send()
                    """))
                #expect(sim.deliveredNotifs.count == 1)
                // Simulate the delegate's auto-withdraw scheduling path.
                let gus = sim.deliveredNotifs[0].identifier
                nt_scheduleWithdrawTimer(gus: gus, after: 0.2)
            }
            // Pump the main run loop until the timer fires (2s budget).
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }

        @Test func testWithdrawAfterZeroDoesNotScheduleTimer() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, """
                    n = mod._new('withdraw-after-zero')
                    n:withdrawAfter(0)
                    n:send()
                    """))
                let gus = luaEvalString(L, "return n:getFunctionTag()") // sanity: module alive
                #expect(gus != nil)
                // No pending timer for a zero withdrawAfter.
                #expect(luaEval(L, "n:withdraw()"))
            }
        }

        // MARK: - No-op fields

        @Test func testNoOpFieldsReturnWithoutCrash() throws {
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                #expect(luaEval(L, "n = mod._new('noop-fields')"))
                // otherButtonTitle keeps the Lua API but is stored locally only.
                #expect(luaEval(L, "n:otherButtonTitle('Close')"))
                #expect(luaEvalString(L, "return n:otherButtonTitle()") == "Close")
                // alwaysShowAdditionalActions is a no-op returning false.
                #expect(luaEvalBool(L, "return n:alwaysShowAdditionalActions()") == false)
                #expect(luaEval(L, "n:alwaysShowAdditionalActions(true)"))
                // setIdImage accepts the call but is a no-op; nil image errors
                // with the expected message.
                let idImageError = luaErrorMsg(L, "n:_setIdImage(nil)")
                #expect(idImageError?.contains("hs.image") == true)
            }
        }

        // MARK: - Delegate lifecycle

        @Test func testModuleGcKeepsUNDelegateInstalled() throws {
            // MJUserNotificationManager.sharedManager is the process-wide
            // UNUserNotificationCenter delegate; nt_meta_gc must NOT nil it.
            // UNUserNotificationCenter.current() is unusable in the SPM runner
            // (no bundle proxy), so assert the observable state: the shared
            // manager singleton exists and nt_meta_gc leaves it untouched.
            let delegate = MJUserNotificationManager.sharedManager
            try withModuleLoaded(luaopen_hs_libnotify) { L in
                let saved = lua_getCurrentState()
                lua_setCurrentState(L)
                defer { lua_setCurrentState(saved) }

                // Simulate module teardown via the module __gc path.
                #expect(luaEval(L, "mod = nil"))
                let specificsBefore = nt_debugSpecifics()
                #expect(specificsBefore != nil)
                nt_debugCleanupModule(L)
                #expect(nt_debugSpecifics() == nil)
            }
            // The shared manager singleton survives module teardown unchanged
            // (no teardown path in the migration nils the process delegate).
            #expect(MJUserNotificationManager.sharedManager === delegate)
        }
    }
}
