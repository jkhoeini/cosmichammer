import Foundation
import os.log

struct AppLifecycleDirectories: Equatable {
    let configDir: String
}

enum AppLifecycleError: Error, CustomStringConvertible, LocalizedError {
    case changeDirectoryFailed(String)

    var description: String {
        switch self {
        case .changeDirectoryFailed(let path):
            return "Unable to change current directory to \(path)"
        }
    }

    var errorDescription: String? {
        description
    }
}

enum AppLifecycle {
    /// Default config file when no explicit `MJConfigFile` override is set:
    /// `${XDG_CONFIG_HOME:-~/.config}/cosmichammer/init.lua`. Hard cut — there is
    /// no `~/.cosmic-hammer` fallback.
    static var defaultConfigFile: String {
        (XDGPaths.configHome as NSString).appendingPathComponent("init.lua")
    }

    static func registerDefaultDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "NSApplicationCrashOnExceptions": true,
            "MJShowDockIconKey": false,
            "MJShowMenuIconKey": true,
            "HSAutoLoadExtensions": true,
            "HSAppleScriptEnabledKey": false,
            "HSOpenConsoleOnDockClickKey": true,
            "HSPreferencesDarkModeKey": false,
            "HSConsoleDarkModeKey": false,
        ])
    }

    static func applyStoredConfigFile(_ defaults: UserDefaults = .standard) {
        if let userConfigFile = defaults.string(forKey: "MJConfigFile") {
            MJConfigFileSet(userConfigFile as NSString)
        }
    }

    static func currentDirectories() -> AppLifecycleDirectories {
        let configDir = MJConfigDir() as String
        return AppLifecycleDirectories(
            configDir: configDir
        )
    }

    /// Create the directories Cosmic Hammer writes to on launch. The config dir
    /// tracks `MJConfigFile` (so an explicit override is honored); state and data
    /// are fixed XDG locations independent of where the config file lives.
    static func prepareConfigDirectories() throws {
        // Config dir first: a blocked/invalid config path should surface before
        // we touch the XDG state/data dirs.
        try MJEnsureDirectoryExistsOrThrow(MJConfigDir() as String)
        try MJEnsureDirectoryExistsOrThrow(XDGPaths.stateHome)
        try MJEnsureDirectoryExistsOrThrow(XDGPaths.dataHome)
    }

    static func changeToConfigDirectory(fileManager: FileManager = .default) throws {
        let configDir = MJConfigDir() as String
        guard fileManager.changeCurrentDirectoryPath(configDir) else {
            throw AppLifecycleError.changeDirectoryFailed(configDir)
        }
    }
}
