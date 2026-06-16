import Foundation

public struct FileAttributes {
    public var size: UInt64
    public var modificationDate: Date?
    public var creationDate: Date?
    public var fileType: FileType
    public var posixPermissions: Int
    public var ownerAccountName: String?
    public var groupOwnerAccountName: String?

    public enum FileType: String, Sendable {
        case regular, directory, symbolicLink, socket, characterSpecial, blockSpecial, unknown
    }

    public init(size: UInt64 = 0,
                modificationDate: Date? = nil,
                creationDate: Date? = nil,
                fileType: FileType = .regular,
                posixPermissions: Int = 0o644,
                ownerAccountName: String? = nil,
                groupOwnerAccountName: String? = nil) {
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.fileType = fileType
        self.posixPermissions = posixPermissions
        self.ownerAccountName = ownerAccountName
        self.groupOwnerAccountName = groupOwnerAccountName
    }
}

public protocol FileSystemProtocol: AnyObject {
    func fileExists(atPath path: String) -> Bool
    func isDirectory(atPath path: String) -> Bool
    func contentsOfFile(atPath path: String) throws -> Data
    func writeFile(atPath path: String, contents: Data, atomically: Bool) throws
    func removeItem(atPath path: String) throws
    func moveItem(from src: String, to dst: String) throws
    func copyItem(from src: String, to dst: String) throws
    func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func attributesOfItem(atPath path: String) throws -> FileAttributes
    func setAttributes(posixPermissions: Int?, ofItemAtPath path: String) throws
    func currentDirectoryPath() -> String
    func homeDirectory() -> String
    func temporaryDirectory() -> String
    func symlinkDestination(atPath path: String) throws -> String
    func createSymbolicLink(atPath path: String, withDestinationPath dst: String) throws
    func changeCurrentDirectory(to path: String) throws
}
