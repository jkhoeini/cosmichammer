import Foundation
import HSDSTCore

public final class SimulatedLocation: LocationProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var location: LocationCoordinate? = LocationCoordinate()
    public var isUpdating = false
    private var handler: ((LocationCoordinate?, Error?) -> Void)?
    public var authStatus: Int = 3

    // MARK: - Configurable geocode state

    /// Forward geocode results keyed by a coordinate string "lat,lon" (rounded to 4 decimal places).
    /// When geocode is called, the simulator looks up the key; if absent, falls back to
    /// `defaultGeocodeResults`.
    public var geocodeResults: [String: [String]] = [:]

    /// Default result returned by geocode when no entry matches the coordinate.
    /// Set to nil to simulate a geocode failure for unknown coordinates.
    public var defaultGeocodeResults: [String]? = ["1 Infinite Loop, Cupertino, CA 95014"]

    /// Geocode error returned when `defaultGeocodeResults` is nil and no matching entry exists.
    public var geocodeError: Error? = nil

    // MARK: - Reverse geocode (address -> coordinates)

    /// Reverse lookup: address string -> LocationCoordinate.
    /// Used by `reverseGeocode` (if you add it) and can be used by tests to
    /// pre-populate known address->coordinate mappings.
    public var addressToCoordinate: [String: LocationCoordinate] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - LocationProtocol

    public func startUpdating(handler: @escaping (LocationCoordinate?, Error?) -> Void) {
        self.handler = handler
        isUpdating = true
        if faults.locationPermissionDenied {
            handler(nil, SimulatedError.permissionDenied("Location access denied (simulated)"))
            return
        }
        if faults.locationUnavailable {
            handler(nil, SimulatedError.injectedFault("Location unavailable (simulated)"))
            return
        }
        if let loc = location {
            handler(loc, nil)
        }
    }

    public func stopUpdating() {
        isUpdating = false
        handler = nil
    }

    public func currentLocation() -> LocationCoordinate? {
        if faults.locationUnavailable { return nil }
        return location
    }

    public func authorizationStatus() -> Int {
        if faults.locationPermissionDenied { return 2 }
        return authStatus
    }

    public func requestAuthorization() {
        // In a real system this would prompt the user. In the simulator,
        // just set authStatus to authorized (3) unless faults deny it.
        if !faults.locationPermissionDenied {
            authStatus = 3
        }
    }

    public func geocode(latitude: Double, longitude: Double,
                        completion: @escaping ([String]?, Error?) -> Void) {
        if faults.locationPermissionDenied {
            completion(nil, SimulatedError.permissionDenied("Location access denied (simulated)"))
            return
        }

        let key = coordinateKey(latitude: latitude, longitude: longitude)
        if let results = geocodeResults[key] {
            completion(results, nil)
        } else if let defaults = defaultGeocodeResults {
            completion(defaults, nil)
        } else {
            completion(nil, geocodeError ?? SimulatedError.injectedFault("No geocode result for \(key) (simulated)"))
        }
    }

    // MARK: - State mutation (test API)

    /// Push a new location, notifying the active handler if updating.
    public func pushLocation(_ coord: LocationCoordinate) {
        location = coord
        handler?(coord, nil)
    }

    /// Register a geocode result for a specific coordinate pair.
    /// Coordinates are rounded to 4 decimal places for key matching.
    public func registerGeocodeResult(latitude: Double, longitude: Double, addresses: [String]) {
        let key = coordinateKey(latitude: latitude, longitude: longitude)
        geocodeResults[key] = addresses
    }

    /// Push an error to the location handler (simulates a location failure mid-update).
    public func pushError(_ error: Error) {
        handler?(nil, error)
    }

    /// Change authorization status and (if updating) deliver an error for denied states.
    public func setAuthorizationStatus(_ status: Int) {
        authStatus = status
        // If the status becomes denied (2) or restricted (1), and we are
        // currently updating, deliver an error to the handler.
        if isUpdating && (status == 1 || status == 2) {
            handler?(nil, SimulatedError.permissionDenied("Location authorization changed to \(status) (simulated)"))
        }
    }

    // MARK: - Private

    private func coordinateKey(latitude: Double, longitude: Double) -> String {
        let lat = (latitude * 10000).rounded() / 10000
        let lon = (longitude * 10000).rounded() / 10000
        return "\(lat),\(lon)"
    }
}
