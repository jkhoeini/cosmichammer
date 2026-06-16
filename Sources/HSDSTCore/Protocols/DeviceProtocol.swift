import Foundation

public struct USBDeviceInfo: Sendable {
    public var id: UInt64
    public var name: String
    public var vendorID: Int
    public var productID: Int
    public var vendorName: String?
    public var productName: String?

    public init(id: UInt64 = 1, name: String = "USB Device",
                vendorID: Int = 0x05AC, productID: Int = 0x8242,
                vendorName: String? = "Apple Inc.", productName: String? = "IR Receiver") {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.vendorName = vendorName
        self.productName = productName
    }
}

public struct SerialPortInfo: Sendable {
    public var path: String
    public var name: String
    public var baudRate: Int
    public var isOpen: Bool

    public init(path: String = "/dev/cu.usbmodem1411", name: String = "usbmodem1411",
                baudRate: Int = 115200, isOpen: Bool = false) {
        self.path = path
        self.name = name
        self.baudRate = baudRate
        self.isOpen = isOpen
    }
}

public struct MIDIDeviceInfo: Sendable {
    public var id: UInt32
    public var name: String
    public var manufacturer: String
    public var isOnline: Bool

    public init(id: UInt32 = 1, name: String = "MIDI Device",
                manufacturer: String = "Unknown", isOnline: Bool = true) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isOnline = isOnline
    }
}

public protocol DeviceProtocol: AnyObject {
    // USB
    func listUSBDevices() -> [USBDeviceInfo]
    func addUSBWatcher(callback: @escaping (USBDeviceInfo, Bool) -> Void) -> UInt64
    func removeUSBWatcher(id: UInt64) -> Bool

    // Serial
    func listSerialPorts() -> [SerialPortInfo]
    func openSerialPort(path: String, baudRate: Int) -> UInt64?
    func closeSerialPort(portID: UInt64) -> Bool
    func writeSerialPort(portID: UInt64, data: Data) -> Bool
    func readSerialPort(portID: UInt64) -> Data?

    // MIDI
    func listMIDIDevices() -> [MIDIDeviceInfo]
    func sendMIDI(deviceID: UInt32, data: Data) -> Bool
}
