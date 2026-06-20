import os.log
import os.signpost

/// Lightweight tracing utilities backed by os_signpost.
/// All calls are zero-cost when no Instruments profiling session is attached.
enum CHTrace {
    static let log = OSLog(subsystem: "org.cosmic-hammer.CosmicHammer", category: "Performance")
    static let signposter = OSSignposter(logHandle: log)
}
