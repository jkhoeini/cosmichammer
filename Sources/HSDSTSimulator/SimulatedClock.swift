import Foundation
import HSDSTCore

public final class SimulatedClock: ClockProtocol {
    private var currentTime: TimeInterval
    private var timers: [SimulatedTimerHandle] = []
    private var rng: RPRNG

    public init(rng: RPRNG, epoch: TimeInterval = Date().timeIntervalSince1970) {
        self.rng = rng
        self.currentTime = epoch
    }

    public func now() -> TimeInterval { currentTime }

    public func absoluteTimeNanos() -> UInt64 {
        UInt64(currentTime * 1_000_000_000)
    }

    public func secondsSinceEpoch() -> Double { currentTime }

    public func sleep(microseconds: UInt32) {
        advance(by: Double(microseconds) / 1_000_000)
    }

    public func createTimer(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) -> any TimerHandle {
        let t = SimulatedTimerHandle(interval: interval, repeats: repeats, handler: handler, clock: self)
        timers.append(t)
        return t
    }

    public func advance(by seconds: TimeInterval) {
        let target = currentTime + seconds
        while currentTime < target {
            let pending = timers.filter { $0.isValid && $0.isScheduled && $0.fireTime <= target }
                .sorted { $0.fireTime < $1.fireTime }
            guard let next = pending.first else {
                currentTime = target
                break
            }
            currentTime = next.fireTime
            next.handler()
            if next.repeats {
                next.fireTime = currentTime + next.interval
            } else {
                next.invalidate()
            }
        }
        timers.removeAll { !$0.isValid }
    }
}

public final class SimulatedTimerHandle: TimerHandle {
    let interval: TimeInterval
    let repeats: Bool
    let handler: () -> Void
    private weak var clock: SimulatedClock?
    fileprivate var fireTime: TimeInterval = 0
    private var _isValid = true
    private var _isScheduled = false

    init(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void, clock: SimulatedClock) {
        self.interval = interval
        self.repeats = repeats
        self.handler = handler
        self.clock = clock
    }

    public var isValid: Bool { _isValid }
    public var isScheduled: Bool { _isScheduled }

    public var nextFireInterval: TimeInterval {
        guard let clock = clock else { return 0 }
        return max(0, fireTime - clock.now())
    }

    public func setNextFire(afterInterval interval: TimeInterval) {
        guard _isValid, let clock = clock else { return }
        fireTime = clock.now() + interval
    }

    public func fire() {
        guard _isValid else { return }
        handler()
    }

    public func invalidate() {
        _isValid = false
        _isScheduled = false
    }

    public func schedule() {
        guard _isValid, let clock = clock else { return }
        _isScheduled = true
        fireTime = clock.now() + interval
    }
}
