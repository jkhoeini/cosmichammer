import Foundation
import HSDSTCore

public final class SimulatedMedia: MediaProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var mediaInfoByPath: [String: MediaInfo] = [:]
    public var thumbnailDataByPath: [String: Data] = [:]
    public var artworkDataByPath: [String: Data] = [:]
    public var metadataByPath: [String: [MediaMetadataItem]] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func mediaInfo(atPath path: String) -> MediaInfo? {
        mediaInfoByPath[path]
    }

    public func extractThumbnail(atPath path: String, time: Double) -> Data? {
        thumbnailDataByPath[path]
    }

    public func extractArtwork(atPath path: String) -> Data? {
        artworkDataByPath[path]
    }

    public func metadata(atPath path: String) -> [MediaMetadataItem] {
        metadataByPath[path] ?? []
    }
}
