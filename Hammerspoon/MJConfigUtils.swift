import Foundation

/// Returns the directory containing the user's Hammerspoon config file.
@_cdecl("MJConfigDir")
func MJConfigDir() -> NSString {
    return (MJConfigFileFullPath() as NSString).deletingLastPathComponent as NSString
}

/// Returns the absolute (symlink-resolved) path to the config directory.
@_cdecl("MJConfigDirAbsolute")
func MJConfigDirAbsolute() -> NSString {
    return (MJConfigDir() as String as NSString).resolvingSymlinksInPath as NSString
}

/// Returns the full, standardized path to the Hammerspoon config file.
@_cdecl("MJConfigFileFullPath")
func MJConfigFileFullPath() -> NSString {
    return (MJConfigFile as String as NSString).standardizingPath as NSString
}
