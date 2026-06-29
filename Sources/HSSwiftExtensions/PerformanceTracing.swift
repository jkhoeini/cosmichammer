import os.log
import os.signpost
import HSDSTCore

/// Lightweight tracing utilities backed by os_signpost.
/// All calls are zero-cost when no Instruments profiling session is attached.
enum CHTrace {
    static let log = OSLog(subsystem: "org.cosmic-hammer.CosmicHammer", category: "Performance")
    static let signposter = OSSignposter(logHandle: log)

    struct Interval {
        let signpostName: StaticString
        let telemetryName: String
        let signpostState: OSSignpostIntervalState
        let telemetrySpanID: UInt64?
    }

    static func beginInterval(_ name: StaticString, attributes: [String: Any] = [:]) -> Interval {
        let signpostState = signposter.beginInterval(name)
        let telemetryName = String(describing: name)
        let spanID = environmentGetGlobalOrNil()?.telemetry.startSpan(
            name: telemetryName,
            kind: .internalSpan,
            attributes: attributes,
            startTime: nil
        )
        return Interval(signpostName: name, telemetryName: telemetryName, signpostState: signpostState, telemetrySpanID: spanID)
    }

    static func endInterval(_ interval: Interval, status: TelemetrySpanStatus = .unset, attributes: [String: Any] = [:]) {
        signposter.endInterval(interval.signpostName, interval.signpostState)
        if let spanID = interval.telemetrySpanID {
            environmentGetGlobalOrNil()?.telemetry.endSpan(
                id: spanID,
                status: status,
                attributes: attributes,
                endTime: nil
            )
        }
    }
}
