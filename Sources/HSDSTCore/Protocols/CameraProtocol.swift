import Foundation

public struct CameraDeviceInfo: Sendable {
    public var id: String
    public var name: String
    public var manufacturer: String
    public var isInUse: Bool
    public var position: String

    public init(id: String = "FaceTimeCamera-001", name: String = "FaceTime HD Camera",
                manufacturer: String = "Apple Inc.", isInUse: Bool = false,
                position: String = "front") {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isInUse = isInUse
        self.position = position
    }
}

public protocol CameraProtocol: AnyObject {
    func allCameras() -> [CameraDeviceInfo]
    func cameraByName(_ name: String) -> CameraDeviceInfo?
    func isInUse(cameraID: String) -> Bool
    func startCapture(cameraID: String, callback: @escaping (Data) -> Void) -> Bool
    func stopCapture(cameraID: String) -> Bool
    func snapshotImage(cameraID: String) -> Data?
    func addWatcher(callback: @escaping (CameraDeviceInfo, String) -> Void) -> UInt64
    func removeWatcher(id: UInt64) -> Bool
}
