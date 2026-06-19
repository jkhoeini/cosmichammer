import Foundation
import HSDSTCore

final class ProductionProcess: ProcessProtocol {
    func run(executablePath: String, arguments: [String],
             environment: [String: String]?,
             currentDirectory: String?,
             completion: @escaping (ProcessResult) -> Void) -> any ProcessHandle {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        if let env = environment { proc.environment = env }
        if let dir = currentDirectory { proc.currentDirectoryURL = URL(fileURLWithPath: dir) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let handle = ProductionProcessHandle(process: proc)
        proc.terminationHandler = { p in
            let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            completion(ProcessResult(exitCode: p.terminationStatus, stdout: out, stderr: err))
        }

        do {
            try proc.run()
            handle.markLaunched()
        } catch {
            completion(ProcessResult(exitCode: -1, stdout: Data(),
                                    stderr: error.localizedDescription.data(using: .utf8) ?? Data()))
        }
        return handle
    }

    func runSync(executablePath: String, arguments: [String],
                 environment: [String: String]?,
                 currentDirectory: String?) -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        if let env = environment { proc.environment = env }
        if let dir = currentDirectory { proc.currentDirectoryURL = URL(fileURLWithPath: dir) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() } catch {
            return ProcessResult(exitCode: -1, stdout: Data(),
                                stderr: error.localizedDescription.data(using: .utf8) ?? Data())
        }
        proc.waitUntilExit()
        return ProcessResult(
            exitCode: proc.terminationStatus,
            stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }

    func streamingRun(executablePath: String, arguments: [String],
                      environment: [String: String]?,
                      currentDirectory: String?,
                      onStdout: @escaping (Data) -> Void,
                      onStderr: @escaping (Data) -> Void,
                      onExit: @escaping (Int32) -> Void) -> any ProcessHandle {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        if let env = environment { proc.environment = env }
        if let dir = currentDirectory { proc.currentDirectoryURL = URL(fileURLWithPath: dir) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onStderr(data) }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onExit(p.terminationStatus)
        }

        let handle = ProductionProcessHandle(process: proc)
        do {
            try proc.run()
            handle.markLaunched()
        } catch { onExit(-1) }
        return handle
    }
}

private final class ProductionProcessHandle: ProcessHandle {
    let process: Process
    private let stdinPipe = Pipe()

    init(process: Process) {
        self.process = process
        process.standardInput = stdinPipe
    }

    var isRunning: Bool { process.isRunning }
    var hasTerminated: Bool { !process.isRunning && _launched }
    var processIdentifier: Int32 { process.processIdentifier }
    var terminationStatus: Int32 { process.terminationStatus }
    var terminationReason: ProcessTerminationReason {
        switch process.terminationReason {
        case .exit: return .exit
        case .uncaughtSignal: return .uncaughtSignal
        @unknown default: return .exit
        }
    }
    var environment: [String: String]? {
        get { process.environment }
        set { process.environment = newValue }
    }
    var currentDirectoryPath: String? {
        get { process.currentDirectoryPath }
        set { if let v = newValue { process.currentDirectoryPath = v } }
    }
    func terminate() { process.terminate() }
    func interrupt() { process.interrupt() }
    func suspend() -> Bool { process.suspend() }
    func resume() -> Bool { process.resume() }
    func writeToStdin(_ data: Data) { stdinPipe.fileHandleForWriting.write(data) }
    func closeStdin() { stdinPipe.fileHandleForWriting.closeFile() }
    func waitUntilExit() { process.waitUntilExit() }

    private var _launched = false
    func markLaunched() { _launched = true }
}
