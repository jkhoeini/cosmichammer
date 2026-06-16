import Foundation
import HSDSTCore

public final class SimulatedFileWatching: FileWatchingProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var watchers: [UInt64: FileWatcherHandle] = [:]
    private var callbacks: [UInt64: (FileWatchEvent) -> Void] = [:]
    private var nextWatcherID: UInt64 = 1

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func createWatcher(paths: [String], callback: @escaping (FileWatchEvent) -> Void) -> UInt64 {
        let id = nextWatcherID
        nextWatcherID += 1
        watchers[id] = FileWatcherHandle(id: id, watchedPaths: paths, isRunning: false)
        callbacks[id] = callback
        return id
    }

    public func startWatcher(watcherID: UInt64) -> Bool {
        guard var handle = watchers[watcherID] else { return false }
        guard !handle.isRunning else { return true }
        handle.isRunning = true
        watchers[watcherID] = handle
        return true
    }

    public func stopWatcher(watcherID: UInt64) -> Bool {
        guard var handle = watchers[watcherID] else { return false }
        guard handle.isRunning else { return true }
        handle.isRunning = false
        watchers[watcherID] = handle
        return true
    }

    public func destroyWatcher(watcherID: UInt64) -> Bool {
        guard watchers.removeValue(forKey: watcherID) != nil else { return false }
        callbacks.removeValue(forKey: watcherID)
        return true
    }

    public func isWatcherRunning(watcherID: UInt64) -> Bool {
        watchers[watcherID]?.isRunning ?? false
    }

    public func watchedPaths(watcherID: UInt64) -> [String]? {
        watchers[watcherID]?.watchedPaths
    }

    /// Inject a simulated file-system event into a running watcher, triggering its callback.
    public func simulateEvent(watcherID: UInt64, paths: [String], flags: [UInt32]) {
        guard let handle = watchers[watcherID], handle.isRunning,
              let callback = callbacks[watcherID] else { return }
        let eventIDs = paths.enumerated().map { UInt64($0.offset + 1) }
        let event = FileWatchEvent(paths: paths, flags: flags, eventIDs: eventIDs)
        callback(event)
    }
}
