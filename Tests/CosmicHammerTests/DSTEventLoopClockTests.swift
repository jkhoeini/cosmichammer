import Testing
import Foundation
import HSDSTCore
import HSDSTSimulator

extension CosmicHammerTests {

    @Suite("DST EventLoop and Clock") final class DSTEventLoopClockTests {

        // MARK: - Clock basics

        @Test func clockStartsAtEpoch() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let now = env.clock.now()
            let epoch = env.clock.secondsSinceEpoch()
            #expect(now == epoch)
        }

        @Test func clockAdvanceIsExact() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let before = env.clock.now()
            harness.clock.advance(by: 1.5)
            let after = env.clock.now()
            #expect(after - before == 1.5)
        }

        @Test func clockAbsoluteTimeNanosConsistentWithNow() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            harness.clock.advance(by: 2.0)
            let now = env.clock.now()
            let nanos = env.clock.absoluteTimeNanos()
            #expect(nanos == UInt64(now * 1_000_000_000))
        }

        @Test func clockSleepAdvancesTime() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let before = env.clock.now()
            env.clock.sleep(microseconds: 500_000)
            let after = env.clock.now()
            #expect(after - before == 0.5)
        }

        @Test func clockMultipleAdvancesAccumulate() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let start = env.clock.now()
            harness.clock.advance(by: 1.0)
            harness.clock.advance(by: 2.0)
            let end = env.clock.now()
            #expect(end - start == 3.0)
        }

        // MARK: - Timer basics

        @Test func timerIsValidAfterCreation() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let timer = env.clock.createTimer(interval: 1.0, repeats: false) {}
            #expect(timer.isValid == true)
            #expect(timer.isScheduled == false)
        }

        @Test func timerFireDirectlyCallsHandler() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false
            let timer = env.clock.createTimer(interval: 1.0, repeats: false) {
                fired = true
            }
            timer.fire()
            #expect(fired)
        }

        @Test func timerInvalidatedCannotFire() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false
            let timer = env.clock.createTimer(interval: 1.0, repeats: false) {
                fired = true
            }
            timer.invalidate()
            timer.fire()
            #expect(!fired)
        }

        @Test func timerSetNextFireReschedules() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false
            let timer = env.clock.createTimer(interval: 5.0, repeats: false) {
                fired = true
            }
            timer.schedule()
            timer.setNextFire(afterInterval: 0.5)
            harness.clock.advance(by: 0.5)
            #expect(fired)
        }

        @Test func timerNextFireIntervalDecreases() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let timer = env.clock.createTimer(interval: 2.0, repeats: false) {}
            timer.schedule()
            let initialInterval = timer.nextFireInterval
            #expect(initialInterval >= 1.99 && initialInterval <= 2.01)
            harness.clock.advance(by: 1.0)
            let remaining = timer.nextFireInterval
            #expect(remaining >= 0.99 && remaining <= 1.01)
        }

        @Test func timerInvalidatedDuringAdvanceStops() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var count = 0
            var timerRef: (any TimerHandle)?
            let timer = env.clock.createTimer(interval: 1.0, repeats: true) {
                count += 1
                if count == 2 {
                    timerRef?.invalidate()
                }
            }
            timerRef = timer
            timer.schedule()
            harness.clock.advance(by: 5.0)
            #expect(count == 2)
        }

        @Test func manyTimersConcurrent() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var firedCount = 0
            var rng = RPRNG(seed: 99)

            for _ in 0..<100 {
                let interval = Double(rng.uniform(below: 1000)) / 100.0
                let timer = env.clock.createTimer(interval: interval, repeats: false) {
                    firedCount += 1
                }
                timer.schedule()
            }

            harness.clock.advance(by: 11.0)
            #expect(firedCount == 100)
        }

        @Test func timerScheduleSetsFireTime() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false
            let timer = env.clock.createTimer(interval: 0.1, repeats: false) {
                fired = true
            }
            #expect(!timer.isScheduled)
            timer.schedule()
            #expect(timer.isScheduled)
            harness.clock.advance(by: 0.1)
            #expect(fired)
        }

        @Test func timerInvalidatePreventsScheduledFire() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false
            let timer = env.clock.createTimer(interval: 1.0, repeats: false) {
                fired = true
            }
            timer.schedule()
            #expect(timer.isValid)
            timer.invalidate()
            #expect(!timer.isValid)
            #expect(!timer.isScheduled)
            harness.clock.advance(by: 2.0)
            #expect(!fired)
        }

        // MARK: - EventLoop

        @Test func asyncWorkDrainsImmediately() {
            let harness = SimulatorHarness(seed: 42)
            let loop = harness.eventLoop
            var ran = false
            loop.async { ran = true }
            #expect(!ran)
            loop.drain()
            #expect(ran)
        }

        @Test func afterWorkDrainsAtCorrectTime() {
            let harness = SimulatorHarness(seed: 42)
            let loop = harness.eventLoop
            var ran = false
            loop.after(seconds: 2.0) { ran = true }

            harness.clock.advance(by: 1.0)
            loop.drain()
            #expect(!ran)

            harness.clock.advance(by: 1.0)
            loop.drain()
            #expect(ran)
        }

        @Test func drainProcessesInOrder() {
            let harness = SimulatorHarness(seed: 42)
            let loop = harness.eventLoop
            var order: [Int] = []
            loop.async { order.append(1) }
            loop.async { order.append(2) }
            loop.async { order.append(3) }
            loop.drain()
            #expect(order == [1, 2, 3])
        }

        @Test func drainLimitPreventsInfiniteLoop() {
            let harness = SimulatorHarness(seed: 42)
            let loop = harness.eventLoop
            var iterations = 0

            func enqueueRecursive() {
                iterations += 1
                loop.async { enqueueRecursive() }
            }
            loop.async { enqueueRecursive() }
            loop.drain()

            #expect(iterations > 0)
            #expect(iterations <= 10_000)
        }

        @Test func pendingCountTracksQueue() {
            let harness = SimulatorHarness(seed: 42)
            let loop = harness.eventLoop
            #expect(loop.pendingCount == 0)

            loop.async {}
            loop.async {}
            #expect(loop.pendingCount == 2)

            loop.after(seconds: 5.0) {}
            #expect(loop.pendingCount == 3)

            loop.drain()
            // The two async items drain (deadline <= now), the after(5s) does not
            #expect(loop.pendingCount == 1)
        }

        @Test func afterWorkWithZeroDelay() {
            let harness = SimulatorHarness(seed: 42)
            let loop = harness.eventLoop
            var ran = false
            loop.after(seconds: 0) { ran = true }
            loop.drain()
            #expect(ran)
        }

        // MARK: - Clock + EventLoop integration

        @Test func eventLoopAndClockIntegrate() {
            let harness = SimulatorHarness(seed: 42)
            var ran = false
            harness.eventLoop.after(seconds: 1.0) { ran = true }

            harness.advanceTime(by: 0.5)
            #expect(!ran)

            harness.advanceTime(by: 0.5)
            #expect(ran)
        }

        @Test func advanceTimeDrainsBoth() {
            let harness = SimulatorHarness(seed: 42)
            var timerFired = false
            var loopRan = false

            let timer = harness.clock.createTimer(interval: 0.5, repeats: false) {
                timerFired = true
            }
            timer.schedule()
            harness.eventLoop.after(seconds: 0.5) { loopRan = true }

            harness.advanceTime(by: 1.0)
            #expect(timerFired)
            #expect(loopRan)
        }

        @Test func timerAndEventLoopOrdering() {
            let harness = SimulatorHarness(seed: 42)
            var events: [String] = []

            let t1 = harness.clock.createTimer(interval: 0.3, repeats: false) {
                events.append("timer")
            }
            t1.schedule()
            harness.eventLoop.after(seconds: 0.5) { events.append("loop") }

            harness.advanceTime(by: 1.0)
            #expect(events.contains("timer"))
            #expect(events.contains("loop"))
        }

        @Test func drainEventLoopAlone() {
            let harness = SimulatorHarness(seed: 42)
            var ran = false
            harness.eventLoop.async { ran = true }
            harness.drainEventLoop()
            #expect(ran)
        }

        // MARK: - Determinism

        @Test func sameSeedProducesSameClockBehavior() {
            func runScenario(seed: Int64) -> [TimeInterval] {
                let harness = SimulatorHarness(seed: seed)
                let start = harness.clock.now()
                var offsets: [TimeInterval] = []
                let timer = harness.clock.createTimer(interval: 0.7, repeats: true) {
                    offsets.append(harness.clock.now() - start)
                }
                timer.schedule()
                harness.advanceTime(by: 3.0)
                return offsets
            }
            let run1 = runScenario(seed: 42)
            let run2 = runScenario(seed: 42)
            #expect(run1 == run2)
            #expect(run1.count == 4)
        }
    }
}
