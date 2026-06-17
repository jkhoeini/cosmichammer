import Foundation
import HSDSTCore

public final class SimulatedFileSystem: FileSystemProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig
    private let clock: any ClockProtocol

    public struct FSNode {
        public var isDirectory: Bool
        public var contents: Data?
        public var children: [String: FSNode]?
        public var attributes: FileAttributes

        public static func file(_ data: Data, permissions: Int = 0o644) -> FSNode {
            FSNode(isDirectory: false, contents: data, children: nil,
                   attributes: FileAttributes(size: UInt64(data.count), fileType: .regular, posixPermissions: permissions))
        }

        public static func directory(permissions: Int = 0o755) -> FSNode {
            FSNode(isDirectory: true, contents: nil, children: [:],
                   attributes: FileAttributes(fileType: .directory, posixPermissions: permissions))
        }
    }

    public var root: FSNode = .directory()
    public var cwd: String = "/tmp"
    public var home: String = "/Users/test"
    public var tmp: String = "/tmp"

    public init(rng: RPRNG, faults: FaultConfig, clock: any ClockProtocol) {
        self.rng = rng
        self.faults = faults
        self.clock = clock
    }

    public func seed(path: String, node: FSNode) {
        setNode(atPath: path, node: node)
    }

    private func clockDate() -> Date {
        Date(timeIntervalSince1970: clock.now())
    }

    // MARK: - FileSystemProtocol

    public func fileExists(atPath path: String) -> Bool {
        resolveNode(atPath: path) != nil
    }

    public func isDirectory(atPath path: String) -> Bool {
        resolveNode(atPath: path)?.isDirectory ?? false
    }

    public func contentsOfFile(atPath path: String) throws -> Data {
        if rng.boolean(probability: faults.fileReadFailProbability) {
            throw SimulatedError.injectedFault("File read failed (simulated)")
        }
        guard let node = resolveNode(atPath: path), !node.isDirectory else {
            throw SimulatedError.fileNotFound(path)
        }
        return node.contents ?? Data()
    }

    public func writeFile(atPath path: String, contents: Data, atomically: Bool) throws {
        if rng.boolean(probability: faults.fileWriteFailProbability) {
            throw SimulatedError.injectedFault("File write failed (simulated)")
        }
        if rng.boolean(probability: faults.diskFullProbability) {
            throw SimulatedError.injectedFault("Disk full (simulated)")
        }
        let now = clockDate()
        var node = FSNode.file(contents)
        if let existing = resolveNode(atPath: path) {
            node.attributes.creationDate = existing.attributes.creationDate
        } else {
            node.attributes.creationDate = now
        }
        node.attributes.modificationDate = now
        setNode(atPath: path, node: node)
    }

    public func removeItem(atPath path: String) throws {
        removeNode(atPath: path)
    }

    public func moveItem(from src: String, to dst: String) throws {
        guard var node = resolveNode(atPath: src) else {
            throw SimulatedError.fileNotFound(src)
        }
        node.attributes.modificationDate = clockDate()
        setNode(atPath: dst, node: node)
        removeNode(atPath: src)
    }

    public func copyItem(from src: String, to dst: String) throws {
        guard let node = resolveNode(atPath: src) else {
            throw SimulatedError.fileNotFound(src)
        }
        setNode(atPath: dst, node: node)
    }

    public func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws {
        let now = clockDate()
        if withIntermediateDirectories {
            var current = ""
            for component in pathComponents(path) {
                current += "/" + component
                if resolveNode(atPath: current) == nil {
                    var node = FSNode.directory()
                    node.attributes.creationDate = now
                    node.attributes.modificationDate = now
                    setNode(atPath: current, node: node)
                }
            }
        } else {
            var node = FSNode.directory()
            node.attributes.creationDate = now
            node.attributes.modificationDate = now
            setNode(atPath: path, node: node)
        }
    }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let node = resolveNode(atPath: path), node.isDirectory else {
            throw SimulatedError.fileNotFound(path)
        }
        return Array(node.children?.keys ?? [:].keys).sorted()
    }

    public func attributesOfItem(atPath path: String) throws -> FileAttributes {
        guard let node = resolveNode(atPath: path) else {
            throw SimulatedError.fileNotFound(path)
        }
        return node.attributes
    }

    public func setAttributes(posixPermissions: Int?, ofItemAtPath path: String) throws {
        guard var node = resolveNode(atPath: path) else {
            throw SimulatedError.fileNotFound(path)
        }
        if let perms = posixPermissions {
            node.attributes.posixPermissions = perms
        }
        setNode(atPath: path, node: node)
    }

    public func currentDirectoryPath() -> String { cwd }
    public func homeDirectory() -> String { home }
    public func temporaryDirectory() -> String { tmp.hasSuffix("/") ? tmp : tmp + "/" }

    public func symlinkDestination(atPath path: String) throws -> String {
        throw SimulatedError.notSupported("symlink resolution")
    }

    public func createSymbolicLink(atPath path: String, withDestinationPath dst: String) throws {
        throw SimulatedError.notSupported("symlink creation")
    }

    public func changeCurrentDirectory(to path: String) throws {
        guard resolveNode(atPath: path) != nil && isDirectory(atPath: path) else {
            throw SimulatedError.fileNotFound(path)
        }
        cwd = path
    }

    // MARK: - Internal tree navigation

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func resolveNode(atPath path: String) -> FSNode? {
        let components = pathComponents(path)
        var current = root
        for component in components {
            guard let children = current.children, let child = children[component] else { return nil }
            current = child
        }
        return current
    }

    private func setNode(atPath path: String, node: FSNode) {
        let components = pathComponents(path)
        guard !components.isEmpty else { return }
        setNodeRecursive(components: components[...], node: node, parent: &root)
    }

    private func setNodeRecursive(components: ArraySlice<String>, node: FSNode, parent: inout FSNode) {
        guard let first = components.first else { return }
        if parent.children == nil { parent.children = [:] }
        if components.count == 1 {
            parent.children?[first] = node
        } else {
            if parent.children?[first] == nil {
                parent.children?[first] = .directory()
            }
            setNodeRecursive(components: components.dropFirst(), node: node, parent: &parent.children![first]!)
        }
    }

    private func removeNode(atPath path: String) {
        let components = pathComponents(path)
        guard components.count > 0 else { return }
        removeNodeRecursive(components: components[...], parent: &root)
    }

    private func removeNodeRecursive(components: ArraySlice<String>, parent: inout FSNode) {
        guard let first = components.first else { return }
        if components.count == 1 {
            parent.children?.removeValue(forKey: first)
        } else if parent.children?[first] != nil {
            removeNodeRecursive(components: components.dropFirst(), parent: &parent.children![first]!)
        }
    }
}

public enum SimulatedError: Error, LocalizedError {
    case fileNotFound(String)
    case injectedFault(String)
    case notSupported(String)
    case permissionDenied(String)
    case timeout(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "File not found: \(p)"
        case .injectedFault(let m): return m
        case .notSupported(let m): return "Not supported: \(m)"
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .timeout(let m): return "Timeout: \(m)"
        case .connectionFailed(let m): return "Connection failed: \(m)"
        }
    }
}
