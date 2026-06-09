import AppKit
import Foundation
import Darwin.sysexits
import CEditline

private let defaultPortName = "Cosmic Hammer"
private let defaultTimeout: CFTimeInterval = 4.0
private let bundleID = "org.cosmic-hammer.CosmicHammer" as CFString

/// XDG state dir for Cosmic Hammer: `${XDG_STATE_HOME:-~/.local/state}/cosmichammer`.
/// Duplicated (not shared) from the app's `XDGPaths` because the `hs` CLI is a
/// standalone target that does not link HSSwiftExtensions. Keep the two in sync.
private func xdgStateHome() -> String {
    let base: String
    if let value = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], value.hasPrefix("/") {
        base = value
    } else {
        base = (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
    }
    return (base as NSString).appendingPathComponent("cosmichammer")
}

private enum MsgID: Int32 {
    case legacy     =   0
    case register   = 100
    case unregister = 200
    case command    = 500
    case query      = 501
    case legacyChk  = 900

    case error      =  -1
    case output     =   1
    case `return`   =   2
    case console    =   3
}

// MARK: - Color configuration

private struct Colors {
    var banner = ""
    var input  = ""
    var output = ""
    var error  = ""
    var reset  = ""

    static func ansi() -> Colors {
        func pref(_ key: String, fallback: String) -> String {
            if let v = CFPreferencesCopyAppValue(key as CFString, bundleID) as? String { return v }
            return fallback
        }
        return Colors(
            banner: pref("ipc.cli.color_initial", fallback: "\u{1b}[35m"),
            input:  pref("ipc.cli.color_input",   fallback: "\u{1b}[33m"),
            output: pref("ipc.cli.color_output",   fallback: "\u{1b}[36m"),
            error:  pref("ipc.cli.color_error",    fallback: "\u{1b}[31m"),
            reset:  "\u{1b}[0m"
        )
    }
}

// MARK: - Client

private final class HSClient {
    var remotePort: CFMessagePort?
    var localPort: CFMessagePort?
    let remoteName: String
    let localName = UUID().uuidString
    var colors: Colors
    var sendTimeout: CFTimeInterval
    var recvTimeout: CFTimeInterval
    var arguments: [String] = []
    var autoReconnect = false
    var exitCode: Int32 = EX_OK

    private var runLoopSource: CFRunLoopSource?
    private var keepAliveTimer: Timer?

    init(remote: String, timeout: CFTimeInterval, useColors: Bool) {
        self.remoteName = remote
        self.sendTimeout = timeout
        self.recvTimeout = timeout
        self.colors = useColors ? .ansi() : Colors()
    }

    deinit {
        if let lp = localPort { CFMessagePortInvalidate(lp) }
    }

    // MARK: Connection

    func connect() -> Bool {
        remotePort = CFMessagePortCreateRemote(nil, remoteName as CFString)
        guard remotePort != nil else {
            fputs("error: can't access Cosmic Hammer message port \(remoteName); is it running with the ipc module loaded?\n", stderr)
            exitCode = EX_UNAVAILABLE
            return false
        }

        let answer = sendToRemote("1 + 1", msgID: .legacyChk, wantResponse: true)
        let version = answer.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        if version.hasPrefix("version:") {
            var ctx = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            var err: DarwinBoolean = false
            localPort = CFMessagePortCreateLocal(nil, localName as CFString, localCallback, &ctx, &err)
            guard !err.boolValue, let lp = localPort else {
                fputs("error: failed to create local port\n", stderr)
                exitCode = EX_UNAVAILABLE
                return false
            }
            if let src = CFMessagePortCreateRunLoopSource(nil, lp, 0) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
                runLoopSource = src
            }
        }

        guard registerWithRemote() else {
            exitCode = EX_UNAVAILABLE
            return false
        }
        return true
    }

    // MARK: Send / Receive

    @discardableResult
    func sendToRemote(_ data: Any, msgID: MsgID, wantResponse: Bool) -> Data? {
        var payload = Data()
        if msgID == .command || (msgID == .query && localPort != nil) {
            payload.append(Data("\(localName)\0".utf8))
        } else if msgID == .legacy || (msgID == .query && localPort == nil) {
            payload.append(UInt8(ascii: "x"))
        }
        if let d = data as? Data { payload.append(d) }
        else if let s = data as? String { payload.append(Data(s.utf8)) }

        var returnedData: Unmanaged<CFData>?
        let code = CFMessagePortSendRequest(
            remotePort, msgID.rawValue, payload as CFData,
            sendTimeout, wantResponse ? recvTimeout : 0,
            wantResponse ? CFRunLoopMode.defaultMode.rawValue : nil,
            &returnedData
        )
        guard code == kCFMessagePortSuccess else {
            fputs("error: \(portError(code))\n", stderr)
            return nil
        }
        return wantResponse ? (returnedData?.takeRetainedValue() as Data?) : nil
    }

    func registerWithRemote() -> Bool {
        guard localPort != nil else { return true }
        var reg = localName
        if !arguments.isEmpty,
           let json = try? JSONSerialization.data(withJSONObject: arguments),
           let str = String(data: json, encoding: .utf8) {
            reg = "\(localName)\0\(str)"
        }
        let resp = sendToRemote(reg, msgID: .register, wantResponse: true)
        return resp != nil
    }

    func unregisterWithRemote() {
        guard localPort != nil else { return }
        sendToRemote(localName, msgID: .unregister, wantResponse: false)
    }

    // MARK: Execute

    @discardableResult
    func execute(_ command: Any) -> Bool {
        let id: MsgID = localPort != nil ? .command : .legacy
        guard let response = sendToRemote(command, msgID: id, wantResponse: true) else {
            exitCode = EX_UNAVAILABLE
            return false
        }
        if localPort != nil {
            return String(data: response, encoding: .utf8) == "ok"
        }
        fputs(colors.output, stdout)
        fwrite((response as NSData).bytes, 1, response.count, stdout)
        fputs("\(colors.reset)\n", stdout)
        return true
    }

    // MARK: Reconnect

    func checkConnection() {
        guard let rp = remotePort, !CFMessagePortIsValid(rp), autoReconnect else { return }
        fputs("Message port invalid. Reconnecting...\n", stderr)
        for _ in 0..<5 {
            sleep(2)
            if let newPort = CFMessagePortCreateRemote(nil, remoteName as CFString) {
                remotePort = newPort
                if registerWithRemote() { fputs("Re-established.\n", stderr); return }
            }
        }
        fputs("error: can't access Cosmic Hammer; is it running?\n", stderr)
        exitCode = EX_UNAVAILABLE
    }
}

// MARK: - CFMessagePort callback

private func localCallback(_: CFMessagePort?, msgid: Int32, data: CFData?, info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    guard let info, let data else { return nil }
    let client = Unmanaged<HSClient>.fromOpaque(info).takeUnretainedValue()
    let bytes = CFDataGetBytePtr(data)!
    let len = CFDataGetLength(data)

    let isStdout = msgid >= 0
    let color: String
    switch MsgID(rawValue: msgid) {
    case .output, .return: color = client.colors.output
    case .console:         color = client.colors.banner
    default:               color = client.colors.error
    }

    let stream = isStdout ? stdout : stderr
    fputs(color, stream)
    fwrite(bytes, 1, len, stream)
    fputs(client.colors.reset, stream)
    if MsgID(rawValue: msgid) == .console { fputs(client.colors.input, stdout) }

    let ack = "check".data(using: .utf8)! as CFData
    return Unmanaged.passRetained(ack)
}

// MARK: - Tab completion

private var completionClient: HSClient?

private func completionGenerator(_ text: UnsafePointer<CChar>?, _ state: Int32) -> UnsafeMutablePointer<CChar>? {
    struct State { static var items: [String] = []; static var idx = 0 }
    guard let text, let client = completionClient else { return nil }

    if state == 0 {
        State.items = []
        State.idx = 0
        let query = "require(\"hs.json\").encode(hs.completionsForInputString(\"\(String(cString: text))\"))"
        if let data = client.sendToRemote(query, msgID: .query, wantResponse: true),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            State.items = arr
        }
    }

    guard State.idx < State.items.count else { return nil }
    let s = State.items[State.idx]
    State.idx += 1
    return strdup(s)
}

private func completionHandler(_ text: UnsafePointer<CChar>?, _: Int32, _: Int32) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    rl_attempted_completion_over = 1
    return rl_completion_matches(text, completionGenerator)
}

// MARK: - Helpers

private func portError(_ code: Int32) -> String {
    switch code {
    case kCFMessagePortSendTimeout:        return "send timeout"
    case kCFMessagePortReceiveTimeout:     return "receive timeout"
    case kCFMessagePortIsInvalid:          return "message port invalid"
    case kCFMessagePortTransportError:     return "error during transport"
    case kCFMessagePortBecameInvalidError: return "message port was invalidated"
    default:                               return "unknown error"
    }
}

private func launchCosmicHammer(auto: Bool) -> Bool {
    if !auto {
        let alert = NSAlert()
        alert.addButton(withTitle: "Launch")
        alert.addButton(withTitle: "Cancel")
        alert.messageText = "Cosmic Hammer is not running"
        alert.informativeText = "Would you like to launch it now?"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID as String) {
            alert.icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        alert.alertStyle = .critical
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID as String) {
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            ok = error == nil
            sem.signal()
        }
        sem.wait()
    }
    return ok
}

private func waitForPort(_ name: String, attempts: Int = 10) -> Bool {
    for _ in 0..<attempts {
        if CFMessagePortCreateRemote(nil, name as CFString) != nil { return true }
        sleep(1)
    }
    return false
}

private func printUsage(_ cmd: String) {
    print("""

    usage: \(cmd) [arguments] [file]

        -A         Auto launch Cosmic Hammer if not running.
        -c cmd     Execute a command. May be specified multiple times.
        -C         Clone console output to this instance.
        -h         Show this help.
        -i         Force interactive mode.
        -m name    Remote port name (default: \(defaultPortName)).
        -n         Disable colors.
        -N         Force colors.
        -P         Mirror print output to console.
        -q         Quiet mode.
        -s         Read stdin (auto-detected).
        -t sec     Send/receive timeout (default: \(defaultTimeout)).
        --         Stop parsing; remaining args passed to _cli.args.
        /path      Execute file. Remaining args passed to _cli.args.

    """)
}

// MARK: - Main

@main
struct HSCli {
    static func main() {
        signal(SIGINT) { _ in fputs("\u{1b}[0m", stdout); exit(4) }

        let args = ProcessInfo.processInfo.arguments
        let cmd = (args.first ?? "hs") as String

        var readStdIn   = isatty(STDIN_FILENO) == 0
        var readFile    = false
        var interactive = !readStdIn && isatty(STDOUT_FILENO) != 0
        var useColors   = interactive
        var autoLaunch  = false
        var exitIfNoHS  = false
        var portName    = defaultPortName
        var fileName: String?
        var timeout     = defaultTimeout
        var preRun: [String] = []
        var seenColors      = false
        var seenInteractive = false

        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-i":
                readStdIn = false; interactive = true; seenInteractive = true
            case "-s":
                interactive = false; readStdIn = true
                if !seenColors { useColors = false }
            case "-A":
                exitIfNoHS = false; autoLaunch = true
            case "-a":
                exitIfNoHS = true; autoLaunch = false
            case "-n":
                useColors = false
            case "-N":
                useColors = true; seenColors = true
            case "-C", "-P", "-q":
                break
            case "-m":
                idx += 1
                guard idx < args.count else { fputs("\(cmd): -m requires an argument\n", stderr); exit(EX_USAGE) }
                portName = args[idx]
            case "-c":
                idx += 1
                guard idx < args.count else { fputs("\(cmd): -c requires an argument\n", stderr); exit(EX_USAGE) }
                preRun.append(args[idx])
                if !seenColors { useColors = false }
                if !seenInteractive { interactive = false }
            case "-t":
                idx += 1
                guard idx < args.count else { fputs("\(cmd): -t requires an argument\n", stderr); exit(EX_USAGE) }
                timeout = Double(args[idx]) ?? defaultTimeout
            case "-h", "-?":
                printUsage(cmd); exit(EX_OK)
            case "--":
                idx += 1; break
            default:
                if arg.hasPrefix("~") || arg.hasPrefix("./") || arg.hasPrefix("/") {
                    let path = NSString(string: arg).expandingTildeInPath
                    guard access(path, R_OK) == 0 else {
                        fputs("\(cmd): \(String(cString: strerror(errno))): \(arg)\n", stderr); exit(EX_USAGE)
                    }
                    fileName = path; readFile = true; readStdIn = false
                    if !seenColors { useColors = false }
                    if !seenInteractive { interactive = false }
                    idx += 1; break
                }
                fputs("\(cmd): illegal option: \(arg)\n", stderr); exit(EX_USAGE)
            }
            idx += 1
        }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID as String).isEmpty
        if !running {
            if exitIfNoHS { exit(EX_TEMPFAIL) }
            if !launchCosmicHammer(auto: autoLaunch) { exit(EX_UNAVAILABLE) }
            guard waitForPort(portName) else {
                fputs("error: can't access Cosmic Hammer; is it running with ipc loaded?\n", stderr)
                exit(EX_UNAVAILABLE)
            }
        }

        let client = HSClient(remote: portName, timeout: timeout, useColors: useColors)
        client.arguments = args
        guard client.connect() else { exit(client.exitCode) }

        if client.localPort == nil {
            fputs("\(client.colors.banner)-- Legacy mode --\(client.colors.reset)\n", stderr)
        }

        if !preRun.isEmpty {
            for cmd in preRun {
                if !client.execute(cmd) { if client.exitCode == EX_OK { client.exitCode = EX_DATAERR }; break }
            }
        }

        if client.exitCode == EX_OK && readStdIn {
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = fread(&chunk, 1, chunk.count, stdin)
                if n == 0 { break }
                buf.append(contentsOf: chunk[..<n])
            }
            if ferror(stdin) != 0 { perror("stdin"); client.exitCode = EX_NOINPUT }
            else if !client.execute(buf) { if client.exitCode == EX_OK { client.exitCode = EX_DATAERR } }
        }

        if client.exitCode == EX_OK && readFile, let fileName {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fileName)) else {
                perror("error opening file"); client.exitCode = EX_NOINPUT; exit(client.exitCode)
            }
            var content = data
            if content.count >= 2 && content[0] == UInt8(ascii: "#") && content[1] == UInt8(ascii: "!") {
                if let nl = content.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
                    content = content[(content.index(after: nl))...]  .dropFirst(0) as? Data ?? Data(content[(content.index(after: nl))...])
                }
            }
            if !client.execute(content) { if client.exitCode == EX_OK { client.exitCode = EX_DATAERR } }
        }

        if client.exitCode == EX_OK && interactive {
            client.autoReconnect = true
            completionClient = client

            let saveHistory = (CFPreferencesCopyAppValue("ipc.cli.saveHistory" as CFString, bundleID) as? Bool) ?? false
            let historyLimit: Int32 = (CFPreferencesCopyAppValue("ipc.cli.historyLimit" as CFString, bundleID) as? NSNumber)?.int32Value ?? 1000
            // History lives under the XDG state dir, independent of the config location.
            let stateHome = xdgStateHome()
            let historyPath = (stateHome as NSString).appendingPathComponent(".cli.history")

            if saveHistory {
                try? FileManager.default.createDirectory(atPath: stateHome, withIntermediateDirectories: true)
                read_history(historyPath)
            }
            print("\(client.colors.banner)Cosmic Hammer interactive prompt.\(client.colors.reset)")

            rl_attempted_completion_function = completionHandler
            rl_completion_append_character = 0

            while client.exitCode == EX_OK {
                client.checkConnection()
                guard client.exitCode == EX_OK else { break }
                fputs("\n\(client.colors.input)", stdout)
                guard let line = readline("> ") else { print(); break }
                fputs(client.colors.reset, stdout)
                let input = String(cString: line)
                if !input.isEmpty { add_history(line) }
                client.execute(input)
                free(line)
            }

            if saveHistory { write_history(historyPath); history_truncate_file(historyPath, historyLimit) }
            completionClient = nil
        }

        client.unregisterWithRemote()
        exit(client.exitCode)
    }
}
