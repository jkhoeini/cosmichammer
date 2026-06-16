import Foundation

public struct FileWatchEvent: Sendable {
    public var paths: [String]
    public var flags: [UInt32]
    public var eventIDs: [UInt64]

    public init(paths: [String], flags: [UInt32], eventIDs: [UInt64]) {
        self.paths = paths
        self.flags = flags
        self.eventIDs = eventIDs
    }
}

public struct FileWatcherHandle: Sendable {
    public var id: UInt64
    public var watchedPaths: [String]
    public var isRunning: Bool

    public init(id: UInt64, watchedPaths: [String], isRunning: Bool = false) {
        self.id = id
        self.watchedPaths = watchedPaths
        self.isRunning = isRunning
    }
}

public protocol FileWatchingProtocol: AnyObject {
    func createWatcher(paths: [String], callback: @escaping (FileWatchEvent) -> Void) -> UInt64
    func startWatcher(watcherID: UInt64) -> Bool
    func stopWatcher(watcherID: UInt64) -> Bool
    func destroyWatcher(watcherID: UInt64) -> Bool
    func isWatcherRunning(watcherID: UInt64) -> Bool
    func watchedPaths(watcherID: UInt64) -> [String]?
}
