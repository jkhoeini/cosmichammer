import Foundation
import os.log

struct AppLifecycleDirectories: Equatable {
    let configDir: String
    let configDirAbsolute: String
    let spoonsDir: String
}

enum AppLifecycleError: Error, CustomStringConvertible, LocalizedError {
    case pathExistsButIsNotDirectory(String)
    case changeDirectoryFailed(String)

    var description: String {
        switch self {
        case .pathExistsButIsNotDirectory(let path):
            return "\(path) exists, but is not a directory"
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
        let configDirAbsolute = MJConfigDirAbsolute() as String
        return AppLifecycleDirectories(
            configDir: configDir,
            configDirAbsolute: configDirAbsolute,
            spoonsDir: (configDirAbsolute as NSString).appendingPathComponent("Spoons")
        )
    }

    static func prepareConfigDirectories(
        fileManager: FileManager = .default,
        createSpoonsDirectory: Bool = true
    ) throws {
        try MJEnsureDirectoryExistsOrThrow(MJConfigDir() as String)

        guard createSpoonsDirectory else { return }

        let directories = currentDirectories()
        var spoonsPathIsDir: ObjCBool = false
        let spoonsPathExists = fileManager.fileExists(atPath: directories.spoonsDir, isDirectory: &spoonsPathIsDir)

        os_log(.info, "Determined Spoons path will be: %{public}s (exists: %{public}s, isDir: %{public}s)",
               directories.spoonsDir,
               spoonsPathExists ? "YES" : "NO",
               spoonsPathIsDir.boolValue ? "YES" : "NO")

        if spoonsPathExists && !spoonsPathIsDir.boolValue {
            throw AppLifecycleError.pathExistsButIsNotDirectory(directories.spoonsDir)
        }

        if !spoonsPathExists {
            os_log(.info, "Creating Spoons directory at: %{public}s", directories.spoonsDir)
            try fileManager.createDirectory(atPath: directories.spoonsDir, withIntermediateDirectories: true, attributes: nil)
        }
    }

    static func changeToConfigDirectory(fileManager: FileManager = .default) throws {
        let configDir = MJConfigDir() as String
        guard fileManager.changeCurrentDirectoryPath(configDir) else {
            throw AppLifecycleError.changeDirectoryFailed(configDir)
        }
    }
}
