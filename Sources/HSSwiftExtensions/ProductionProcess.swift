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

        do { try proc.run() } catch {
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
        do { try proc.run() } catch { onExit(-1) }
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
    var processIdentifier: Int32 { process.processIdentifier }
    func terminate() { process.terminate() }
    func interrupt() { process.interrupt() }
    func writeToStdin(_ data: Data) { stdinPipe.fileHandleForWriting.write(data) }
    func closeStdin() { stdinPipe.fileHandleForWriting.closeFile() }
}
