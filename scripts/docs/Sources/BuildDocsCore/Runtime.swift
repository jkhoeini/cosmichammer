import Foundation

public var debug: Bool = false
public var failOnWarn: Bool = true
public var hasWarned: Bool = false
public var lintMode: Bool = false
public var lints: [LintError] = []
public var standaloneMode: Bool = false

public func dbg(_ msg: String) {
    if debug {
        print("DEBUG: \(msg)")
    }
}

public func warn(_ msg: String) {
    print("WARN: \(msg)")
    hasWarned = true
}

public func fatal(_ msg: String) -> Never {
    print("ERROR: \(msg)")
    exit(1)
}
