import Foundation
import HSDSTCore
import Darwin.POSIX.sys.time

final class ProductionClock: ClockProtocol {
    func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }

    func absoluteTimeNanos() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let absTime = mach_absolute_time()
        return (absTime * UInt64(timebase.numer)) / UInt64(timebase.denom)
    }

    func secondsSinceEpoch() -> Double {
        var v = timeval()
        gettimeofday(&v, nil)
        return Double(v.tv_sec) + Double(v.tv_usec) / 1.0e6
    }

    func sleep(microseconds: UInt32) {
        usleep(microseconds)
    }

    func createTimer(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) -> any TimerHandle {
        ProductionTimerHandle(interval: interval, repeats: repeats, handler: handler)
    }
}

final class ProductionTimerHandle: TimerHandle {
    private var timer: Timer?
    private let interval: TimeInterval
    private let repeats: Bool
    private let handler: () -> Void

    init(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) {
        self.interval = interval
        self.repeats = repeats
        self.handler = handler
        self.timer = Timer(timeInterval: interval, repeats: repeats) { [handler] _ in handler() }
    }

    var isValid: Bool { timer?.isValid ?? false }
    var isScheduled: Bool {
        guard let t = timer else { return false }
        return CFRunLoopContainsTimer(CFRunLoopGetMain(), t as CFRunLoopTimer, CFRunLoopMode.defaultMode)
    }

    var nextFireInterval: TimeInterval {
        guard let t = timer else { return 0 }
        return CFRunLoopTimerGetNextFireDate(t as CFRunLoopTimer) - CFAbsoluteTimeGetCurrent()
    }

    func setNextFire(afterInterval interval: TimeInterval) {
        timer?.fireDate = Date(timeIntervalSinceNow: interval)
    }

    func fire() { timer?.fire() }

    func invalidate() { timer?.invalidate() }

    func schedule() {
        guard let t = timer else { return }
        RunLoop.main.add(t, forMode: .common)
    }
}
