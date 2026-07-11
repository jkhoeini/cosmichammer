import Testing
import HSDSTCore
import HSDSTSimulator

extension CosmicHammerTests {
    @Suite("DST Input Simulator") final class DSTInputTests {
        private let commandModifier: UInt32 = 256
        private let commandEventFlag: UInt64 = 0x100000

        @Test func duplicateHotkeyCombinationIsRejectedWithoutReplacingOwner() {
            let harness = SimulatorHarness(seed: 42)
            let input = harness.createEnvironment().input
            var callbacks: [UInt32] = []

            #expect(input.registerHotkey(id: 1, keyCode: 12, mods: commandModifier) { id, _ in
                callbacks.append(UInt32(id))
            })
            #expect(!input.registerHotkey(id: 2, keyCode: 12, mods: commandModifier) { id, _ in
                callbacks.append(UInt32(id))
            })

            let event = input.createKeyboardEvent(keyCode: 12, keyDown: true, flags: commandEventFlag)
            #expect(input.postEvent(event, tapLocation: 0))
            #expect(callbacks == [1])
        }

        @Test func hotkeyRegistrationPersistsAcrossEnvironmentsUntilUnregistered() {
            let harness = SimulatorHarness(seed: 42)
            let firstInput = harness.createEnvironment().input
            let secondInput = harness.createEnvironment().input
            var callbackCount = 0

            #expect(firstInput.registerHotkey(id: 1, keyCode: 12, mods: commandModifier) { _, _ in
                callbackCount += 1
            })
            #expect(!secondInput.registerHotkey(id: 2, keyCode: 12, mods: commandModifier) { _, _ in })

            let event = secondInput.createKeyboardEvent(keyCode: 12, keyDown: true, flags: commandEventFlag)
            #expect(secondInput.postEvent(event, tapLocation: 0))
            #expect(callbackCount == 1)

            firstInput.unregisterHotkey(id: 1)
            #expect(secondInput.registerHotkey(id: 2, keyCode: 12, mods: commandModifier) { _, _ in })
        }
        @Test func onlyRegisteringInputCanUnregisterHotkey() {
            let harness = SimulatorHarness(seed: 42)
            let firstInput = harness.createEnvironment().input
            let secondInput = harness.createEnvironment().input

            #expect(firstInput.registerHotkey(id: 1, keyCode: 12, mods: commandModifier) { _, _ in })

            secondInput.unregisterHotkey(id: 1)
            #expect(!secondInput.registerHotkey(id: 2, keyCode: 12, mods: commandModifier) { _, _ in })

            firstInput.unregisterHotkey(id: 1)
            #expect(secondInput.registerHotkey(id: 2, keyCode: 12, mods: commandModifier) { _, _ in })
        }
        @Test func systemReservedHotkeysAreConfigurableState() {
            let combo = SimulatedInput.SystemHotkeyCombo(keyCode: 12, mods: commandModifier)
            let reservedInput = SimulatorHarness(
                seed: 42,
                systemReservedHotkeys: [combo]
            ).createEnvironment().input
            let availableInput = SimulatorHarness(
                seed: 42,
                systemReservedHotkeys: []
            ).createEnvironment().input

            #expect(!reservedInput.registerHotkey(id: 1, keyCode: 12, mods: commandModifier) { _, _ in })
            #expect(availableInput.registerHotkey(id: 1, keyCode: 12, mods: commandModifier) { _, _ in })
        }
    }
}
