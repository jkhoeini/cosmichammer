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

public protocol ProcessHandle: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    func terminate()
    func interrupt()
    func writeToStdin(_ data: Data)
    func closeStdin()
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
