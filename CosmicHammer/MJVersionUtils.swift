import Foundation

// MARK: - C-visible API (preserves the symbols declared in MJVersionUtils.h)

/// Returns the integer-encoded version of the running app (cached after first call).
/// Format: major * 10000 + minor * 100 + bugfix
@_cdecl("MJVersionFromThisApp")
func MJVersionFromThisApp() -> Int32 {
    struct Once {
        static let value: Int32 = {
            guard let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
                return 0
            }
            return versionFromString(version)
        }()
    }
    return Once.value
}

/// Parses a version string like "1.2.3" into an integer: major * 10000 + minor * 100 + bugfix.
@_cdecl("MJVersionFromString")
func MJVersionFromString(_ str: NSString) -> Int32 {
    return versionFromString(str as String)
}

// MARK: - Internal

private func versionFromString(_ str: String) -> Int32 {
    let scanner = Scanner(string: str)
    let major = scanner.scanInt() ?? 0
    _ = scanner.scanString(".")
    let minor = scanner.scanInt() ?? 0
    var bugfix = 0
    if scanner.scanString(".") != nil {
        bugfix = scanner.scanInt() ?? 0
    }
    return Int32(major * 10000 + minor * 100 + bugfix)
}
