import Foundation
import HSDSTCore

public final class SimulatedProcess: ProcessProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig
    private let eventLoop: EventLoopProtocol
    private static var nextPID: Int32 = 1000

    public var scriptedResults: [String: ProcessResult] = [:]
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

    public func run(executablePath: String, arguments: [String],
                    environment: [String: String]?,
                    currentDirectory: String?,
                    completion: @escaping (ProcessResult) -> Void) -> any ProcessHandle {
        launchedProcesses.append((path: executablePath, args: arguments))
        let handle = SimulatedProcessHandle(pid: allocatePID())

        if rng.boolean(probability: faults.processLaunchFailProbability) {
            let result = ProcessResult(exitCode: 127, stdout: Data(),
                                       stderr: "launch failed (simulated)".data(using: .utf8) ?? Data())
            eventLoop.async {
                completion(result)
                handle._isRunning = false
            }
            return handle
        }

        let key = executablePath + " " + arguments.joined(separator: " ")
        let result = scriptedResults[key] ?? defaultResult

        if rng.boolean(probability: faults.processCrashProbability) {
            let crashResult = ProcessResult(exitCode: -11, stdout: result.stdout,
                                             stderr: "crashed (simulated)".data(using: .utf8) ?? Data())
            eventLoop.async {
                completion(crashResult)
                handle._isRunning = false
            }
        } else {
            eventLoop.async {
                completion(result)
                handle._isRunning = false
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
        let key = executablePath + " " + arguments.joined(separator: " ")
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

        let key = executablePath + " " + arguments.joined(separator: " ")
        let result = scriptedResults[key] ?? defaultResult

        eventLoop.async {
            if !result.stdout.isEmpty { onStdout(result.stdout) }
            if !result.stderr.isEmpty { onStderr(result.stderr) }
            onExit(result.exitCode)
            handle._isRunning = false
        }
        return handle
    }
}

final class SimulatedProcessHandle: ProcessHandle {
    var _isRunning = true
    let processIdentifier: Int32
    var stdinData: [Data] = []

    init(pid: Int32) {
        self.processIdentifier = pid
    }

    var isRunning: Bool { _isRunning }
    func terminate() { _isRunning = false }
    func interrupt() { _isRunning = false }
    func writeToStdin(_ data: Data) { stdinData.append(data) }
    func closeStdin() {}
}
