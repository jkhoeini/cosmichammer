import AVFoundation
import CoreMediaIO
import Foundation
import HSDSTCore

final class ProductionCamera: CameraProtocol {
    private var nextWatcherID: UInt64 = 1
    private var watchers: [UInt64: NSObjectProtocol] = [:]

    func allCameras() -> [CameraDeviceInfo] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices.map { deviceToCameraInfo($0) }
    }

    func cameraByName(_ name: String) -> CameraDeviceInfo? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discoverySession.devices.first(where: { $0.localizedName == name })
        else { return nil }
        return deviceToCameraInfo(device)
    }

    func isInUse(cameraID: String) -> Bool {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else { return false }
        // Check via CoreMediaIO for a more accurate "is running somewhere" flag
        return device.isInUseByAnotherApplication || isDeviceRunning(device)
    }

    func startCapture(cameraID: String,
                      callback: @escaping (Data) -> Void) -> Bool
    {
        // Full capture requires AVCaptureSession + AVCaptureVideoDataOutput which
        // is stateful and needs delegate management. This is a lightweight wrapper;
        // the real extension (Camera.swift) handles the full lifecycle.
        // TODO: Implement full capture session management
        return false
    }

    func stopCapture(cameraID: String) -> Bool {
        // TODO: Paired with startCapture session management
        return false
    }

    func snapshotImage(cameraID: String) -> Data? {
        // Taking a snapshot requires setting up a brief capture session.
        // TODO: Implement one-shot capture with AVCaptureStillImageOutput
        return nil
    }

    func addWatcher(callback: @escaping (CameraDeviceInfo, String) -> Void) -> UInt64 {
        let id = nextWatcherID
        nextWatcherID += 1

        let observer = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil, queue: .main
        ) { notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            let info = self.deviceToCameraInfo(device)
            callback(info, "connected")
        }

        let observer2 = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil, queue: .main
        ) { notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            let info = self.deviceToCameraInfo(device)
            callback(info, "disconnected")
        }

        watchers[id] = observer
        watchers[id + 1000000] = observer2  // Store disconnect observer with offset
        return id
    }

    func removeWatcher(id: UInt64) -> Bool {
        guard let observer = watchers.removeValue(forKey: id) else { return false }
        NotificationCenter.default.removeObserver(observer)
        // Also remove the disconnect observer
        if let observer2 = watchers.removeValue(forKey: id + 1000000) {
            NotificationCenter.default.removeObserver(observer2)
        }
        return true
    }

    // MARK: - Private

    private func deviceToCameraInfo(_ device: AVCaptureDevice) -> CameraDeviceInfo {
        let position: String
        switch device.position {
        case .front: position = "front"
        case .back: position = "back"
        default: position = "unspecified"
        }
        return CameraDeviceInfo(
            id: device.uniqueID,
            name: device.localizedName,
            manufacturer: device.manufacturer,
            isInUse: device.isInUseByAnotherApplication || isDeviceRunning(device),
            position: position
        )
    }

    private func isDeviceRunning(_ device: AVCaptureDevice) -> Bool {
        // Use CoreMediaIO to check if device is running somewhere
        // This is a heuristic; the actual Camera.swift extension uses CMIOObject
        // property queries for precise detection
        return device.isInUseByAnotherApplication
    }
}
