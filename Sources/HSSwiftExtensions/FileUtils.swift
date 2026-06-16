import Foundation
import HSDSTCore
import os.log

func MJEnsureDirectoryExistsOrThrow(_ dir: String) throws {
    if let env = environmentGetGlobalOrNil() {
        try env.fileSystem.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } else {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    }
}

@_cdecl("MJEnsureDirectoryExists")
@discardableResult
func MJEnsureDirectoryExists(_ dir: NSString) -> Bool {
    do {
        try MJEnsureDirectoryExistsOrThrow(dir as String)
        return true
    } catch {
        os_log(.error, "Unable to create directory %{public}s: %{public}s", dir as String, error.localizedDescription)
        return false
    }
}
