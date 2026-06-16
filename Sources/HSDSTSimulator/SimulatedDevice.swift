import Foundation
import HSDSTCore

public final class SimulatedDevice: DeviceProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var usbDevices: [USBDeviceInfo] = [
        USBDeviceInfo(id: 1, name: "Apple IR Receiver", vendorID: 0x05AC, productID: 0x8242,
                      vendorName: "Apple Inc.", productName: "IR Receiver"),
        USBDeviceInfo(id: 2, name: "Internal Keyboard", vendorID: 0x05AC, productID: 0x0273,
                      vendorName: "Apple Inc.", productName: "Apple Internal Keyboard / Trackpad"),
    ]

    public var serialPorts: [SerialPortInfo] = []
    public var midiDevices: [MIDIDeviceInfo] = []

    public var serialWrittenData: [(portID: UInt64, data: Data)] = []
    public var serialReadQueue: [UInt64: [Data]] = [:]

    private var nextWatcherID: UInt64 = 1
    private var usbWatchers: [UInt64: (USBDeviceInfo, Bool) -> Void] = [:]
    private var nextPortID: UInt64 = 1
    private var openPorts: [UInt64: String] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - USB

    public func listUSBDevices() -> [USBDeviceInfo] { usbDevices }

    public func addUSBWatcher(callback: @escaping (USBDeviceInfo, Bool) -> Void) -> UInt64 {
        let id = nextWatcherID
        nextWatcherID += 1
        usbWatchers[id] = callback
        return id
    }

    public func removeUSBWatcher(id: UInt64) -> Bool {
        usbWatchers.removeValue(forKey: id) != nil
    }

    // MARK: - Serial

    public func listSerialPorts() -> [SerialPortInfo] { serialPorts }

    public func openSerialPort(path: String, baudRate: Int) -> UInt64? {
        guard let idx = serialPorts.firstIndex(where: { $0.path == path }) else { return nil }
        guard !serialPorts[idx].isOpen else { return nil }
        let portID = nextPortID
        nextPortID += 1
        openPorts[portID] = path
        serialPorts[idx] = SerialPortInfo(path: serialPorts[idx].path, name: serialPorts[idx].name,
                                          baudRate: baudRate, isOpen: true)
        return portID
    }

    public func closeSerialPort(portID: UInt64) -> Bool {
        guard let path = openPorts.removeValue(forKey: portID) else { return false }
        if let idx = serialPorts.firstIndex(where: { $0.path == path }) {
            serialPorts[idx] = SerialPortInfo(path: serialPorts[idx].path, name: serialPorts[idx].name,
                                              baudRate: serialPorts[idx].baudRate, isOpen: false)
        }
        return true
    }

    public func writeSerialPort(portID: UInt64, data: Data) -> Bool {
        guard openPorts[portID] != nil else { return false }
        serialWrittenData.append((portID: portID, data: data))
        return true
    }

    public func readSerialPort(portID: UInt64) -> Data? {
        guard openPorts[portID] != nil else { return nil }
        guard serialReadQueue[portID] != nil, !serialReadQueue[portID]!.isEmpty else { return nil }
        return serialReadQueue[portID]!.removeFirst()
    }

    // MARK: - MIDI

    public func listMIDIDevices() -> [MIDIDeviceInfo] { midiDevices }

    public func sendMIDI(deviceID: UInt32, data: Data) -> Bool {
        guard midiDevices.contains(where: { $0.id == deviceID && $0.isOnline }) else { return false }
        return true
    }

    // MARK: - Test helpers

    /// Simulate a USB device being connected, notifying all watchers.
    public func simulateUSBConnect(_ device: USBDeviceInfo) {
        usbDevices.append(device)
        for watcher in usbWatchers.values {
            watcher(device, true)
        }
    }

    /// Simulate a USB device being disconnected, notifying all watchers.
    public func simulateUSBDisconnect(id: UInt64) {
        guard let idx = usbDevices.firstIndex(where: { $0.id == id }) else { return }
        let device = usbDevices.remove(at: idx)
        for watcher in usbWatchers.values {
            watcher(device, false)
        }
    }

    /// Enqueue data to be returned by readSerialPort for a given port.
    public func enqueueSerialRead(portID: UInt64, data: Data) {
        serialReadQueue[portID, default: []].append(data)
    }
}
