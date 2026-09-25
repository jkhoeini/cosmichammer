import Testing
import CoreGraphics
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite final class SpaceDisplayLifecycleTests {
        @Test func spaceLifecycleCallbacksPreserveRegistrationOrderAndRemoval() {
            let spaces = SimulatorHarness(seed: 42).createEnvironment().spaces as! SimulatedSpaces
            var received: [String] = []
            let first = spaces.addSpaceLifecycleCallback { event in
                received.append("first:\(event.kind.rawValue):\(event.spaceID)")
            }
            _ = spaces.addSpaceLifecycleCallback { event in
                received.append("second:\(event.kind.rawValue):\(event.spaceID)")
            }

            spaces.simulateSpaceLifecycleEvent(.init(kind: .created, spaceID: 7))
            #expect(received == ["first:created:7", "second:created:7"])
            #expect(spaces.removeSpaceLifecycleCallback(id: first))
            #expect(!spaces.removeSpaceLifecycleCallback(id: first))

            spaces.simulateSpaceLifecycleEvent(.init(kind: .destroyed, spaceID: 7))
            #expect(received == [
                "first:created:7", "second:created:7", "second:destroyed:7",
            ])
        }

        @Test func displayCallbacksCoverEveryKindAndStopAfterRemoval() {
            let screen = SimulatorHarness(seed: 42).createEnvironment().screen as! SimulatedScreen
            var received: [DisplayReconfigurationEvent] = []
            let callbackID = screen.addDisplayReconfigurationCallback { received.append($0) }
            let events = DisplayReconfigurationEvent.Kind.allCasesForTesting.map {
                DisplayReconfigurationEvent(kind: $0, displayID: 9)
            }

            for event in events {
                screen.simulateDisplayReconfigurationEvent(event)
            }
            #expect(received == events)
            #expect(screen.removeDisplayReconfigurationCallback(id: callbackID))
            #expect(!screen.removeDisplayReconfigurationCallback(id: callbackID))

            screen.simulateDisplayReconfigurationEvent(.init(kind: .added, displayID: 10))
            #expect(received == events)
        }

        @Test func spaceNotificationDecodeRejectsBadPayloads() {
            var rawID: UInt64 = 42
            withUnsafePointer(to: &rawID) { pointer in
                #expect(decodeSpaceLifecycleNotification(
                    type: 1327, data: pointer, length: MemoryLayout<UInt64>.size
                ) == .init(kind: .created, spaceID: 42))
                #expect(decodeSpaceLifecycleNotification(
                    type: 1328, data: pointer, length: MemoryLayout<UInt64>.size
                ) == .init(kind: .destroyed, spaceID: 42))
                #expect(decodeSpaceLifecycleNotification(
                    type: 999, data: pointer, length: MemoryLayout<UInt64>.size
                ) == nil)
                #expect(decodeSpaceLifecycleNotification(
                    type: 1327, data: pointer, length: MemoryLayout<UInt64>.size - 1
                ) == nil)
            }
            #expect(decodeSpaceLifecycleNotification(type: 1327, data: nil, length: 8) == nil)
        }

        @Test func spaceLifecycleGuardsFilterNoiseAndDeduplicate() {
            var known: Set<Int> = [1]
            #expect(!acceptedSpaceLifecycleEvent(
                .init(kind: .created, spaceID: 2), knownSpaceIDs: &known,
                createdSpaceType: .system))
            #expect(known == [1])
            #expect(acceptedSpaceLifecycleEvent(
                .init(kind: .created, spaceID: 2), knownSpaceIDs: &known,
                createdSpaceType: .user))
            #expect(!acceptedSpaceLifecycleEvent(
                .init(kind: .created, spaceID: 2), knownSpaceIDs: &known,
                createdSpaceType: .user))
            #expect(!acceptedSpaceLifecycleEvent(
                .init(kind: .destroyed, spaceID: 3), knownSpaceIDs: &known,
                createdSpaceType: .unknown))
            #expect(acceptedSpaceLifecycleEvent(
                .init(kind: .destroyed, spaceID: 2), knownSpaceIDs: &known,
                createdSpaceType: .unknown))
            #expect(known == [1])
        }

        @Test func snapshotDiffIsStableAndFiltersSystemSpaces() {
            let current = [
                SpaceInfo(id: 4, type: .fullscreen),
                SpaceInfo(id: 3, type: .system),
                SpaceInfo(id: 2, type: .user),
            ]
            #expect(spaceLifecycleSnapshotDiff(previous: [1, 2], current: current) == [
                .init(kind: .created, spaceID: 4),
                .init(kind: .destroyed, spaceID: 1),
            ])
        }

        @Test func displayFlagsHaveDeterministicPrecedenceAndIgnoreBeforePhase() {
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.beginConfigurationFlag, .addFlag]
            ) == nil)
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.addFlag, .removeFlag, .movedFlag]
            ) == .init(kind: .added, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.removeFlag, .movedFlag]
            ) == .init(kind: .removed, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.movedFlag, .desktopShapeChangedFlag]
            ) == .init(kind: .moved, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.desktopShapeChangedFlag]
            ) == .init(kind: .resized, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.disabledFlag]
            ) == .init(kind: .disabled, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.enabledFlag]
            ) == .init(kind: .enabled, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.setModeFlag]
            ) == .init(kind: .resized, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.setMainFlag]
            ) == .init(kind: .configurationChanged, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.mirrorFlag]
            ) == .init(kind: .configurationChanged, displayID: 7))
            #expect(displayReconfigurationEvent(
                displayID: 7, flags: [.unMirrorFlag]
            ) == .init(kind: .configurationChanged, displayID: 7))
            #expect(displayReconfigurationEvent(displayID: 7, flags: []) == nil)
        }
    }
}

private extension DisplayReconfigurationEvent.Kind {
    static let allCasesForTesting: [Self] = [
        .added, .removed, .moved, .resized, .disabled, .enabled,
        .configurationChanged,
    ]
}
