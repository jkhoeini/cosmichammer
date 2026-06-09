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
    static let defaultConfigFile = "~/.cosmic-hammer/init.lua"

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

    static func prepareConfigDirectories() throws {
        try MJEnsureDirectoryExistsOrThrow(MJConfigDir() as String)
    }

    static func changeToConfigDirectory(fileManager: FileManager = .default) throws {
        let configDir = MJConfigDir() as String
        guard fileManager.changeCurrentDirectoryPath(configDir) else {
            throw AppLifecycleError.changeDirectoryFailed(configDir)
        }
    }
}
