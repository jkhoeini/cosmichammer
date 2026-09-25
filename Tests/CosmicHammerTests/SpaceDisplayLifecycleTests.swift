import Testing
import HSDSTCore
import HSDSTSimulator

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
    }
}

private extension DisplayReconfigurationEvent.Kind {
    static let allCasesForTesting: [Self] = [
        .added, .removed, .moved, .resized, .disabled, .enabled,
    ]
}
