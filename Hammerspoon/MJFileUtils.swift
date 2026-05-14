import Foundation

/// Ensures the directory at the given path exists, creating intermediate directories as needed.
/// - Parameter dir: The path of the directory to create.
/// - Returns: `true` if the directory was created or already exists, `false` on failure.
@objc
@discardableResult
func MJEnsureDirectoryExists(_ dir: String) -> Bool {
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return true
    } catch {
        return false
    }
}
