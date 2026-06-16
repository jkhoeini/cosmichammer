import Foundation
import HSDSTCore

public final class SimulatedCamera: CameraProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var cameras: [CameraDeviceInfo] = [CameraDeviceInfo()]
    public var capturingCameras: Set<String> = []
    public var snapshotData: Data?

    private var nextWatcherID: UInt64 = 1
    private var watchers: [UInt64: (CameraDeviceInfo, String) -> Void] = [:]
    private var captureCallbacks: [String: (Data) -> Void] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func allCameras() -> [CameraDeviceInfo] { cameras }

    public func cameraByName(_ name: String) -> CameraDeviceInfo? {
        cameras.first { $0.name == name }
    }

    public func isInUse(cameraID: String) -> Bool {
        guard let camera = cameras.first(where: { $0.id == cameraID }) else { return false }
        return camera.isInUse
    }

    public func startCapture(cameraID: String, callback: @escaping (Data) -> Void) -> Bool {
        guard cameras.contains(where: { $0.id == cameraID }) else { return false }
        guard !capturingCameras.contains(cameraID) else { return false }
        capturingCameras.insert(cameraID)
        captureCallbacks[cameraID] = callback
        if let idx = cameras.firstIndex(where: { $0.id == cameraID }) {
            cameras[idx] = CameraDeviceInfo(
                id: cameras[idx].id, name: cameras[idx].name,
                manufacturer: cameras[idx].manufacturer, isInUse: true,
                position: cameras[idx].position
            )
        }
        return true
    }

    public func stopCapture(cameraID: String) -> Bool {
        guard capturingCameras.contains(cameraID) else { return false }
        capturingCameras.remove(cameraID)
        captureCallbacks.removeValue(forKey: cameraID)
        if let idx = cameras.firstIndex(where: { $0.id == cameraID }) {
            cameras[idx] = CameraDeviceInfo(
                id: cameras[idx].id, name: cameras[idx].name,
                manufacturer: cameras[idx].manufacturer, isInUse: false,
                position: cameras[idx].position
            )
        }
        return true
    }

    public func snapshotImage(cameraID: String) -> Data? {
        guard cameras.contains(where: { $0.id == cameraID }) else { return nil }
        return snapshotData
    }

    public func addWatcher(callback: @escaping (CameraDeviceInfo, String) -> Void) -> UInt64 {
        let id = nextWatcherID
        nextWatcherID += 1
        watchers[id] = callback
        return id
    }

    public func removeWatcher(id: UInt64) -> Bool {
        watchers.removeValue(forKey: id) != nil
    }
}
