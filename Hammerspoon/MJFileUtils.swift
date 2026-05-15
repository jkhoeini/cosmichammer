import Foundation

@_cdecl("MJEnsureDirectoryExists")
@discardableResult
func MJEnsureDirectoryExists(_ dir: NSString) -> Bool {
    do {
        try FileManager.default.createDirectory(atPath: dir as String, withIntermediateDirectories: true, attributes: nil)
        return true
    } catch {
        return false
    }
}
