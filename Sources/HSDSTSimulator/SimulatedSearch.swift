import Foundation
import HSDSTCore

public final class SimulatedSearch: SearchProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var queries: [UInt64: SpotlightQueryHandle] = [:]
    public var queryResultsStore: [UInt64: [SpotlightItem]] = [:]
    public var preloadedResults: [String: [SpotlightItem]] = [:]
    private var callbacks: [UInt64: ([SpotlightItem]) -> Void] = [:]
    private var nextQueryID: UInt64 = 1

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func createQuery(queryString: String, searchScopes: [String]?,
                            sortDescriptors: [(attribute: String, ascending: Bool)]?,
                            attributes: [String]?) -> UInt64 {
        let id = nextQueryID
        nextQueryID += 1
        queries[id] = SpotlightQueryHandle(id: id, queryString: queryString)
        queryResultsStore[id] = []
        return id
    }

    public func startQuery(queryID: UInt64) -> Bool {
        guard var handle = queries[queryID] else { return false }
        guard !handle.isRunning else { return false }

        handle.isRunning = true
        handle.isGathering = true
        queries[queryID] = handle

        // Resolve results from preloaded data
        let results = preloadedResults[handle.queryString] ?? []
        queryResultsStore[queryID] = results

        // Finish gathering immediately in simulation
        handle.isGathering = false
        handle.resultCount = results.count
        queries[queryID] = handle

        // Fire callback if registered
        if let cb = callbacks[queryID] {
            cb(results)
        }

        return true
    }

    public func stopQuery(queryID: UInt64) -> Bool {
        guard var handle = queries[queryID] else { return false }
        guard handle.isRunning else { return false }

        handle.isRunning = false
        handle.isGathering = false
        queries[queryID] = handle
        return true
    }

    public func destroyQuery(queryID: UInt64) -> Bool {
        guard queries.removeValue(forKey: queryID) != nil else { return false }
        queryResultsStore.removeValue(forKey: queryID)
        callbacks.removeValue(forKey: queryID)
        return true
    }

    public func queryResults(queryID: UInt64) -> [SpotlightItem] {
        queryResultsStore[queryID] ?? []
    }

    public func queryCount(queryID: UInt64) -> Int {
        queryResultsStore[queryID]?.count ?? 0
    }

    public func queryResult(queryID: UInt64, index: Int) -> SpotlightItem? {
        guard let results = queryResultsStore[queryID],
              index >= 0, index < results.count else { return nil }
        return results[index]
    }

    public func queryIsGathering(queryID: UInt64) -> Bool {
        queries[queryID]?.isGathering ?? false
    }

    public func setQueryCallback(queryID: UInt64, callback: @escaping ([SpotlightItem]) -> Void) -> Bool {
        guard queries[queryID] != nil else { return false }
        callbacks[queryID] = callback
        return true
    }
}
