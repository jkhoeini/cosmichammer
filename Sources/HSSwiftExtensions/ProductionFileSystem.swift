import Foundation
import HSDSTCore

final class ProductionFileSystem: FileSystemProtocol {
    private let fm = FileManager.default

    func fileExists(atPath path: String) -> Bool { fm.fileExists(atPath: path) }

    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func contentsOfFile(atPath path: String) throws -> Data {
        guard let data = fm.contents(atPath: path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                          userInfo: [NSFilePathErrorKey: path])
        }
        return data
    }

    func writeFile(atPath path: String, contents: Data, atomically: Bool) throws {
        try contents.write(to: URL(fileURLWithPath: path), options: atomically ? .atomic : [])
    }

    func removeItem(atPath path: String) throws { try fm.removeItem(atPath: path) }

    func moveItem(from src: String, to dst: String) throws { try fm.moveItem(atPath: src, toPath: dst) }

    func copyItem(from src: String, to dst: String) throws { try fm.copyItem(atPath: src, toPath: dst) }

    func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        try fm.contentsOfDirectory(atPath: path)
    }

    func attributesOfItem(atPath path: String) throws -> FileAttributes {
        let attrs = try fm.attributesOfItem(atPath: path)
        let fileType: FileAttributes.FileType
        switch attrs[.type] as? FileAttributeType {
        case .typeDirectory: fileType = .directory
        case .typeSymbolicLink: fileType = .symbolicLink
        case .typeSocket: fileType = .socket
        case .typeCharacterSpecial: fileType = .characterSpecial
        case .typeBlockSpecial: fileType = .blockSpecial
        default: fileType = .regular
        }
        return FileAttributes(
            size: (attrs[.size] as? UInt64) ?? 0,
            modificationDate: attrs[.modificationDate] as? Date,
            creationDate: attrs[.creationDate] as? Date,
            fileType: fileType,
            posixPermissions: (attrs[.posixPermissions] as? Int) ?? 0,
            ownerAccountName: attrs[.ownerAccountName] as? String,
            groupOwnerAccountName: attrs[.groupOwnerAccountName] as? String
        )
    }

    func setAttributes(posixPermissions: Int?, ofItemAtPath path: String) throws {
        var attrs: [FileAttributeKey: Any] = [:]
        if let perms = posixPermissions { attrs[.posixPermissions] = perms }
        try fm.setAttributes(attrs, ofItemAtPath: path)
    }

    func currentDirectoryPath() -> String { fm.currentDirectoryPath }
    func homeDirectory() -> String { NSHomeDirectory() }
    func temporaryDirectory() -> String { NSTemporaryDirectory() }

    func symlinkDestination(atPath path: String) throws -> String {
        try fm.destinationOfSymbolicLink(atPath: path)
    }

    func createSymbolicLink(atPath path: String, withDestinationPath dst: String) throws {
        try fm.createSymbolicLink(atPath: path, withDestinationPath: dst)
    }

    func changeCurrentDirectory(to path: String) throws {
        guard fm.changeCurrentDirectoryPath(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                          userInfo: [NSFilePathErrorKey: path])
        }
    }
}
