import Foundation
import HSDSTCore
import CoreLocation

final class ProductionLocation: LocationProtocol {
    private var manager: CLLocationManager?
    private var updateHandler: ((LocationCoordinate?, Error?) -> Void)?
    private lazy var delegate = LocationDelegate(owner: self)

    func startUpdating(handler: @escaping (LocationCoordinate?, Error?) -> Void) {
        updateHandler = handler
        if manager == nil {
            let mgr = CLLocationManager()
            mgr.delegate = delegate
            manager = mgr
        }
        manager?.startUpdatingLocation()
    }

    func stopUpdating() {
        manager?.stopUpdatingLocation()
        updateHandler = nil
    }

    func currentLocation() -> LocationCoordinate? {
        guard let loc = manager?.location ?? CLLocationManager().location else { return nil }
        return LocationCoordinate(latitude: loc.coordinate.latitude,
                                  longitude: loc.coordinate.longitude)
    }

    func authorizationStatus() -> Int {
        Int(CLLocationManager.authorizationStatus().rawValue)
    }

    func requestAuthorization() {
        if manager == nil {
            let mgr = CLLocationManager()
            mgr.delegate = delegate
            manager = mgr
        }
        manager?.requestAlwaysAuthorization()
    }

    func geocode(latitude: Double, longitude: Double,
                 completion: @escaping ([String]?, Error?) -> Void) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            if let error = error {
                completion(nil, error)
                return
            }
            let addresses = placemarks?.compactMap { placemark -> String? in
                [placemark.subThoroughfare, placemark.thoroughfare,
                 placemark.locality, placemark.administrativeArea,
                 placemark.postalCode, placemark.country]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            }
            completion(addresses, nil)
        }
    }

    fileprivate func deliverUpdate(_ coordinate: LocationCoordinate?, error: Error?) {
        updateHandler?(coordinate, error)
    }
}

private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    weak var owner: ProductionLocation?

    init(owner: ProductionLocation) {
        self.owner = owner
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        owner?.deliverUpdate(LocationCoordinate(latitude: loc.coordinate.latitude,
                                                longitude: loc.coordinate.longitude), error: nil)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        owner?.deliverUpdate(nil, error: error)
    }
}
