import Foundation

/// XDG Base Directory paths for Cosmic Hammer.
///
/// All directories live under the app-name segment `cosmichammer`. Each base
/// honors its `XDG_*_HOME` environment variable when set to an absolute path
/// (per the spec, relative values are invalid and ignored) and otherwise falls
/// back to the spec default under `$HOME`.
///
/// Hard cut: there is no legacy `~/.cosmic-hammer` fallback. The only way to
/// point Cosmic Hammer at a non-XDG config location is an explicit `MJConfigFile`
/// override (see `AppLifecycle.applyStoredConfigFile`).
enum XDGPaths {
    static let appName = "cosmichammer"

    /// `${XDG_CONFIG_HOME:-~/.config}/cosmichammer`
    static var configHome: String { resolve("XDG_CONFIG_HOME", default: ".config") }
    /// `${XDG_STATE_HOME:-~/.local/state}/cosmichammer`
    static var stateHome: String { resolve("XDG_STATE_HOME", default: ".local/state") }
    /// `${XDG_DATA_HOME:-~/.local/share}/cosmichammer`
    static var dataHome: String { resolve("XDG_DATA_HOME", default: ".local/share") }
    /// `${XDG_CACHE_HOME:-~/.cache}/cosmichammer`
    static var cacheHome: String { resolve("XDG_CACHE_HOME", default: ".cache") }

    private static func resolve(_ envVar: String, default fallback: String) -> String {
        let base: String
        if let value = ProcessInfo.processInfo.environment[envVar], value.hasPrefix("/") {
            base = value
        } else {
            base = (NSHomeDirectory() as NSString).appendingPathComponent(fallback)
        }
        return (base as NSString).appendingPathComponent(appName)
    }
}
