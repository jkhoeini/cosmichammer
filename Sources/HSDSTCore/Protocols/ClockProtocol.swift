import Foundation

public protocol TimerHandle: AnyObject {
    var isValid: Bool { get }
    var isScheduled: Bool { get }
    var nextFireInterval: TimeInterval { get }
    func setNextFire(afterInterval interval: TimeInterval)
    func fire()
    func invalidate()
    func schedule()
}

public protocol ClockProtocol: AnyObject {
    func now() -> TimeInterval
    func absoluteTimeNanos() -> UInt64
    func secondsSinceEpoch() -> Double
    func sleep(microseconds: UInt32)
    func createTimer(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) -> any TimerHandle
}
