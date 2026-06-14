import Cocoa
import CLua
import Lua
import IOKit
import IOKit.hid
import IOKit.usb
import os.log

// MARK: - Constants (mirroring razer.h)

private let USERDATA_TAG = "hs.razer"

private let USB_VID_RAZER: Int32                = 0x1532
private let USB_PID_RAZER_TARTARUS_V2: Int32    = 0x022B

// IOKit USB COM-style UUIDs not bridged to Swift (defined as C macros in IOUSBLib.h / IOCFPlugIn.h).
// We recreate them using CFUUIDGetConstantUUIDWithBytes.
private let kIOUSBDeviceUserClientTypeID_: CFUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
    0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

private let kIOCFPlugInInterfaceID_: CFUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

// kIOUSBDeviceInterfaceID is an alias for kIOUSBDeviceInterfaceID100
private let kIOUSBDeviceInterfaceID_: CFUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4,
    0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

// MARK: - Global variables

var razerRefTable: Int32 = LUA_NOREF

private var razerManager: HSRazerManager?

// MARK: - Time helper

private func getSecondsSinceEpoch() -> Double {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
}

// MARK: - HSRazerReportBuilder

/// Builds a 90-byte Razer report buffer.
/// This replaces the C struct HSRazerReport which uses bitfields and unions
/// that don't translate cleanly to Swift.
private struct HSRazerReportBuilder {
    static func build(transactionID: UInt8,
                      commandClass: UInt8,
                      commandID: UInt8,
                      arguments: [Int: NSNumber]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 90)

        let dataSize = UInt8(arguments.count)

        report[0] = 0x00                // status: New Command
        report[1] = transactionID       // transaction_id
        report[2] = 0x00                // remaining_packets (high byte)
        report[3] = 0x00                // remaining_packets (low byte)
        report[4] = 0x00                // protocol_type
        report[5] = dataSize            // data_size
        report[6] = commandClass        // command_class
        report[7] = commandID           // command_id

        // Arguments go into bytes 8..87
        for (key, value) in arguments {
            if key >= 0 && key < 80 {
                report[8 + key] = UInt8(truncatingIfNeeded: value.intValue)
            }
        }

        // CRC: XOR bytes 2..87
        var crc: UInt8 = 0
        for i in 2..<88 {
            crc ^= report[i]
        }
        report[88] = crc                // crc
        report[89] = 0x00               // reserved

        return report
    }
}

// MARK: - HSRazerResult

class HSRazerResult: NSObject {
    var success: Bool = false
    var errorMessage: NSString?

    var brightness: NSNumber?

    var orangeStatusLight: Bool = false
    var greenStatusLight: Bool = false
    var blueStatusLight: Bool = false

    var argumentTwo: UInt8 = 0
}

// MARK: - HSRazerDevice

class HSRazerDevice: NSObject, LuaTeardownable {
    var device: IOHIDDevice?
    weak var manager: HSRazerManager?
    var buttonCallbackRef: Int32 = LUA_NOREF
    var isValid: Bool = true

    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        destroyEventTap()
        // buttonCallbackRef is cleaned up by the Lua GC caller
    }

    var locationID: NSNumber?

    var eventTap: CFMachPort?

    var name: String = "Unknown"
    var productID: Int32 = 0

    // Remapping Details:
    var buttonNames: NSDictionary?
    var remapping: NSDictionary?

    // Backlight Details:
    var backlightRows: Int32 = 0
    var backlightColumns: Int32 = 0

    // Scroll Wheel:
    var scrollWheelID: Int32 = 0
    var scrollWheelPressed: Bool = false

    var lastScrollWheelEvent: Double = 0

    var lsCanary: UInt64 = UInt64()

    init(device: IOHIDDevice, manager: HSRazerManager) {
        super.init()
        self.device = device
        self.isValid = true
        self.manager = manager
        self.buttonCallbackRef = LUA_NOREF
        self.name = "Unknown"
        self.scrollWheelPressed = false
        self.lastScrollWheelEvent = getSecondsSinceEpoch()
    }

    func invalidate() {
        isValid = false
        destroyEventTap()
    }

    // MARK: - Button Callbacks

    func deviceButtonPress(_ scancodeString: String, pressed: Int) {
        guard isValid else { return }

        guard let buttonName = buttonNames?.value(forKey: scancodeString) as? String else {
            return
        }

        var buttonAction = ""
        let scrollWheelIDStr = "\(scrollWheelID)"

        if scancodeString == scrollWheelIDStr {
            if pressed == 1 {
                buttonAction = "up"
                lastScrollWheelEvent = getSecondsSinceEpoch()
            } else if pressed == -1 {
                buttonAction = "down"
                lastScrollWheelEvent = getSecondsSinceEpoch()
            } else if pressed == 0 {
                if scrollWheelPressed {
                    buttonAction = "released"
                    scrollWheelPressed = false
                } else {
                    buttonAction = "pressed"
                    scrollWheelPressed = true
                }
            }
        } else {
            buttonAction = pressed == 1 ? "pressed" : "released"
        }

        guard buttonCallbackRef != LUA_NOREF else { return }

        guard lua_isStateGenerationValid(lsCanary) else { return }

        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(buttonCallbackRef))
        _ = pushHSRazerDevice(L, self)
        lua_pushany(L, buttonName as NSString)
        lua_pushany(L, buttonAction as NSString)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    // MARK: - Event Tap for Scroll Wheel

    func setupEventTap() {
        guard scrollWheelID != 0 else {
            os_log(.info, "[hs.razer] The device does not have a scroll wheel ID, so aborting event tap setup.")
            return
        }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: razerEventTapCallback,
            userInfo: selfPtr
        ) else {
            os_log(.error, "[hs.razer] Failed to create the event tap.")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func destroyEventTap() {
        if let tap = eventTap {
            if CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - Backlight Placeholders (overridden by subclasses)

    func setBacklightToStaticColor(_ color: NSColor) -> HSRazerResult {
        fatalError("setBacklightToStaticColor not implemented")
    }

    func setBacklightToOff() -> HSRazerResult {
        fatalError("setBacklightToOff not implemented")
    }

    func setBacklightToWave(speed: NSNumber, direction: String) -> HSRazerResult {
        fatalError("setBacklightToWaveWithSpeed not implemented")
    }

    func setBacklightToSpectrum() -> HSRazerResult {
        fatalError("setBacklightToSpectrum not implemented")
    }

    func setBacklightToReactive(color: NSColor, speed: NSNumber) -> HSRazerResult {
        fatalError("setBacklightToReactiveWithColor not implemented")
    }

    func setBacklightToStarlight(color: NSColor?, secondaryColor: NSColor?, speed: NSNumber) -> HSRazerResult {
        fatalError("setBacklightToStarlightWithColor not implemented")
    }

    func setBacklightToBreathing(color: NSColor?, secondaryColor: NSColor?) -> HSRazerResult {
        fatalError("setBacklightToBreathingWithColor not implemented")
    }

    func setBacklightToCustom(colors: NSMutableDictionary) -> HSRazerResult {
        fatalError("setBacklightToCustomWithColors not implemented")
    }

    // MARK: - Brightness Placeholders

    func getBrightness() -> HSRazerResult {
        fatalError("getBrightness not implemented")
    }

    func setBrightness(_ brightness: NSNumber) -> HSRazerResult {
        fatalError("setBrightness not implemented")
    }

    // MARK: - Status Light Placeholders

    func getOrangeStatusLight() -> HSRazerResult {
        fatalError("getOrangeStatusLight not implemented")
    }

    func setOrangeStatusLight(_ active: Bool) -> HSRazerResult {
        fatalError("setOrangeStatusLight not implemented")
    }

    func getGreenStatusLight() -> HSRazerResult {
        fatalError("getGreenStatusLight not implemented")
    }

    func setGreenStatusLight(_ active: Bool) -> HSRazerResult {
        fatalError("setGreenStatusLight not implemented")
    }

    func getBlueStatusLight() -> HSRazerResult {
        fatalError("getBlueStatusLight not implemented")
    }

    func setBlueStatusLight(_ active: Bool) -> HSRazerResult {
        fatalError("setBlueStatusLight not implemented")
    }

    // MARK: - USB Device Communication

    func sendRazerReport(transactionID: Int32, commandClass: Int32, commandID: Int32, arguments: NSDictionary) -> HSRazerResult {
        let result = HSRazerResult()

        let wValue: UInt16 = 0x300
        let wIndex: UInt16 = 0x01
        let wLength: UInt16 = 90

        // Convert NSDictionary to [Int: NSNumber]
        var args: [Int: NSNumber] = [:]
        for (key, value) in arguments {
            if let k = key as? NSNumber, let v = value as? NSNumber {
                args[k.intValue] = v
            }
        }

        // Build the report
        var reportBytes = HSRazerReportBuilder.build(
            transactionID: UInt8(truncatingIfNeeded: transactionID),
            commandClass: UInt8(truncatingIfNeeded: commandClass),
            commandID: UInt8(truncatingIfNeeded: commandID),
            arguments: args
        )

        // Find the matching USB device via IOKit
        guard let dev = getUSBRazerDevice() else {
            result.errorMessage = "Failed to create a Razer device for the initial report." as NSString
            return result
        }

        // Send the report (OUT direction)
        let sendResult: IOReturn = reportBytes.withUnsafeMutableBytes { rawBuf in
            var request = IOUSBDevRequest()
            request.bmRequestType = UInt8(kUSBOut | kUSBClass | kUSBInterface)
            request.bRequest = UInt8(kUSBRqSetConfig)
            request.wValue = wValue
            request.wIndex = wIndex
            request.wLength = wLength
            request.pData = rawBuf.baseAddress
            return dev.pointee.pointee.DeviceRequest(dev, &request)
        }

        if sendResult != kIOReturnSuccess {
            _ = dev.pointee.pointee.USBDeviceClose(dev)
            _ = dev.pointee.pointee.Release(dev)
            result.errorMessage = "Failed to send Device Request: \(sendResult)" as NSString
            return result
        }

        // Wait for response
        usleep(500)

        // Read response (IN direction)
        var responseBytes = [UInt8](repeating: 0, count: 90)
        let responseResult: IOReturn = responseBytes.withUnsafeMutableBytes { rawBuf in
            var responseRequest = IOUSBDevRequest()
            responseRequest.bmRequestType = UInt8(kUSBIn | kUSBClass | kUSBInterface)
            responseRequest.bRequest = UInt8(kUSBRqClearFeature)
            responseRequest.wValue = wValue
            responseRequest.wIndex = wIndex
            responseRequest.wLength = wLength
            responseRequest.pData = rawBuf.baseAddress
            return dev.pointee.pointee.DeviceRequest(dev, &responseRequest)
        }

        // Close & Release the USB Device:
        _ = dev.pointee.pointee.USBDeviceClose(dev)
        _ = dev.pointee.pointee.Release(dev)

        if responseResult != kIOReturnSuccess {
            result.errorMessage = "Failed to get a response back from the Razer Device: \(String(cString: mach_error_string(responseResult)))" as NSString
        } else {
            // Validate response fields match sent report
            let respRemainingPackets = (UInt16(responseBytes[2]) << 8) | UInt16(responseBytes[3])
            let sentRemainingPackets = (UInt16(reportBytes[2]) << 8) | UInt16(reportBytes[3])
            let respCommandClass = responseBytes[6]
            let sentCommandClass = reportBytes[6]
            let respCommandID = responseBytes[7]
            let sentCommandID = reportBytes[7]
            let respStatus = responseBytes[0]

            if respRemainingPackets != sentRemainingPackets {
                result.errorMessage = "The sent report remaining packets don't match the response remaining packets." as NSString
            } else if respCommandClass != sentCommandClass {
                result.errorMessage = "The sent report command class doesn't match the response command class." as NSString
            } else if respCommandID != sentCommandID {
                result.errorMessage = "The sent report command ID doesn't match the response command ID." as NSString
            } else if respStatus == 0x01 {
                // "Busy" -- but still successful per the ObjC implementation
                result.success = true
            } else if respStatus == 0x02 {
                result.success = true
            } else if respStatus == 0x03 {
                result.errorMessage = "The command sent to the Razer device failed." as NSString
            } else if respStatus == 0x04 {
                result.errorMessage = "The command sent to the Razer device timed out." as NSString
            } else if respStatus == 0x05 {
                result.errorMessage = "The command sent to the Razer device is not supported." as NSString
            } else {
                result.errorMessage = "Unexpected status back from the Razer device: \(respStatus)" as NSString
            }
        }

        // Argument two from response (byte index 8+2 = 10)
        result.argumentTwo = responseBytes[10]

        return result
    }

    /// Find the USB device matching this Razer device's locationID and productID.
    private func getUSBRazerDevice() -> UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>? {
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            return nil
        }

        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter)
        guard kr == KERN_SUCCESS else { return nil }

        defer { IOObjectRelease(iter) }

        var usbDevice = IOIteratorNext(iter)
        while usbDevice != 0 {
            var plugInInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0

            let plugInResult = IOCreatePlugInInterfaceForService(
                usbDevice,
                kIOUSBDeviceUserClientTypeID_,
                kIOCFPlugInInterfaceID_,
                &plugInInterface,
                &score
            )

            IOObjectRelease(usbDevice)

            guard plugInResult == kIOReturnSuccess,
                  let plugin = plugInInterface,
                  let pluginPtr = plugin.pointee else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Query for IOUSBDeviceInterface
            var devInterface: UnsafeMutableRawPointer?
            let uuidBytes = CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID_)
            let hResult = withUnsafeBytes(of: uuidBytes) { uuidBuf in
                pluginPtr.pointee.QueryInterface(
                    pluginPtr,
                    uuidBuf.load(as: REFIID.self),
                    &devInterface
                )
            }

            // Release plugin
            _ = pluginPtr.pointee.Release(pluginPtr)

            guard hResult == S_OK, let rawDev = devInterface else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            let dev = rawDev.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>.self)

            // Check location ID
            var deviceLocationID: UInt32 = 0
            guard dev.pointee.pointee.GetLocationID(dev, &deviceLocationID) == kIOReturnSuccess,
                  deviceLocationID == locationID?.uint32Value else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Check vendor
            var vendor: UInt16 = 0
            guard dev.pointee.pointee.GetDeviceVendor(dev, &vendor) == kIOReturnSuccess,
                  vendor == UInt16(USB_VID_RAZER) else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Check product
            var product: UInt16 = 0
            guard dev.pointee.pointee.GetDeviceProduct(dev, &product) == kIOReturnSuccess,
                  product == UInt16(productID) else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Open the device
            let openResult = dev.pointee.pointee.USBDeviceOpen(dev)
            guard openResult == kIOReturnSuccess else {
                _ = dev.pointee.pointee.Release(dev)
                usbDevice = IOIteratorNext(iter)
                continue
            }

            return dev
        }

        return nil
    }
}

// MARK: - Event Tap C Callback

private func razerEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    if type == .tapDisabledByUserInput {
        return Unmanaged.passUnretained(event)
    }

    let device = Unmanaged<HSRazerDevice>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout {
        if let tap = device.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard lua_isStateGenerationValid(device.lsCanary) else {
        return Unmanaged.passUnretained(event)
    }

    let currentTime = getSecondsSinceEpoch() - 0.1
    if currentTime < device.lastScrollWheelEvent {
        return nil
    } else {
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - HSRazerTartarusV2Device

class HSRazerTartarusV2Device: HSRazerDevice {

    override init(device: IOHIDDevice, manager: HSRazerManager) {
        super.init(device: device, manager: manager)

        self.name = "Razer Tartarus V2"
        self.productID = USB_PID_RAZER_TARTARUS_V2

        self.backlightRows = 4
        self.backlightColumns = 6

        self.scrollWheelID = 56

        self.buttonNames = [
            "30" : "1",   "31" : "2",  "32" : "3",  "33" : "4",   "34" : "5",
            "43" : "6",   "20" : "7",  "26" : "8",  "8"  : "9",   "21" : "10",
            "57" : "11",  "4"  : "12", "22" : "13", "7"  : "14",  "9"  : "15",
            "225": "16",  "29" : "17", "27" : "18", "6"  : "19",  "44" : "20",
            "56" : "Scroll Wheel", "226": "Mode",
            "82" : "Up",  "81" : "Down", "80" : "Left", "79" : "Right",
        ]

        self.remapping = [
            "0x100000001" : "0x70000001E", "0x100000002" : "0x70000001F",
            "0x100000003" : "0x700000020", "0x100000004" : "0x700000021",
            "0x100000005" : "0x700000022", "0x100000006" : "0x70000002B",
            "0x100000007" : "0x700000014", "0x100000008" : "0x70000001A",
            "0x100000009" : "0x700000008", "0x100000010" : "0x700000015",
            "0x100000011" : "0x700000039", "0x100000012" : "0x700000004",
            "0x100000013" : "0x700000016", "0x100000014" : "0x700000007",
            "0x100000015" : "0x700000009", "0x100000016" : "0x7000000E1",
            "0x100000017" : "0x70000001D", "0x100000018" : "0x70000001B",
            "0x100000019" : "0x700000006", "0x100000020" : "0x70000002C",
            "0x100000021" : "0x700000035", "0x100000022" : "0x700000052",
            "0x100000023" : "0x700000051", "0x100000024" : "0x700000050",
            "0x100000025" : "0x70000004F",
        ]
    }

    // MARK: - Color helpers

    private func colorComponents(_ color: NSColor) -> (r: NSNumber, g: NSNumber, b: NSNumber) {
        let r = NSNumber(value: Int(floor(color.redComponent) * 255))
        let g = NSNumber(value: Int(floor(color.greenComponent) * 255))
        let b = NSNumber(value: Int(floor(color.blueComponent) * 255))
        return (r, g, b)
    }

    // MARK: - LED Backlights

    override func setBacklightToOff() -> HSRazerResult {
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
            NSNumber(value: 2): NSNumber(value: 0x00), NSNumber(value: 3): NSNumber(value: 0x00),
            NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x00),
            NSNumber(value: 6): NSNumber(value: 0x00),
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToStaticColor(_ color: NSColor) -> HSRazerResult {
        let (red, green, blue) = colorComponents(color)
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
            NSNumber(value: 2): NSNumber(value: 0x01), NSNumber(value: 3): NSNumber(value: 0x00),
            NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x01),
            NSNumber(value: 6): red, NSNumber(value: 7): green, NSNumber(value: 8): blue,
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToWave(speed: NSNumber, direction: String) -> HSRazerResult {
        let directionValue: NSNumber = (direction == "right") ? NSNumber(value: 2) : NSNumber(value: 1)
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
            NSNumber(value: 2): NSNumber(value: 0x04), NSNumber(value: 3): directionValue,
            NSNumber(value: 4): speed, NSNumber(value: 5): NSNumber(value: 0x00),
            NSNumber(value: 6): NSNumber(value: 0x00),
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToSpectrum() -> HSRazerResult {
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
            NSNumber(value: 2): NSNumber(value: 0x03), NSNumber(value: 3): NSNumber(value: 0x00),
            NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x01),
            NSNumber(value: 6): NSNumber(value: 0x00),
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToReactive(color: NSColor, speed: NSNumber) -> HSRazerResult {
        let (red, green, blue) = colorComponents(color)
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
            NSNumber(value: 2): NSNumber(value: 0x05), NSNumber(value: 3): NSNumber(value: 0x00),
            NSNumber(value: 4): speed, NSNumber(value: 5): NSNumber(value: 0x01),
            NSNumber(value: 6): red, NSNumber(value: 7): green, NSNumber(value: 8): blue,
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToStarlight(color: NSColor?, secondaryColor: NSColor?, speed: NSNumber) -> HSRazerResult {
        if let color = color, let secondaryColor = secondaryColor {
            let (red, green, blue) = colorComponents(color)
            let (redS, greenS, blueS) = colorComponents(secondaryColor)
            let arguments: NSDictionary = [
                NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
                NSNumber(value: 2): NSNumber(value: 0x07), NSNumber(value: 3): NSNumber(value: 0x00),
                NSNumber(value: 4): speed, NSNumber(value: 5): NSNumber(value: 0x02),
                NSNumber(value: 6): red, NSNumber(value: 7): green, NSNumber(value: 8): blue,
                NSNumber(value: 9): redS, NSNumber(value: 10): greenS, NSNumber(value: 11): blueS,
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else if let color = color {
            let (red, green, blue) = colorComponents(color)
            let arguments: NSDictionary = [
                NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
                NSNumber(value: 2): NSNumber(value: 0x07), NSNumber(value: 3): NSNumber(value: 0x00),
                NSNumber(value: 4): speed, NSNumber(value: 5): NSNumber(value: 0x01),
                NSNumber(value: 6): red, NSNumber(value: 7): green, NSNumber(value: 8): blue,
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else {
            let arguments: NSDictionary = [
                NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
                NSNumber(value: 2): NSNumber(value: 0x07), NSNumber(value: 3): NSNumber(value: 0x00),
                NSNumber(value: 4): speed, NSNumber(value: 5): NSNumber(value: 0x00),
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        }
    }

    override func setBacklightToBreathing(color: NSColor?, secondaryColor: NSColor?) -> HSRazerResult {
        if let color = color, let secondaryColor = secondaryColor {
            let (red, green, blue) = colorComponents(color)
            let (redS, greenS, blueS) = colorComponents(secondaryColor)
            let arguments: NSDictionary = [
                NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
                NSNumber(value: 2): NSNumber(value: 0x02), NSNumber(value: 3): NSNumber(value: 0x02),
                NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x02),
                NSNumber(value: 6): red, NSNumber(value: 7): green, NSNumber(value: 8): blue,
                NSNumber(value: 9): redS, NSNumber(value: 10): greenS, NSNumber(value: 11): blueS,
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else if let color = color {
            let (red, green, blue) = colorComponents(color)
            let arguments: NSDictionary = [
                NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
                NSNumber(value: 2): NSNumber(value: 0x02), NSNumber(value: 3): NSNumber(value: 0x01),
                NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x01),
                NSNumber(value: 6): red, NSNumber(value: 7): green, NSNumber(value: 8): blue,
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else {
            let arguments: NSDictionary = [
                NSNumber(value: 0): NSNumber(value: 0x01), NSNumber(value: 1): NSNumber(value: 0x05),
                NSNumber(value: 2): NSNumber(value: 0x02), NSNumber(value: 3): NSNumber(value: 0x00),
                NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x00),
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        }
    }

    override func setBacklightToCustom(colors: NSMutableDictionary) -> HSRazerResult {
        var customColorsCount = 1

        for row in 0..<Int(backlightRows) {
            let arguments = NSMutableDictionary()
            arguments[NSNumber(value: 0)] = NSNumber(value: 0x00)
            arguments[NSNumber(value: 1)] = NSNumber(value: 0x00)
            arguments[NSNumber(value: 2)] = NSNumber(value: row)
            arguments[NSNumber(value: 3)] = NSNumber(value: 0)
            arguments[NSNumber(value: 4)] = NSNumber(value: Int(backlightColumns) - 1)

            var count = 5
            for _ in 0..<Int(backlightColumns) {
                let currentColor = colors[NSNumber(value: customColorsCount)] as? NSColor
                customColorsCount += 1

                if let c = currentColor {
                    let (red, green, blue) = colorComponents(c)
                    arguments[NSNumber(value: count)] = red;     count += 1
                    arguments[NSNumber(value: count)] = green;   count += 1
                    arguments[NSNumber(value: count)] = blue;    count += 1
                } else {
                    arguments[NSNumber(value: count)] = NSNumber(value: 0); count += 1
                    arguments[NSNumber(value: count)] = NSNumber(value: 0); count += 1
                    arguments[NSNumber(value: count)] = NSNumber(value: 0); count += 1
                }
            }

            let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x03, arguments: arguments)
            if !result.success { return result }
        }

        let modeArguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x00),
            NSNumber(value: 2): NSNumber(value: 0x08), NSNumber(value: 3): NSNumber(value: 0x00),
            NSNumber(value: 4): NSNumber(value: 0x00), NSNumber(value: 5): NSNumber(value: 0x00),
            NSNumber(value: 6): NSNumber(value: 0x00), NSNumber(value: 7): NSNumber(value: 0x00),
            NSNumber(value: 8): NSNumber(value: 0x00), NSNumber(value: 9): NSNumber(value: 0x00),
            NSNumber(value: 10): NSNumber(value: 0x00), NSNumber(value: 11): NSNumber(value: 0x00),
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: modeArguments)
    }

    // MARK: - LED Brightness

    override func getBrightness() -> HSRazerResult {
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x00),
            NSNumber(value: 2): NSNumber(value: 0x00),
        ]
        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x84, arguments: arguments)
        if result.success { result.brightness = NSNumber(value: round(Double(result.argumentTwo) / 2.55)) }
        return result
    }

    override func setBrightness(_ brightness: NSNumber) -> HSRazerResult {
        let adjustedBrightness = NSNumber(value: round(Double(brightness.intValue) * 2.55))
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x00),
            NSNumber(value: 2): adjustedBrightness,
        ]
        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x04, arguments: arguments)
        if result.success { result.brightness = NSNumber(value: round(Double(result.argumentTwo) / 2.55)) }
        return result
    }

    // MARK: - Status Lights

    override func setOrangeStatusLight(_ active: Bool) -> HSRazerResult {
        let onOrOff: NSNumber = active ? NSNumber(value: 0x01) : NSNumber(value: 0x00)
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x0C), NSNumber(value: 2): onOrOff,
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x00, arguments: arguments)
    }

    override func getOrangeStatusLight() -> HSRazerResult {
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x0C), NSNumber(value: 2): NSNumber(value: 0x00),
        ]
        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x80, arguments: arguments)
        if result.success { result.orangeStatusLight = (result.argumentTwo == 1) }
        return result
    }

    override func setGreenStatusLight(_ active: Bool) -> HSRazerResult {
        let onOrOff: NSNumber = active ? NSNumber(value: 0x01) : NSNumber(value: 0x00)
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x0D), NSNumber(value: 2): onOrOff,
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x00, arguments: arguments)
    }

    override func getGreenStatusLight() -> HSRazerResult {
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x0D), NSNumber(value: 2): NSNumber(value: 0x00),
        ]
        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x80, arguments: arguments)
        if result.success { result.greenStatusLight = (result.argumentTwo == 1) }
        return result
    }

    override func setBlueStatusLight(_ active: Bool) -> HSRazerResult {
        let onOrOff: NSNumber = active ? NSNumber(value: 0x01) : NSNumber(value: 0x00)
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x0E), NSNumber(value: 2): onOrOff,
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x00, arguments: arguments)
    }

    override func getBlueStatusLight() -> HSRazerResult {
        let arguments: NSDictionary = [
            NSNumber(value: 0): NSNumber(value: 0x00), NSNumber(value: 1): NSNumber(value: 0x0E), NSNumber(value: 2): NSNumber(value: 0x00),
        ]
        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x80, arguments: arguments)
        if result.success { result.blueStatusLight = (result.argumentTwo == 1) }
        return result
    }
}

// MARK: - HID Callbacks (C function pointers)

private func hidCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let sender = sender, let context = context else { return }

    let hidDevice = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()

    guard let locationID = IOHIDDeviceGetProperty(hidDevice, kIOHIDLocationIDKey as CFString) as? NSNumber else {
        return
    }

    let manager = Unmanaged<HSRazerManager>.fromOpaque(context).takeUnretainedValue()

    for device in manager.devices {
        guard let razerDevice = device as? HSRazerDevice else { continue }
        if razerDevice.locationID == locationID {
            let elem = IOHIDValueGetElement(value)
            let scancode = IOHIDElementGetUsage(elem)
            let pressed = IOHIDValueGetIntegerValue(value)

            if scancode < 4 || scancode > 231 { return }

            let scancodeString = "\(scancode)"
            razerDevice.deviceButtonPress(scancodeString, pressed: pressed)
        }
    }
}

private func hidConnect(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context = context else { return }
    let manager = Unmanaged<HSRazerManager>.fromOpaque(context).takeUnretainedValue()
    _ = manager.deviceDidConnect(device)
}

private func hidDisconnect(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context = context else { return }
    let manager = Unmanaged<HSRazerManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceDidDisconnect(device)
    IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
}

// MARK: - HSRazerManager

class HSRazerManager: NSObject {
    var ioHIDManager: IOHIDManager?
    var devices: NSMutableArray = NSMutableArray()
    var discoveryCallbackRef: Int32 = LUA_NOREF

    override init() {
        super.init()

        devices = NSMutableArray(capacity: 1)
        discoveryCallbackRef = LUA_NOREF

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        ioHIDManager = hidManager

        let matchTartarusV2: [String: Any] = [
            kIOHIDVendorIDKey: USB_VID_RAZER,
            kIOHIDProductIDKey: USB_PID_RAZER_TARTARUS_V2,
        ]

        IOHIDManagerSetDeviceMatchingMultiple(hidManager, [matchTartarusV2] as CFArray)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, hidConnect, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, hidDisconnect, selfPtr)
        IOHIDManagerRegisterInputValueCallback(hidManager, hidCallback, selfPtr)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func doGC() {
        guard let hidManager = ioHIDManager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        ioHIDManager = nil
    }

    @discardableResult
    func startHIDManager() -> Bool {
        guard let hidManager = ioHIDManager else { return false }
        return IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    @discardableResult
    func stopHIDManager() -> Bool {
        guard let hidManager = ioHIDManager else { return true }
        return IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    func deviceDidConnect(_ device: IOHIDDevice) -> HSRazerDevice? {
        guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
              let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else {
            return nil
        }

        guard vendorID.int32Value == USB_VID_RAZER else { return nil }

        var razerDevice: HSRazerDevice? = nil

        switch productID.int32Value {
        case USB_PID_RAZER_TARTARUS_V2:
            let alreadyRegistered = devices.contains { item in
                if let d = item as? HSRazerDevice, d.locationID == locationID { return true }
                return false
            }

            if !alreadyRegistered {
                razerDevice = HSRazerTartarusV2Device(device: device, manager: self)
                razerDevice!.locationID = locationID
                razerDevice!.setupEventTap()
            }
        default:
            break
        }

        guard let razerDevice = razerDevice else { return nil }

        devices.add(razerDevice)

        razerDevice.lsCanary = lua_currentStateGeneration()

        if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
            os_log(.info, "%{public}s", "hs.razer detected a device connecting, but no discovery callback has been set. See hs.razer.discoveryCallback()")
        } else {
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(discoveryCallbackRef))
            L.push(true)
            _ = pushHSRazerDevice(L, razerDevice)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }

        return razerDevice
    }

    func deviceDidDisconnect(_ device: IOHIDDevice) {
        for (index, item) in devices.enumerated() {
            guard let razerDevice = item as? HSRazerDevice else { continue }
            guard razerDevice.device == device else { continue }

            razerDevice.invalidate()
            if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
                os_log(.info, "%{public}s", "hs.razer detected a device disconnecting, but no callback has been set. See hs.razer.discoveryCallback()")
            } else {
                let L = lua_getCurrentState()!
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(discoveryCallbackRef))
                L.push(false)
                _ = pushHSRazerDevice(L, razerDevice)
                if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
            }

            devices.removeObject(at: index)
            return
        }
    }
}

// MARK: - Lua API: Module-level functions

/// hs.razer.init(fn)
/// Function
/// Initialises the Razer driver and sets a discovery callback.
///
/// Parameters:
///  * fn - A function that will be called when a Razer device is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.razer object, being the device that was connected/disconnected
///
/// Returns:
///  * None
///
/// Notes:
///  * This function must be called before any other parts of this module are used
private let razer_init: lua_CFunction = { L in
    luaL_checktype(L, 1, LUA_TFUNCTION)

    razerManager = HSRazerManager()
    lua_replaceRegistryFunctionRef(L, &razerManager!.discoveryCallbackRef, at: 1)
    razerManager!.startHIDManager()

    return 0
}

/// hs.razer.discoveryCallback(fn) -> none
/// Function
/// Sets/clears a callback for reacting to device discovery events
///
/// Parameters:
///  * fn - A function that will be called when a Razer device is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.razer object, being the device that was connected/disconnected
///
/// Returns:
///  * None
private let razer_discoveryCallback: lua_CFunction = { L in
    if razerManager == nil {
        razerManager = HSRazerManager()
    }
    lua_unrefRegistryRef(L, &razerManager!.discoveryCallbackRef)

    if lua_type(L, 1) == LUA_TFUNCTION {
        lua_replaceRegistryFunctionRef(L, &razerManager!.discoveryCallbackRef, at: 1)
    }

    return 0
}

/// hs.razer.numDevices() -> number
/// Function
/// Gets the number of Razer devices connected
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of Razer devices attached to the system
private let razer_numDevices: lua_CFunction = { L in
    L!.push(lua_Integer(razerManager?.devices.count ?? 0))
    return 1
}

/// hs.razer.getDevice(num) -> razerObject | nil
/// Function
/// Gets an hs.razer object for the specified device
///
/// Parameters:
///  * num - A number that should be within the bounds of the number of connected devices
///
/// Returns:
///  * An hs.razer object or `nil` if something goes wrong
private let razer_getDevice: lua_CFunction = { L in
    luaL_checktype(L, 1, LUA_TNUMBER)

    let deviceNumber = Int(lua_tointeger(L, 1)) - 1

    guard let manager = razerManager, deviceNumber >= 0, deviceNumber < manager.devices.count else {
        lua_pushnil(L)
        return 1
    }

    if let razer = manager.devices[deviceNumber] as? HSRazerDevice {
        _ = pushHSRazerDevice(L, razer)
    } else {
        lua_pushnil(L)
    }

    return 1
}


// MARK: - Lua<->NSObject Conversion Functions

@discardableResult
private func pushHSRazerDevice(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let device = obj as? HSRazerDevice else { return 0 }
    L.push(userdata: device)
    return 1
}

// MARK: - Lua Initialiser

@_cdecl("luaopen_hs_librazer")
public func luaopen_hs_librazer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    razerRefTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register idiomatic Metatable<HSRazerDevice> with LuaSwift.
    L.register(Metatable<HSRazerDevice>(
        fields: [
            "name": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                lua_pushany(L, razer.name as NSString)
                return 1
            },
            "callback": .closure { L in
                let device: HSRazerDevice = try L.checkArgument(1)
                lua_replaceRegistryFunctionRef(L, &device.buttonCallbackRef, at: 2)
                lua_pushvalue(L, 1)
                return 1
            },
            "brightness": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    let result = razer.getBrightness()
                    lua_pushvalue(L, 1)
                    if result.success { lua_pushany(L, result.brightness); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                } else {
                    let brightness = lua_tovalue(L, at: 2) as! NSNumber
                    if brightness.intValue < 0 || brightness.intValue > 100 {
                        lua_pushvalue(L, 1); L.push(false)
                        lua_pushany(L, "The brightness must be between 0 and 100." as NSString)
                        return 3
                    }
                    let result = razer.setBrightness(brightness)
                    lua_pushvalue(L, 1)
                    if result.success { lua_pushany(L, result.brightness); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                }
                return 3
            },
            "backlightsOff": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                let result = razer.setBacklightToOff()
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsCustom": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TTABLE)
                let customColors = NSMutableDictionary()
                lua_pushnil(L)
                while lua_next(L, 2) != 0 {
                    let key = NSNumber(value: lua_tonumber(L, -2))
                    let color = tableToNSColor(L, at: -1)
                    if let color = color { customColors[key] = color }
                    lua_pop(L, 1)
                }
                let result = razer.setBacklightToCustom(colors: customColors)
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsWave": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                let speed = lua_tovalue(L, at: 2) as! NSNumber
                let direction = lua_tovalue(L, at: 3) as! NSString
                if speed.intValue < 1 || speed.intValue > 255 {
                    lua_pushvalue(L, 1); L.push(false)
                    lua_pushany(L, "The speed must be between 1 and 255." as NSString); return 3
                }
                if direction != "left" && direction != "right" {
                    lua_pushvalue(L, 1); L.push(false)
                    lua_pushany(L, "The direction must be 'left' or 'right'." as NSString); return 3
                }
                let result = razer.setBacklightToWave(speed: speed, direction: direction as String)
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsSpectrum": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                let result = razer.setBacklightToSpectrum()
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsReactive": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                let speed = lua_tovalue(L, at: 2) as! NSNumber
                guard let color = tableToNSColor(L, at: 3) else {
                    return luaL_argerror(L, 3, "color table expected")
                }
                if speed.intValue < 1 || speed.intValue > 4 {
                    lua_pushvalue(L, 1); L.push(false)
                    lua_pushany(L, "The speed must be between 1 and 4." as NSString); return 3
                }
                let result = razer.setBacklightToReactive(color: color, speed: speed)
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsStatic": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TTABLE)
                guard let color = tableToNSColor(L, at: 2) else {
                    return luaL_argerror(L, 2, "color table expected")
                }
                let result = razer.setBacklightToStaticColor(color)
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsStarlight": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                let speed = lua_tovalue(L, at: 2) as! NSNumber
                if speed.intValue < 1 || speed.intValue > 3 {
                    lua_pushvalue(L, 1); L.push(false)
                    lua_pushany(L, "The speed must be between 1 and 3." as NSString); return 3
                }
                var color: NSColor? = nil
                var secondaryColor: NSColor? = nil
                if lua_type(L, 3) == LUA_TTABLE { color = tableToNSColor(L, at: 3) }
                if lua_type(L, 4) == LUA_TTABLE { secondaryColor = tableToNSColor(L, at: 4) }
                let result = razer.setBacklightToStarlight(color: color, secondaryColor: secondaryColor, speed: speed)
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "backlightsBreathing": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                var color: NSColor? = nil
                var secondaryColor: NSColor? = nil
                if lua_type(L, 2) == LUA_TTABLE { color = tableToNSColor(L, at: 2) }
                if lua_type(L, 3) == LUA_TTABLE { secondaryColor = tableToNSColor(L, at: 3) }
                let result = razer.setBacklightToBreathing(color: color, secondaryColor: secondaryColor)
                lua_pushvalue(L, 1); L.push(result.success); lua_pushany(L, result.errorMessage)
                return 3
            },
            "orangeStatusLight": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    let result = razer.getOrangeStatusLight()
                    lua_pushvalue(L, 1)
                    if result.success { L.push(result.orangeStatusLight); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                } else {
                    let active = lua_toboolean(L, 2) != 0
                    let result = razer.setOrangeStatusLight(active)
                    lua_pushvalue(L, 1)
                    if result.success { L.push(active); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                }
                return 3
            },
            "greenStatusLight": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    let result = razer.getGreenStatusLight()
                    lua_pushvalue(L, 1)
                    if result.success { L.push(result.greenStatusLight); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                } else {
                    let active = lua_toboolean(L, 2) != 0
                    let result = razer.setGreenStatusLight(active)
                    lua_pushvalue(L, 1)
                    if result.success { L.push(active); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                }
                return 3
            },
            "blueStatusLight": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    let result = razer.getBlueStatusLight()
                    lua_pushvalue(L, 1)
                    if result.success { L.push(result.blueStatusLight); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                } else {
                    let active = lua_toboolean(L, 2) != 0
                    let result = razer.setBlueStatusLight(active)
                    lua_pushvalue(L, 1)
                    if result.success { L.push(active); lua_pushnil(L) }
                    else { lua_pushnil(L); lua_pushany(L, result.errorMessage) }
                }
                return 3
            },
            "_remapping": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                lua_pushany(L, razer.remapping)
                return 1
            },
            "_productID": .closure { L in
                let razer: HSRazerDevice = try L.checkArgument(1)
                lua_pushany(L, NSNumber(value: razer.productID))
                return 1
            },
        ],
        eq: .closure { L in
            if let obj1: HSRazerDevice = L.touserdata(1),
               let obj2: HSRazerDevice = L.touserdata(2) {
                L.push(obj1.isEqual(obj2))
            } else {
                L.push(false)
            }
            return 1
        },
        tostring: .closure { L in
            let obj: HSRazerDevice = try L.checkArgument(1)
            let ptrVal = Int(bitPattern: lua_topointer(L, 1))
            L.push("\(USERDATA_TAG): \(obj.name) (0x\(String(ptrVal, radix: 16)))")
            return 1
        }
    ))

    installMetatableBoilerplate(L, for: HSRazerDevice.self, tag: USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 4)
    lua_pushcclosure(L, razer_init, 0)
    lua_setfield(L, -2, "init")
    lua_pushcclosure(L, razer_discoveryCallback, 0)
    lua_setfield(L, -2, "discoveryCallback")
    lua_pushcclosure(L, razer_numDevices, 0)
    lua_setfield(L, -2, "numDevices")
    lua_pushcclosure(L, razer_getDevice, 0)
    lua_setfield(L, -2, "getDevice")

    // Set module metatable (for __gc)
    lua_createtable(L, 0, 1)
    lua_pushcclosure(L, { L in
        razerManager?.stopHIDManager()
        razerManager?.doGC()
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")
    lua_setmetatable(L, -2)

    return 1
}
