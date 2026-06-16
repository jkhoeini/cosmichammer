import Foundation
import HSDSTCore

public final class SimulatedEventLoop: EventLoopProtocol {
    private struct PendingWork {
        let deadline: TimeInterval
        let block: () -> Void
    }

    private var queue: [PendingWork] = []
    private let clock: SimulatedClock

    public init(clock: SimulatedClock) {
        self.clock = clock
    }

    public func async(_ block: @escaping () -> Void) {
        queue.append(PendingWork(deadline: clock.now(), block: block))
    }

    public func after(seconds: TimeInterval, block: @escaping () -> Void) {
        queue.append(PendingWork(deadline: clock.now() + seconds, block: block))
    }

    public func drain() {
        var iterations = 0
        let limit = 10_000
        while !queue.isEmpty && iterations < limit {
            let now = clock.now()
            guard let idx = queue.indices.first(where: { queue[$0].deadline <= now }) else { break }
            let work = queue.remove(at: idx)
            work.block()
            iterations += 1
        }
    }

    public var pendingCount: Int { queue.count }
}
