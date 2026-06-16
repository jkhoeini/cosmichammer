import Foundation
import HSDSTCore

final class ProductionLocation: LocationProtocol {
    func startUpdating(handler: @escaping (LocationCoordinate?, Error?) -> Void) {
        // Stub — actual implementation uses CLLocationManager
        handler(nil, NSError(domain: "HSDSTCore", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Location not yet migrated to DST protocol"]))
    }

    func stopUpdating() {}

    func currentLocation() -> LocationCoordinate? { nil }

    func authorizationStatus() -> Int { 0 }

    func requestAuthorization() {}

    func geocode(latitude: Double, longitude: Double,
                 completion: @escaping ([String]?, Error?) -> Void) {
        completion(nil, nil)
    }
}
