import Foundation
import HSDSTCore

final class ProductionMedia: MediaProtocol {
    func mediaInfo(atPath path: String) -> MediaInfo? { nil }
    func extractThumbnail(atPath path: String, time: Double) -> Data? { nil }
    func extractArtwork(atPath path: String) -> Data? { nil }
    func metadata(atPath path: String) -> [MediaMetadataItem] { [] }
}
