import Foundation

public struct MediaInfo: Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var format: String

    public init(duration: Double = 0.0, width: Int = 0, height: Int = 0,
                format: String = "unknown") {
        self.duration = duration
        self.width = width
        self.height = height
        self.format = format
    }
}

public struct MediaMetadataItem: Sendable {
    public var key: String
    public var value: String
    public var dataValue: Data?

    public init(key: String = "", value: String = "", dataValue: Data? = nil) {
        self.key = key
        self.value = value
        self.dataValue = dataValue
    }
}

public protocol MediaProtocol: AnyObject {
    func mediaInfo(atPath path: String) -> MediaInfo?
    func extractThumbnail(atPath path: String, time: Double) -> Data?
    func extractArtwork(atPath path: String) -> Data?
    func metadata(atPath path: String) -> [MediaMetadataItem]
}
