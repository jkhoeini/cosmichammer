import Foundation

public struct LocationCoordinate: Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var timestamp: Date

    public init(latitude: Double = 37.7749, longitude: Double = -122.4194,
                altitude: Double = 0, horizontalAccuracy: Double = 10,
                verticalAccuracy: Double = 10, timestamp: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.timestamp = timestamp
    }
}

public protocol LocationProtocol: AnyObject {
    func startUpdating(handler: @escaping (LocationCoordinate?, Error?) -> Void)
    func stopUpdating()
    func currentLocation() -> LocationCoordinate?
    func authorizationStatus() -> Int
    func requestAuthorization()
    func geocode(latitude: Double, longitude: Double,
                 completion: @escaping ([String]?, Error?) -> Void)
}
