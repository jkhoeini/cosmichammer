import Foundation

public struct FaultConfig: Sendable {
    // Clock / timer faults
    public var timerSkipProbability: Double = 0
    public var timerJitterRange: ClosedRange<Double> = 0...0
    public var sleepFails: Bool = false

    // File system faults
    public var fileReadFailProbability: Double = 0
    public var fileWriteFailProbability: Double = 0
    public var diskFullProbability: Double = 0

    // Network faults
    public var connectionFailProbability: Double = 0
    public var packetDropProbability: Double = 0
    public var httpTimeoutProbability: Double = 0

    // Workspace faults
    public var appLaunchFailProbability: Double = 0

    // Pasteboard faults
    public var pasteboardUnavailable: Bool = false

    // Settings faults
    public var settingsReadFailProbability: Double = 0

    // Screen faults
    public var brightnessSetFailProbability: Double = 0

    // System info faults
    public var batteryUnavailable: Bool = false
    public var wifiUnavailable: Bool = false

    // Location faults
    public var locationPermissionDenied: Bool = false
    public var locationUnavailable: Bool = false

    // Notification faults
    public var notificationDropProbability: Double = 0

    // Process faults
    public var processLaunchFailProbability: Double = 0
    public var processCrashProbability: Double = 0

    // Permission faults
    public var accessibilityPermissionDenied: Bool = false
    public var screenRecordingPermissionDenied: Bool = false

    // Window faults
    public var windowOperationFailProbability: Double = 0

    // Audio faults
    public var audioDeviceUnavailable: Bool = false
    public var audioSetVolumeFailProbability: Double = 0

    // Socket faults
    public var socketSendFailProbability: Double = 0

    // Speech faults
    public var speechUnavailable: Bool = false

    // WebView faults
    public var webViewLoadFailProbability: Double = 0

    // Automation faults
    public var scriptExecutionFailProbability: Double = 0

    // File watching faults
    public var fileWatcherCreateFailProbability: Double = 0

    // Device faults
    public var serialPortOpenFailProbability: Double = 0

    // Camera faults
    public var cameraUnavailable: Bool = false

    // Search faults
    public var searchQueryFailProbability: Double = 0

    // Login item faults
    public var loginItemSetFailProbability: Double = 0

    // Dialog faults
    public var dialogCancelled: Bool = false

    // StatusBar faults
    public var statusBarCreateFailProbability: Double = 0

    // Bonjour faults
    public var bonjourPublishFailProbability: Double = 0
    public var bonjourResolveFailProbability: Double = 0

    // Drawing faults
    public var imageLoadFailProbability: Double = 0

    // Certificate faults
    public var keyGenerationFailProbability: Double = 0
    public var keychainOperationFailProbability: Double = 0

    // Media faults
    public var mediaReadFailProbability: Double = 0

    public init() {}

    // MARK: - Tier 2: Targeted fault factories

    public static func withFileReadFailure() -> FaultConfig {
        var c = FaultConfig()
        c.fileReadFailProbability = 1.0
        return c
    }

    public static func withNetworkTimeout() -> FaultConfig {
        var c = FaultConfig()
        c.httpTimeoutProbability = 1.0
        return c
    }

    public static func withConnectionFailure() -> FaultConfig {
        var c = FaultConfig()
        c.connectionFailProbability = 1.0
        return c
    }

    public static func withDiskFull() -> FaultConfig {
        var c = FaultConfig()
        c.diskFullProbability = 1.0
        return c
    }

    public static func withPermissionDenied(accessibility: Bool = false,
                                            location: Bool = false,
                                            screenRecording: Bool = false) -> FaultConfig {
        var c = FaultConfig()
        c.accessibilityPermissionDenied = accessibility
        c.locationPermissionDenied = location
        c.screenRecordingPermissionDenied = screenRecording
        return c
    }

    // MARK: - Tier 3: Swarm fault profile

    public static func swarm(rng: inout RPRNG) -> FaultConfig {
        var c = FaultConfig()
        c.timerSkipProbability = rng.uniformDouble() * 0.1
        c.fileReadFailProbability = rng.uniformDouble() * 0.05
        c.fileWriteFailProbability = rng.uniformDouble() * 0.05
        c.diskFullProbability = rng.uniformDouble() * 0.02
        c.connectionFailProbability = rng.uniformDouble() * 0.1
        c.packetDropProbability = rng.uniformDouble() * 0.1
        c.httpTimeoutProbability = rng.uniformDouble() * 0.1
        c.appLaunchFailProbability = rng.uniformDouble() * 0.05
        c.pasteboardUnavailable = rng.boolean(probability: 0.05)
        c.settingsReadFailProbability = rng.uniformDouble() * 0.02
        c.brightnessSetFailProbability = rng.uniformDouble() * 0.05
        c.batteryUnavailable = rng.boolean(probability: 0.1)
        c.wifiUnavailable = rng.boolean(probability: 0.1)
        c.locationPermissionDenied = rng.boolean(probability: 0.1)
        c.locationUnavailable = rng.boolean(probability: 0.05)
        c.notificationDropProbability = rng.uniformDouble() * 0.05
        c.processLaunchFailProbability = rng.uniformDouble() * 0.05
        c.processCrashProbability = rng.uniformDouble() * 0.02
        c.accessibilityPermissionDenied = rng.boolean(probability: 0.1)
        c.screenRecordingPermissionDenied = rng.boolean(probability: 0.1)
        c.windowOperationFailProbability = rng.uniformDouble() * 0.05
        c.audioDeviceUnavailable = rng.boolean(probability: 0.1)
        c.audioSetVolumeFailProbability = rng.uniformDouble() * 0.05
        c.socketSendFailProbability = rng.uniformDouble() * 0.05
        c.speechUnavailable = rng.boolean(probability: 0.1)
        c.webViewLoadFailProbability = rng.uniformDouble() * 0.05
        c.scriptExecutionFailProbability = rng.uniformDouble() * 0.05
        c.fileWatcherCreateFailProbability = rng.uniformDouble() * 0.02
        c.serialPortOpenFailProbability = rng.uniformDouble() * 0.05
        c.cameraUnavailable = rng.boolean(probability: 0.1)
        c.searchQueryFailProbability = rng.uniformDouble() * 0.02
        c.loginItemSetFailProbability = rng.uniformDouble() * 0.02
        c.dialogCancelled = rng.boolean(probability: 0.1)
        c.statusBarCreateFailProbability = rng.uniformDouble() * 0.02
        c.bonjourPublishFailProbability = rng.uniformDouble() * 0.05
        c.bonjourResolveFailProbability = rng.uniformDouble() * 0.05
        c.imageLoadFailProbability = rng.uniformDouble() * 0.05
        c.keyGenerationFailProbability = rng.uniformDouble() * 0.02
        c.keychainOperationFailProbability = rng.uniformDouble() * 0.02
        c.mediaReadFailProbability = rng.uniformDouble() * 0.05
        return c
    }
}
