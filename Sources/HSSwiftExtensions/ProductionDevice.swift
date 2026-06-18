import CoreMIDI
import Foundation
import HSDSTCore
import IOKit
import IOKit.serial
import IOKit.usb

final class ProductionDevice: DeviceProtocol {
    private var nextWatcherID: UInt64 = 1
    private var usbWatchers: [UInt64: (port: IONotificationPortRef, iterator: io_iterator_t)] = [:]
    private var serialPorts: [UInt64: SerialPortState] = [:]
    private var nextSerialID: UInt64 = 1

    private class SerialPortState {
        let fd: Int32
        let path: String
        let baudRate: Int
        var isOpen: Bool = true

        init(fd: Int32, path: String, baudRate: Int) {
            self.fd = fd
            self.path = path
            self.baudRate = baudRate
        }
    }

    // MARK: - USB

    func listUSBDevices() -> [USBDeviceInfo] {
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDeviceInfo] = []
        var device = IOIteratorNext(iterator)
        var idCounter: UInt64 = 1

        while device != 0 {
            defer {
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
            }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                device, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let propsDict = props?.takeRetainedValue() as NSDictionary?
            else { continue }

            let vendorID = (propsDict[kUSBVendorID] as? NSNumber)?.intValue ?? 0
            let productID = (propsDict[kUSBProductID] as? NSNumber)?.intValue ?? 0
            let vendorName = propsDict[kUSBVendorString] as? String
            let productName = propsDict[kUSBProductString] as? String
            let name = productName ?? vendorName ?? "USB Device"

            devices.append(USBDeviceInfo(
                id: idCounter, name: name,
                vendorID: vendorID, productID: productID,
                vendorName: vendorName, productName: productName
            ))
            idCounter += 1
        }
        return devices
    }

    func addUSBWatcher(callback: @escaping (USBDeviceInfo, Bool) -> Void) -> UInt64 {
        assertionFailure("addUSBWatcher not routed through protocol; Usb.swift uses IOKit directly")
        let id = nextWatcherID
        nextWatcherID += 1
        return id
    }

    func removeUSBWatcher(id: UInt64) -> Bool {
        assertionFailure("removeUSBWatcher not routed through protocol; Usb.swift uses IOKit directly")
        guard let entry = usbWatchers.removeValue(forKey: id) else { return false }
        IONotificationPortDestroy(entry.port)
        IOObjectRelease(entry.iterator)
        return true
    }

    // MARK: - Serial

    func listSerialPorts() -> [SerialPortInfo] {
        guard let matchingDict = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPortInfo] = []
        var service = IOIteratorNext(iterator)

        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            if let pathRef = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)
            {
                let path = pathRef.takeRetainedValue() as! String
                let name = (path as NSString).lastPathComponent
                ports.append(SerialPortInfo(
                    path: path, name: name,
                    baudRate: 115200, isOpen: false
                ))
            }
        }
        return ports
    }

    func openSerialPort(path: String, baudRate: Int) -> UInt64? {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }

        // Configure the serial port
        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, speed_t(baudRate))
        cfsetospeed(&options, speed_t(baudRate))
        options.c_cflag |= UInt(CS8)       // 8-bit chars
        options.c_cflag |= UInt(CLOCAL)    // Ignore modem status
        options.c_cflag |= UInt(CREAD)     // Enable receiver
        tcsetattr(fd, TCSANOW, &options)

        let id = nextSerialID
        nextSerialID += 1
        serialPorts[id] = SerialPortState(fd: fd, path: path, baudRate: baudRate)
        return id
    }

    func closeSerialPort(portID: UInt64) -> Bool {
        guard let state = serialPorts.removeValue(forKey: portID) else { return false }
        Darwin.close(state.fd)
        return true
    }

    func writeSerialPort(portID: UInt64, data: Data) -> Bool {
        guard let state = serialPorts[portID], state.isOpen else { return false }
        let written = data.withUnsafeBytes { ptr in
            Darwin.write(state.fd, ptr.baseAddress!, data.count)
        }
        return written == data.count
    }

    func readSerialPort(portID: UInt64) -> Data? {
        guard let state = serialPorts[portID], state.isOpen else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(state.fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }
        return Data(buffer[0..<bytesRead])
    }

    // MARK: - MIDI

    func listMIDIDevices() -> [MIDIDeviceInfo] {
        var devices: [MIDIDeviceInfo] = []
        let count = MIDIGetNumberOfDevices()

        for i in 0..<count {
            let device = MIDIGetDevice(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(device, kMIDIPropertyName, &name)
            let deviceName = name?.takeRetainedValue() as String? ?? "MIDI Device"

            var manufacturer: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(device, kMIDIPropertyManufacturer, &manufacturer)
            let mfr = manufacturer?.takeRetainedValue() as String? ?? "Unknown"

            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(device, kMIDIPropertyOffline, &offline)

            devices.append(MIDIDeviceInfo(
                id: UInt32(i), name: deviceName,
                manufacturer: mfr, isOnline: offline == 0
            ))
        }
        return devices
    }

    func sendMIDI(deviceID: UInt32, data: Data) -> Bool {
        assertionFailure("sendMIDI not routed through protocol; Midi.swift uses CoreMIDI directly")
        return false
    }
}
