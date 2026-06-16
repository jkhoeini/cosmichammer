import Foundation

public struct SpotlightItem: Sendable {
    public var path: String
    public var displayName: String
    public var contentType: String?
    public var lastModified: Date?
    public var size: Int64?
    public var attributes: [String: String]

    public init(path: String, displayName: String, contentType: String? = nil,
                lastModified: Date? = nil, size: Int64? = nil,
                attributes: [String: String] = [:]) {
        self.path = path
        self.displayName = displayName
        self.contentType = contentType
        self.lastModified = lastModified
        self.size = size
        self.attributes = attributes
    }
}

public struct SpotlightQueryHandle: Sendable {
    public var id: UInt64
    public var queryString: String
    public var isRunning: Bool
    public var isGathering: Bool
    public var resultCount: Int

    public init(id: UInt64, queryString: String, isRunning: Bool = false,
                isGathering: Bool = false, resultCount: Int = 0) {
        self.id = id
        self.queryString = queryString
        self.isRunning = isRunning
        self.isGathering = isGathering
        self.resultCount = resultCount
    }
}

public protocol SearchProtocol: AnyObject {
    func createQuery(queryString: String, searchScopes: [String]?,
                     sortDescriptors: [(attribute: String, ascending: Bool)]?,
                     attributes: [String]?) -> UInt64
    func startQuery(queryID: UInt64) -> Bool
    func stopQuery(queryID: UInt64) -> Bool
    func destroyQuery(queryID: UInt64) -> Bool
    func queryResults(queryID: UInt64) -> [SpotlightItem]
    func queryCount(queryID: UInt64) -> Int
    func queryResult(queryID: UInt64, index: Int) -> SpotlightItem?
    func queryIsGathering(queryID: UInt64) -> Bool
    func setQueryCallback(queryID: UInt64, callback: @escaping ([SpotlightItem]) -> Void) -> Bool
}
