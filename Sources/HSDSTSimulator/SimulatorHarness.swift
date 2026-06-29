import Foundation
import HSDSTCore

public final class SimulatorHarness {
    public let seed: Int64
    public private(set) var rng: RPRNG
    public private(set) var clock: SimulatedClock
    public private(set) var eventLoop: SimulatedEventLoop

    public init(seed: Int64 = 42) {
        self.seed = seed
        self.rng = RPRNG(seed: seed)
        self.clock = SimulatedClock(rng: rng.fork())
        self.eventLoop = SimulatedEventLoop(clock: clock)
    }

    public func createEnvironment(faults: FaultConfig = FaultConfig()) -> Environment {
        // Original 12 simulators
        let clockSim = clock
        let eventLoopSim = eventLoop
        let fsSim = SimulatedFileSystem(rng: rng.fork(), faults: faults, clock: clockSim)
        let netSim = SimulatedNetwork(rng: rng.fork(), faults: faults, clock: clockSim)
        let wsSim = SimulatedWorkspace(rng: rng.fork(), faults: faults)
        let pbSim = SimulatedPasteboard(rng: rng.fork(), faults: faults)
        let setSim = SimulatedSettings(rng: rng.fork(), faults: faults)
        let scrSim = SimulatedScreen(rng: rng.fork(), faults: faults)
        let sysSim = SimulatedSystemInfo(rng: rng.fork(), faults: faults)
        let locSim = SimulatedLocation(rng: rng.fork(), faults: faults)
        let notSim = SimulatedNotification(rng: rng.fork(), faults: faults)
        let procSim = SimulatedProcess(rng: rng.fork(), faults: faults, eventLoop: eventLoopSim)

        // New 15 simulators
        let winSim = SimulatedWindow(rng: rng.fork(), faults: faults)
        let axSim = SimulatedAccessibility(rng: rng.fork(), faults: faults)
        let inputSim = SimulatedInput(rng: rng.fork(), faults: faults)
        let audioSim = SimulatedAudio(rng: rng.fork(), faults: faults)
        let socketSim = SimulatedSocket(rng: rng.fork(), faults: faults)
        let speechSim = SimulatedSpeech(rng: rng.fork(), faults: faults)
        let spacesSim = SimulatedSpaces(rng: rng.fork(), faults: faults)
        let webViewSim = SimulatedWebView(rng: rng.fork(), faults: faults)
        let automationSim = SimulatedAutomation(rng: rng.fork(), faults: faults)
        let fileWatchSim = SimulatedFileWatching(rng: rng.fork(), faults: faults)
        let deviceSim = SimulatedDevice(rng: rng.fork(), faults: faults)
        let cameraSim = SimulatedCamera(rng: rng.fork(), faults: faults)
        let searchSim = SimulatedSearch(rng: rng.fork(), faults: faults)
        let loginItemSim = SimulatedLoginItem(rng: rng.fork(), faults: faults)
        let dialogSim = SimulatedDialog(rng: rng.fork(), faults: faults)

        // Round 3 simulators
        let statusBarSim = SimulatedStatusBar(rng: rng.fork(), faults: faults)
        let bonjourSim = SimulatedBonjour(rng: rng.fork(), faults: faults)
        let drawingSim = SimulatedDrawing(rng: rng.fork(), faults: faults)
        let certificateSim = SimulatedCertificate(rng: rng.fork(), faults: faults)
        let mediaSim = SimulatedMedia(rng: rng.fork(), faults: faults)

        // Round 4 simulators
        let appSim = SimulatedApplication(rng: rng.fork(), faults: faults)
        appSim.windowSim = winSim
        let telemetrySim = SimulatedTelemetry(rng: rng.fork(), faults: faults)

        return Environment(
            clock: clockSim,
            eventLoop: eventLoopSim,
            fileSystem: fsSim,
            network: netSim,
            workspace: wsSim,
            pasteboard: pbSim,
            settings: setSim,
            screen: scrSim,
            systemInfo: sysSim,
            location: locSim,
            notification: notSim,
            process: procSim,
            window: winSim,
            accessibility: axSim,
            input: inputSim,
            audio: audioSim,
            socket: socketSim,
            speech: speechSim,
            spaces: spacesSim,
            webView: webViewSim,
            automation: automationSim,
            fileWatching: fileWatchSim,
            device: deviceSim,
            camera: cameraSim,
            search: searchSim,
            loginItem: loginItemSim,
            dialog: dialogSim,
            statusBar: statusBarSim,
            bonjour: bonjourSim,
            drawing: drawingSim,
            certificate: certificateSim,
            media: mediaSim,
            application: appSim,
            telemetry: telemetrySim
        )
    }

    public func advanceTime(by seconds: TimeInterval) {
        clock.advance(by: seconds)
        eventLoop.drain()
    }

    public func drainEventLoop() {
        eventLoop.drain()
    }
}
