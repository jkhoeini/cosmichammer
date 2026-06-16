import Foundation
import HSDSTCore

final class ProductionSearch: SearchProtocol {
    private var nextID: UInt64 = 1
    private var queries: [UInt64: QueryState] = [:]

    private class QueryState: NSObject {
        let query: NSMetadataQuery
        var callback: (([SpotlightItem]) -> Void)?
        var observer: NSObjectProtocol?

        init(query: NSMetadataQuery) {
            self.query = query
        }
    }

    func createQuery(queryString: String, searchScopes: [String]?,
                     sortDescriptors: [(attribute: String, ascending: Bool)]?,
                     attributes: [String]?) -> UInt64
    {
        let mdQuery = NSMetadataQuery()
        mdQuery.predicate = NSPredicate(fromMetadataQueryString: queryString)

        if let scopes = searchScopes {
            mdQuery.searchScopes = scopes
        }
        if let sorts = sortDescriptors {
            mdQuery.sortDescriptors = sorts.map {
                NSSortDescriptor(key: $0.attribute, ascending: $0.ascending)
            }
        }
        if let attrs = attributes {
            mdQuery.valueListAttributes = attrs
        }

        let id = nextID
        nextID += 1
        queries[id] = QueryState(query: mdQuery)
        return id
    }

    func startQuery(queryID: UInt64) -> Bool {
        guard let state = queries[queryID] else { return false }
        return state.query.start()
    }

    func stopQuery(queryID: UInt64) -> Bool {
        guard let state = queries[queryID] else { return false }
        state.query.stop()
        return true
    }

    func destroyQuery(queryID: UInt64) -> Bool {
        guard let state = queries.removeValue(forKey: queryID) else { return false }
        state.query.stop()
        if let observer = state.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        return true
    }

    func queryResults(queryID: UInt64) -> [SpotlightItem] {
        guard let state = queries[queryID] else { return [] }
        state.query.disableUpdates()
        defer { state.query.enableUpdates() }

        var items: [SpotlightItem] = []
        for i in 0..<state.query.resultCount {
            if let item = extractItem(state.query, at: i) {
                items.append(item)
            }
        }
        return items
    }

    func queryCount(queryID: UInt64) -> Int {
        guard let state = queries[queryID] else { return 0 }
        return state.query.resultCount
    }

    func queryResult(queryID: UInt64, index: Int) -> SpotlightItem? {
        guard let state = queries[queryID],
              index >= 0 && index < state.query.resultCount
        else { return nil }
        state.query.disableUpdates()
        defer { state.query.enableUpdates() }
        return extractItem(state.query, at: index)
    }

    func queryIsGathering(queryID: UInt64) -> Bool {
        guard let state = queries[queryID] else { return false }
        return state.query.isGathering
    }

    func setQueryCallback(queryID: UInt64,
                          callback: @escaping ([SpotlightItem]) -> Void) -> Bool
    {
        guard let state = queries[queryID] else { return false }
        state.callback = callback

        // Remove old observer if present
        if let observer = state.observer {
            NotificationCenter.default.removeObserver(observer)
        }

        state.observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: state.query, queue: .main
        ) { [weak self, weak state] _ in
            guard let self = self, let state = state else { return }
            let results = self.queryResults(queryID: queryID)
            state.callback?(results)
        }
        return true
    }

    // MARK: - Private

    private func extractItem(_ query: NSMetadataQuery, at index: Int) -> SpotlightItem? {
        guard let mdItem = query.result(at: index) as? NSMetadataItem else { return nil }
        let path = mdItem.value(forAttribute: NSMetadataItemPathKey) as? String ?? ""
        let name = mdItem.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? ""
        let contentType = mdItem.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let lastModified = mdItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
        let size = mdItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int64
        return SpotlightItem(path: path, displayName: name,
                             contentType: contentType, lastModified: lastModified,
                             size: size, attributes: [:])
    }
}
