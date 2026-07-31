// PROTOTYPE — throwaway model for deterministic replay and bounded liveness.
import Foundation

struct SimulationRunInputs: Equatable {
    let seed: Int64
    let epochSeconds: Int64
    let identitySeed: UInt64
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

struct DeterministicIdentitySource {
    let seed: UInt64
    private var ordinals: [String: UInt64] = [:]

    init(seed: UInt64) {
        self.seed = seed
    }

    mutating func next(namespace: String) -> String {
        let ordinal = ordinals[namespace, default: 0]
        ordinals[namespace] = ordinal + 1

        var state = seed ^ 0xcbf29ce484222325
        for byte in namespace.utf8 {
            state ^= UInt64(byte)
            state &*= 0x100000001b3
        }
        state ^= ordinal &* 0x9e3779b97f4a7c15

        var mixer = SplitMix64(state: state)
        let words = [mixer.next(), mixer.next()]
        var bytes = words.flatMap { word in
            (0..<8).map { shift in UInt8(truncatingIfNeeded: word >> (shift * 8)) }
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }
        return hex[0..<4].joined()
            + "-" + hex[4..<6].joined()
            + "-" + hex[6..<8].joined()
            + "-" + hex[8..<10].joined()
            + "-" + hex[10..<16].joined()
    }
}

enum ProgressSignal: String {
    case quiesced
    case stepLimitExceeded
    case stalled
}

struct ProgressLimits {
    let maxSteps: Int
    let maxVirtualSeconds: Int64
}

struct ProgressReceipt {
    let signal: ProgressSignal
    let inputs: SimulationRunInputs
    let faultProfile: String
    let steps: Int
    let startTime: Int64
    let endTime: Int64
    let pendingWork: Int
    let lastProgress: String
    let unmetPredicate: String
}

enum WorkSource: String {
    case timer
    case eventLoop
}

enum WorkAction {
    case record
    case finish
    case reschedule(after: Int64)
    case enqueueEvent(label: String)
}

private struct ScheduledWork {
    let deadline: Int64
    let insertionOrder: Int
    let source: WorkSource
    let label: String
    let action: WorkAction
}

final class PrototypeScheduler {
    private let inputs: SimulationRunInputs
    private var currentTime: Int64
    private var timerQueue: [ScheduledWork] = []
    private var eventLoopQueue: [ScheduledWork] = []
    private var nextInsertionOrder = 0
    private(set) var finished = false
    private(set) var executionTrace: [String] = []

    init(inputs: SimulationRunInputs) {
        self.inputs = inputs
        self.currentTime = inputs.epochSeconds
    }

    func schedule(after delay: Int64, source: WorkSource, label: String, action: WorkAction) {
        precondition(delay >= 0)
        let work = ScheduledWork(
            deadline: currentTime + delay,
            insertionOrder: nextInsertionOrder,
            source: source,
            label: label,
            action: action
        )
        switch source {
        case .timer: timerQueue.append(work)
        case .eventLoop: eventLoopQueue.append(work)
        }
        nextInsertionOrder += 1
    }

    func run(
        faultProfile: String = "clean",
        until predicate: () -> Bool,
        unmetPredicate: String,
        limits: ProgressLimits
    ) -> ProgressReceipt {
        precondition(limits.maxSteps > 0)
        precondition(limits.maxVirtualSeconds >= 0)
        let startTime = currentTime
        let virtualDeadline = startTime + limits.maxVirtualSeconds
        var steps = 0
        var lastProgress = "none"

        while !predicate() {
            guard let nextDeadline = nextDeadline() else {
                return receipt(.stalled, faultProfile, steps, startTime, lastProgress, unmetPredicate)
            }
            if nextDeadline > virtualDeadline {
                currentTime = virtualDeadline
                return receipt(.stalled, faultProfile, steps, startTime, lastProgress, unmetPredicate)
            }
            if steps == limits.maxSteps {
                return receipt(
                    .stepLimitExceeded, faultProfile, steps, startTime,
                    lastProgress, unmetPredicate
                )
            }

            currentTime = max(currentTime, nextDeadline)

            while let index = dueWorkIndex(in: timerQueue) {
                if steps == limits.maxSteps {
                    return receipt(
                        .stepLimitExceeded, faultProfile, steps, startTime,
                        lastProgress, unmetPredicate
                    )
                }
                let work = timerQueue.remove(at: index)
                execute(work, steps: &steps, lastProgress: &lastProgress)
            }

            while let index = dueWorkIndex(in: eventLoopQueue) {
                if steps == limits.maxSteps {
                    return receipt(
                        .stepLimitExceeded, faultProfile, steps, startTime,
                        lastProgress, unmetPredicate
                    )
                }
                let work = eventLoopQueue.remove(at: index)
                execute(work, steps: &steps, lastProgress: &lastProgress)
            }
        }

        return receipt(.quiesced, faultProfile, steps, startTime, lastProgress, unmetPredicate)
    }

    private func execute(
        _ work: ScheduledWork,
        steps: inout Int,
        lastProgress: inout String
    ) {
        steps += 1
        lastProgress = "\(work.source.rawValue).\(work.label)"
        executionTrace.append("\(lastProgress)@\(currentTime)")

        switch work.action {
        case .record:
            break
        case .finish:
            finished = true
        case let .reschedule(delay):
            schedule(after: delay, source: work.source, label: work.label, action: work.action)
        case let .enqueueEvent(label):
            schedule(after: 0, source: .eventLoop, label: label, action: .record)
        }
    }

    private func nextDeadline() -> Int64? {
        (timerQueue.map(\.deadline) + eventLoopQueue.map(\.deadline)).min()
    }

    private func dueWorkIndex(in queue: [ScheduledWork]) -> Int? {
        queue.indices
            .filter { queue[$0].deadline <= currentTime }
            .min { lhs, rhs in
                let left = queue[lhs]
                let right = queue[rhs]
                if left.deadline == right.deadline {
                    return left.insertionOrder < right.insertionOrder
                }
                return left.deadline < right.deadline
            }
    }

    private func receipt(
        _ signal: ProgressSignal,
        _ faultProfile: String,
        _ steps: Int,
        _ startTime: Int64,
        _ lastProgress: String,
        _ unmetPredicate: String
    ) -> ProgressReceipt {
        ProgressReceipt(
            signal: signal,
            inputs: inputs,
            faultProfile: faultProfile,
            steps: steps,
            startTime: startTime,
            endTime: currentTime,
            pendingWork: timerQueue.count + eventLoopQueue.count,
            lastProgress: lastProgress,
            unmetPredicate: unmetPredicate
        )
    }
}

struct ReplayObservation: Equatable {
    let inputs: SimulationRunInputs
    let faultSample: UInt64
    let notificationIdentifier: String
    let certificateCreatedAt: Int64
    let notificationDeliveredAt: Int64
    let telemetryDuration: Int64
    let executionTrace: [String]
}

private let canonicalInputs = SimulationRunInputs(
    seed: 42,
    epochSeconds: 978_307_200,
    identitySeed: 42
)

private func replayObservation(faultDraws: Int) -> ReplayObservation {
    var faultRNG = SplitMix64(state: UInt64(bitPattern: canonicalInputs.seed))
    for _ in 0..<faultDraws { _ = faultRNG.next() }
    let faultSample = faultRNG.next()

    var identities = DeterministicIdentitySource(seed: canonicalInputs.identitySeed)
    let notificationIdentifier = identities.next(namespace: "notification")

    let scheduler = PrototypeScheduler(inputs: canonicalInputs)
    scheduler.schedule(
        after: 1,
        source: .eventLoop,
        label: "notification-delivery",
        action: .record
    )
    scheduler.schedule(after: 2, source: .timer, label: "telemetry-flush", action: .finish)
    let progress = scheduler.run(
        until: { scheduler.finished },
        unmetPredicate: "telemetry flush completes",
        limits: ProgressLimits(maxSteps: 10_000, maxVirtualSeconds: 60)
    )
    precondition(progress.signal == .quiesced)

    return ReplayObservation(
        inputs: canonicalInputs,
        faultSample: faultSample,
        notificationIdentifier: notificationIdentifier,
        certificateCreatedAt: canonicalInputs.epochSeconds,
        notificationDeliveredAt: canonicalInputs.epochSeconds + 1,
        telemetryDuration: progress.endTime - (canonicalInputs.epochSeconds + 1),
        executionTrace: scheduler.executionTrace
    )
}

private func stepLimitedReceipt() -> ProgressReceipt {
    let scheduler = PrototypeScheduler(inputs: canonicalInputs)
    scheduler.schedule(after: 0, source: .timer, label: "spin", action: .reschedule(after: 0))
    return scheduler.run(
        until: { false },
        unmetPredicate: "repeating timer is cancelled",
        limits: ProgressLimits(maxSteps: 5, maxVirtualSeconds: 60)
    )
}

private func stalledReceipt() -> ProgressReceipt {
    let scheduler = PrototypeScheduler(inputs: canonicalInputs)
    scheduler.schedule(after: 61, source: .eventLoop, label: "late-completion", action: .finish)
    return scheduler.run(
        until: { scheduler.finished },
        unmetPredicate: "late callback completes",
        limits: ProgressLimits(maxSteps: 10_000, maxVirtualSeconds: 60)
    )
}

private func emptyAtStepLimitReceipt() -> ProgressReceipt {
    let scheduler = PrototypeScheduler(inputs: canonicalInputs)
    scheduler.schedule(after: 0, source: .eventLoop, label: "last-work", action: .record)
    return scheduler.run(
        until: { false },
        unmetPredicate: "completion signal arrives",
        limits: ProgressLimits(maxSteps: 1, maxVirtualSeconds: 60)
    )
}

private func twoPhaseExecutionTrace() -> [String] {
    let scheduler = PrototypeScheduler(inputs: canonicalInputs)
    scheduler.schedule(
        after: 1,
        source: .timer,
        label: "enqueue-event",
        action: .enqueueEvent(label: "from-timer")
    )
    scheduler.schedule(after: 1, source: .timer, label: "finish", action: .finish)
    let receipt = scheduler.run(
        until: { scheduler.finished },
        unmetPredicate: "two-phase scenario completes",
        limits: ProgressLimits(maxSteps: 10_000, maxVirtualSeconds: 60)
    )
    precondition(receipt.signal == .quiesced && receipt.steps == 3)
    return scheduler.executionTrace
}

let replayA = replayObservation(faultDraws: 128)
let replayB = replayObservation(faultDraws: 128)
let replayWithoutFaultDraws = replayObservation(faultDraws: 0)
precondition(replayA == replayB)
precondition(replayWithoutFaultDraws.notificationIdentifier == replayA.notificationIdentifier)
precondition(replayWithoutFaultDraws.faultSample != replayA.faultSample)
precondition(replayA.notificationIdentifier.count == 36)
precondition(replayA.executionTrace == [
    "eventLoop.notification-delivery@978307201",
    "timer.telemetry-flush@978307202",
])
precondition(twoPhaseExecutionTrace() == [
    "timer.enqueue-event@978307201",
    "timer.finish@978307201",
    "eventLoop.from-timer@978307201",
])

let quiescedScheduler = PrototypeScheduler(inputs: canonicalInputs)
quiescedScheduler.schedule(after: 1, source: .eventLoop, label: "prepare", action: .record)
quiescedScheduler.schedule(after: 2, source: .timer, label: "complete", action: .finish)
let quiesced = quiescedScheduler.run(
    until: { quiescedScheduler.finished },
    unmetPredicate: "scenario completes",
    limits: ProgressLimits(maxSteps: 10_000, maxVirtualSeconds: 60)
)
let stepLimited = stepLimitedReceipt()
let stalled = stalledReceipt()
let emptyStall = emptyAtStepLimitReceipt()

precondition(quiesced.signal == .quiesced && quiesced.steps == 2 && quiesced.pendingWork == 0)
precondition(stepLimited.signal == .stepLimitExceeded && stepLimited.steps == 5)
precondition(stepLimited.pendingWork == 1 && stepLimited.lastProgress == "timer.spin")
precondition(stalled.signal == .stalled && stalled.steps == 0 && stalled.pendingWork == 1)
precondition(stalled.endTime - stalled.startTime == 60)
precondition(stepLimited.inputs == canonicalInputs && stepLimited.faultProfile == "clean")
precondition(stepLimited.unmetPredicate == "repeating timer is cancelled")
precondition(emptyStall.signal == .stalled && emptyStall.steps == 1)
precondition(emptyStall.pendingWork == 0 && emptyStall.lastProgress == "eventLoop.last-work")

let injectedFields = [
    "clock.epoch",
    "userNotification.identifier-observed",
    "certificate.createdAt",
    "notification.actualDeliveryDate",
    "telemetry.duration",
]
let excludedFields = [
    "userNotification.autoUUID-unobserved",
    "location.referenceDate-already-fixed",
    "realIO.tempUUID",
    "realIO.wallClock",
]

print("inputs=seed:\(canonicalInputs.seed) epoch:\(canonicalInputs.epochSeconds) identity-seed:\(canonicalInputs.identitySeed)")
print("replay=byte-identical identity=fault-independent time=clock-derived")
print("quiesced=steps:\(quiesced.steps) virtual:\(quiesced.endTime - quiesced.startTime) pending:\(quiesced.pendingWork) signal:\(quiesced.signal.rawValue)")
print("step-limit=steps:\(stepLimited.steps) virtual:\(stepLimited.endTime - stepLimited.startTime) pending:\(stepLimited.pendingWork) signal:\(stepLimited.signal.rawValue)")
print("stalled=steps:\(stalled.steps) virtual:\(stalled.endTime - stalled.startTime) pending:\(stalled.pendingWork) signal:\(stalled.signal.rawValue)")
print("empty-stall=steps:\(emptyStall.steps) virtual:\(emptyStall.endTime - emptyStall.startTime) pending:\(emptyStall.pendingWork) signal:\(emptyStall.signal.rawValue)")
print("fields=inject:\(injectedFields.joined(separator: ",")) exclude:\(excludedFields.joined(separator: ","))")
