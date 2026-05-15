import Foundation

private var _MJConfigFile: NSString = "~/.hammerspoon/init.lua"

@_cdecl("MJConfigFileGet")
func MJConfigFileGet() -> NSString {
    return _MJConfigFile
}

@_cdecl("MJConfigFileSet")
func MJConfigFileSet(_ path: NSString) {
    _MJConfigFile = path
}

@_cdecl("MJConfigFileFullPath")
func MJConfigFileFullPath() -> NSString {
    return (_MJConfigFile as String).standardizingPath as NSString
}

@_cdecl("MJConfigDir")
func MJConfigDir() -> NSString {
    return (MJConfigFileFullPath() as String).deletingLastPathComponent as NSString
}

@_cdecl("MJConfigDirAbsolute")
func MJConfigDirAbsolute() -> NSString {
    return (MJConfigDir() as String).resolvingSymlinksInPath as NSString
}

private extension String {
    var standardizingPath: String {
        return (self as NSString).standardizingPath
    }
    var deletingLastPathComponent: String {
        return (self as NSString).deletingLastPathComponent
    }
    var resolvingSymlinksInPath: String {
        return (self as NSString).resolvingSymlinksInPath
    }
}
