import CoreServices
import Foundation
import HSDSTCore

final class ProductionFileWatching: FileWatchingProtocol {
    private var nextID: UInt64 = 1
    private var watchers: [UInt64: WatcherState] = [:]

    private class WatcherState {
        let paths: [String]
        let callback: (FileWatchEvent) -> Void
        var stream: FSEventStreamRef?
        var isRunning: Bool = false

        init(paths: [String], callback: @escaping (FileWatchEvent) -> Void) {
            self.paths = paths
            self.callback = callback
        }
    }

    func createWatcher(paths: [String], callback: @escaping (FileWatchEvent) -> Void) -> UInt64 {
        let id = nextID
        nextID += 1
        let state = WatcherState(paths: paths, callback: callback)

        let unmanaged = Unmanaged.passRetained(state)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagWatchRoot)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)

        let fsCallback: FSEventStreamCallback = {
            _, clientInfo, numEvents, eventPaths, eventFlags, eventIds in
            guard let clientInfo = clientInfo else { return }
            let watcher = Unmanaged<WatcherState>.fromOpaque(clientInfo).takeUnretainedValue()

            guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            var paths: [String] = []
            var flags: [UInt32] = []
            var ids: [UInt64] = []
            for i in 0..<numEvents {
                paths.append(cfPaths[i])
                flags.append(eventFlags[i])
                ids.append(eventIds[i])
            }
            let event = FileWatchEvent(paths: paths, flags: flags, eventIDs: ids)
            watcher.callback(event)
        }

        let stream = FSEventStreamCreate(
            nil, fsCallback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, flags
        )
        state.stream = stream
        watchers[id] = state
        return id
    }

    func startWatcher(watcherID: UInt64) -> Bool {
        guard let state = watchers[watcherID], let stream = state.stream,
            !state.isRunning
        else { return false }
        FSEventStreamScheduleWithRunLoop(
            stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        state.isRunning = true
        return true
    }

    func stopWatcher(watcherID: UInt64) -> Bool {
        guard let state = watchers[watcherID], let stream = state.stream,
            state.isRunning
        else { return false }
        FSEventStreamStop(stream)
        FSEventStreamUnscheduleFromRunLoop(
            stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        state.isRunning = false
        return true
    }

    func destroyWatcher(watcherID: UInt64) -> Bool {
        guard let state = watchers.removeValue(forKey: watcherID) else { return false }
        if let stream = state.stream {
            if state.isRunning {
                FSEventStreamStop(stream)
                FSEventStreamUnscheduleFromRunLoop(
                    stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            }
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        return true
    }

    func isWatcherRunning(watcherID: UInt64) -> Bool {
        watchers[watcherID]?.isRunning ?? false
    }

    func watchedPaths(watcherID: UInt64) -> [String]? {
        watchers[watcherID]?.paths
    }
}
