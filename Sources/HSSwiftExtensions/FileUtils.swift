import Foundation
import os.log

func MJEnsureDirectoryExistsOrThrow(_ dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
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
