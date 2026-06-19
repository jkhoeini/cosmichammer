import Foundation
import HSDSTCore

public final class SimulatedProcess: ProcessProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig
    private let eventLoop: EventLoopProtocol
    private static var nextPID: Int32 = 1000

    public var scriptedResults: [String: ProcessResult] = [:]
    /// Commands listed here stay running until explicitly terminated.
    /// Their completion fires only on terminate/interrupt.
    public var longRunningCommands: Set<String> = ["/bin/sleep"]
    public var defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    public var launchedProcesses: [(path: String, args: [String])] = []

    public init(rng: RPRNG, faults: FaultConfig, eventLoop: EventLoopProtocol) {
        self.rng = rng
        self.faults = faults
        self.eventLoop = eventLoop
    }

    private func allocatePID() -> Int32 {
        let pid = SimulatedProcess.nextPID
        SimulatedProcess.nextPID += 1
        return pid
    }

    private func resultKey(_ path: String, _ args: [String]) -> String {
        if args.isEmpty { return path }
        return path + " " + args.joined(separator: " ")
    }

    public func run(executablePath: String, arguments: [String],
                    environment: [String: String]?,
                    currentDirectory: String?,
                    completion: @escaping (ProcessResult) -> Void) -> any ProcessHandle {
        launchedProcesses.append((path: executablePath, args: arguments))
        let handle = SimulatedProcessHandle(pid: allocatePID())
        handle.environment = environment
        handle.currentDirectoryPath = currentDirectory
        handle.markStarted()

        if rng.boolean(probability: faults.processLaunchFailProbability) {
            let result = ProcessResult(exitCode: 127, stdout: Data(),
                                       stderr: "launch failed (simulated)".data(using: .utf8) ?? Data())
            eventLoop.async {
                handle.markTerminated(status: result.exitCode, reason: .exit)
                completion(result)
            }
            return handle
        }

        let key = resultKey(executablePath, arguments)
        let result = scriptedResults[key] ?? defaultResult

        if rng.boolean(probability: faults.processCrashProbability) {
            let crashResult = ProcessResult(exitCode: -11, stdout: result.stdout,
                                             stderr: "crashed (simulated)".data(using: .utf8) ?? Data())
            eventLoop.async {
                handle.markTerminated(status: crashResult.exitCode, reason: .uncaughtSignal)
                completion(crashResult)
            }
        } else if longRunningCommands.contains(executablePath) {
            // Long-running: stay alive until terminate/interrupt. Store completion
            // on the handle so it fires when the process is killed.
            handle.onTerminated = { status, reason in
                completion(ProcessResult(exitCode: status, stdout: result.stdout, stderr: result.stderr))
            }
        } else {
            eventLoop.async {
                handle.markTerminated(status: result.exitCode, reason: .exit)
                completion(result)
            }
        }
        return handle
    }

    public func runSync(executablePath: String, arguments: [String],
                        environment: [String: String]?,
                        currentDirectory: String?) -> ProcessResult {
        launchedProcesses.append((path: executablePath, args: arguments))
        if rng.boolean(probability: faults.processLaunchFailProbability) {
            return ProcessResult(exitCode: 127, stdout: Data(),
                                stderr: "launch failed (simulated)".data(using: .utf8) ?? Data())
        }
        let key = resultKey(executablePath, arguments)
        return scriptedResults[key] ?? defaultResult
    }

    public func streamingRun(executablePath: String, arguments: [String],
                             environment: [String: String]?,
                             currentDirectory: String?,
                             onStdout: @escaping (Data) -> Void,
                             onStderr: @escaping (Data) -> Void,
                             onExit: @escaping (Int32) -> Void) -> any ProcessHandle {
        launchedProcesses.append((path: executablePath, args: arguments))
        let handle = SimulatedProcessHandle(pid: allocatePID())
        handle.environment = environment
        handle.currentDirectoryPath = currentDirectory
        handle.markStarted()

        let key = resultKey(executablePath, arguments)
        let result = scriptedResults[key] ?? defaultResult

        if executablePath == "/bin/cat" {
            // /bin/cat echoes stdin to stdout. Route through event loop so
            // the echo fires on the next drain cycle, not synchronously
            // during setInput.
            handle.onStdinWrite = { [weak self] data in
                self?.eventLoop.async {
                    onStdout(data)
                }
            }
            handle.onCloseStdin = { [weak handle, weak self] in
                guard let handle = handle else { return }
                self?.eventLoop.async {
                    handle.markTerminated(status: 0, reason: .exit)
                    onExit(0)
                }
            }
        } else if longRunningCommands.contains(executablePath) {
            handle.onTerminated = { status, _ in
                onExit(status)
                handle.markTerminated(status: status, reason: .uncaughtSignal)
            }
        } else {
            eventLoop.async {
                if !result.stdout.isEmpty { onStdout(result.stdout) }
                if !result.stderr.isEmpty { onStderr(result.stderr) }
                handle.markTerminated(status: result.exitCode, reason: .exit)
                onExit(result.exitCode)
            }
        }
        return handle
    }
}

public final class SimulatedProcessHandle: ProcessHandle {
    var _hasStarted = false
    var _hasTerminated = false
    var _terminationStatus: Int32 = 0
    var _terminationReason: ProcessTerminationReason = .exit
    var _isSuspended = false
    public let processIdentifier: Int32
    public var stdinData: [Data] = []
    public var environment: [String: String]?
    public var currentDirectoryPath: String?
    /// Called when stdin data is written (for /bin/cat echo simulation).
    public var onStdinWrite: ((Data) -> Void)?
    /// Called when stdin is closed.
    public var onCloseStdin: (() -> Void)?
    /// Called when the process is terminated externally (for long-running processes).
    /// Arguments: (terminationStatus, terminationReason)
    var onTerminated: ((Int32, ProcessTerminationReason) -> Void)?

    init(pid: Int32) {
        self.processIdentifier = pid
    }

    public var isRunning: Bool { _hasStarted && !_hasTerminated }
    public var hasTerminated: Bool { _hasTerminated }
    public var terminationStatus: Int32 { _terminationStatus }
    public var terminationReason: ProcessTerminationReason { _terminationReason }

    func markStarted() {
        _hasStarted = true
    }

    func markTerminated(status: Int32, reason: ProcessTerminationReason) {
        guard !_hasTerminated else { return }
        _hasTerminated = true
        _terminationStatus = status
        _terminationReason = reason
    }

    public func terminate() {
        guard isRunning else { return }
        let callback = onTerminated
        onTerminated = nil
        markTerminated(status: 15, reason: .uncaughtSignal)
        callback?(15, .uncaughtSignal)
    }
    public func interrupt() {
        guard isRunning else { return }
        let callback = onTerminated
        onTerminated = nil
        markTerminated(status: 15, reason: .uncaughtSignal)
        callback?(15, .uncaughtSignal)
    }
    public func suspend() -> Bool {
        guard isRunning else { return false }
        _isSuspended = true
        return true
    }
    public func resume() -> Bool {
        guard _isSuspended else { return false }
        _isSuspended = false
        return true
    }
    public func writeToStdin(_ data: Data) {
        stdinData.append(data)
        onStdinWrite?(data)
    }
    public func closeStdin() {
        onCloseStdin?()
    }
    public func waitUntilExit() {
        // In simulation, waitUntilExit on a still-running process completes it
        // with normal exit (code 0). This mirrors the real behavior where
        // waitUntilExit blocks until the process finishes naturally.
        if _hasStarted && !_hasTerminated {
            let callback = onTerminated
            onTerminated = nil
            markTerminated(status: 0, reason: .exit)
            callback?(0, .exit)
        }
    }
}
