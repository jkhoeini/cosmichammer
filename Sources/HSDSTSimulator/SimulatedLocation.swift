import Foundation
import HSDSTCore

public final class SimulatedLocation: LocationProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var location: LocationCoordinate? = LocationCoordinate()
    public var isUpdating = false
    private var handler: ((LocationCoordinate?, Error?) -> Void)?
    public var authStatus: Int = 3

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

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

    public func requestAuthorization() {}

    public func geocode(latitude: Double, longitude: Double,
                        completion: @escaping ([String]?, Error?) -> Void) {
        completion(["1 Infinite Loop, Cupertino, CA 95014"], nil)
    }

    public func pushLocation(_ coord: LocationCoordinate) {
        location = coord
        handler?(coord, nil)
    }
}
