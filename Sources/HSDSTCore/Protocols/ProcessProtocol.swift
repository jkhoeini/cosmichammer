import Foundation

public struct ProcessResult {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32 = 0, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessTerminationReason: Sendable {
    case exit
    case uncaughtSignal
}

public protocol ProcessHandle: AnyObject {
    var isRunning: Bool { get }
    var hasTerminated: Bool { get }
    var processIdentifier: Int32 { get }
    var terminationStatus: Int32 { get }
    var terminationReason: ProcessTerminationReason { get }
    var environment: [String: String]? { get set }
    var currentDirectoryPath: String? { get set }
    func terminate()
    func interrupt()
    func suspend() -> Bool
    func resume() -> Bool
    func writeToStdin(_ data: Data)
    func closeStdin()
    func waitUntilExit()
}

public protocol ProcessProtocol: AnyObject {
    func run(executablePath: String, arguments: [String],
             environment: [String: String]?,
             currentDirectory: String?,
             completion: @escaping (ProcessResult) -> Void) -> any ProcessHandle

    func runSync(executablePath: String, arguments: [String],
                 environment: [String: String]?,
                 currentDirectory: String?) -> ProcessResult

    func streamingRun(executablePath: String, arguments: [String],
                      environment: [String: String]?,
                      currentDirectory: String?,
                      onStdout: @escaping (Data) -> Void,
                      onStderr: @escaping (Data) -> Void,
                      onExit: @escaping (Int32) -> Void) -> any ProcessHandle
}
