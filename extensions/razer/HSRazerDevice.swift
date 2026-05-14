import Foundation
import Cocoa
import IOKit
import IOKit.hid
import LuaSkin
import Darwin.POSIX.sys.time

// MARK: - Razer USB Device Report Structure

/// Mirrors the C union HSTransactionID.
struct HSTransactionID {
    var id: UInt8

    /// 3-bit device identifier | 5-bit unique transaction ID
    init(rawID: UInt8) { self.id = rawID }
    init() { self.id = 0 }
}

/// Mirrors the C union HSCommandID.
struct HSCommandID {
    var id: UInt8

    /// 1-bit direction (1 = device→Mac, 0 = Mac→device) | 7-bit command ID
    init(rawID: UInt8) { self.id = rawID }
    init() { self.id = 0 }
}

/// The 90-byte report structure sent to / received from a Razer USB device.
struct HSRazerReport {
    var status: UInt8 = 0x00                // Always 0x00 for a New Command
    var transaction_id: HSTransactionID = HSTransactionID()
    var remaining_packets: UInt16 = 0       // Big-endian byte order
    var protocol_type: UInt8 = 0x00         // Always seems to be 0x00
    var data_size: UInt8 = 0                // How many arguments used in the report
    var command_class: UInt8 = 0            // The type of command being triggered
    var command_id: HSCommandID = HSCommandID()
    var arguments: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  //  0- 9
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 10-19
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 20-29
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 30-39
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 40-49
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 50-59
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // 60-69
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8   // 70-79
    ) = (0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0)
    var crc: UInt8 = 0                      // Simple XOR checksum
    var reserved: UInt8 = 0x00              // Always 0x00
}

// Helper: read/write the 80-element argument tuple by index.
private func setArgument(_ report: inout HSRazerReport, index: Int, value: UInt8) {
    withUnsafeMutableBytes(of: &report.arguments) { buf in
        buf[index] = value
    }
}

private func getArgument(_ report: HSRazerReport, index: Int) -> UInt8 {
    var copy = report.arguments
    return withUnsafeBytes(of: &copy) { buf in buf[index] }
}

// MARK: - Helper

private func getSecondsSinceEpoch() -> Double {
    var v = timeval()
    gettimeofday(&v, nil)
    return Double(v.tv_sec) + Double(v.tv_usec) / 1.0e6
}

// MARK: - HSRazerResult

@objcMembers
class HSRazerResult: NSObject {
    var success: Bool = false
    var errorMessage: NSString?

    var brightness: NSNumber?

    var orangeStatusLight: Bool = false
    var greenStatusLight: Bool = false
    var blueStatusLight: Bool = false

    var argumentTwo: UInt8 = 0
}

// MARK: - Event Tap Callback (C-convention)

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    // Prevent a crash when doing garbage collection:
    if type == .tapDisabledByUserInput {
        return Unmanaged.passRetained(event)
    }

    guard let refcon = refcon else {
        return Unmanaged.passRetained(event)
    }

    let device = Unmanaged<HSRazerDevice>.fromOpaque(refcon).takeUnretainedValue()

    // Restart event tap if it times out:
    if type == .tapDisabledByTimeout {
        CGEvent.tapEnable(tap: device.eventTap!, enable: true)
        return Unmanaged.passRetained(event)
    }

    // Guard against this callback being delivered at a point where LuaSkin has been reset:
    let skin = LuaSkin.shared(withState: nil)
    if !skin.checkGCCanary(device.lsCanary) {
        return Unmanaged.passRetained(event)
    }

    // Throw away the event if we recently scrolled with the Razer Device:
    let currentTime = getSecondsSinceEpoch() - 0.1
    if currentTime < device.lastScrollWheelEvent {
        return nil
    } else {
        return Unmanaged.passRetained(event)
    }
}

// MARK: - HSRazerDevice

@objcMembers
class HSRazerDevice: NSObject {

    var device: IOHIDDevice?
    var manager: AnyObject?
    var selfRefCount: Int = 0
    var buttonCallbackRef: Int32 = LUA_NOREF
    var isValid: Bool = true

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

    var lsCanary: LSGCCanary = 0

    // MARK: - Init / Invalidate

    init(device: IOHIDDevice, manager: AnyObject) {
        super.init()
        self.device = device
        self.isValid = true
        self.manager = manager
        self.buttonCallbackRef = LUA_NOREF
        self.selfRefCount = 0

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
        // Abort if the device is no longer valid:
        guard isValid else { return }

        // Get button name from device dictionary:
        guard let buttonName = buttonNames?.value(forKey: scancodeString) as? String else {
            return
        }

        // Process the button action:
        var buttonAction = ""
        let scrollWheelIDString = "\(scrollWheelID)"

        if scancodeString == scrollWheelIDString {
            // Scroll Wheel:
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
            // Buttons:
            if pressed == 1 {
                buttonAction = "pressed"
            } else {
                buttonAction = "released"
            }
        }

        // Trigger the Lua callback:
        if buttonCallbackRef != LUA_NOREF {
            let skin = LuaSkin.shared(withState: nil)
            guard skin.checkGCCanary(lsCanary) else { return }

            _lua_stackguard_entry(skin.L)
            skin.pushLuaRef(razerRefTable, ref: buttonCallbackRef)
            skin.pushNSObject(self)
            skin.pushNSObject(buttonName as NSString)
            skin.pushNSObject(buttonAction as NSString)
            skin.protectedCallAndError("hs.razer:callback", nargs: 3, nresults: 0)
            _lua_stackguard_exit(skin.L)
        }
    }

    // MARK: - Event Tap for Scroll Wheel

    func setupEventTap() {
        guard scrollWheelID != 0 else {
            NSLog("[hs.razer] The device does not have a scroll wheel ID, so aborting event tap setup.")
            return
        }

        let location: CGEventTapLocation = .cghidEventTap
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        let unmanaged = Unmanaged.passUnretained(self)
        eventTap = CGEvent.tapCreate(
            tap: location,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: unmanaged.toOpaque()
        )

        guard let tap = eventTap else {
            NSLog("[hs.razer] Failed to create the event tap.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func destroyEventTap() {
        if let tap = eventTap {
            if CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            // CFMachPort is managed; releasing happens when the reference drops.
            // But to match the ObjC CFRelease:
            eventTap = nil
        }
    }

    // MARK: - Keyboard Backlight Placeholders

    func setBacklightToStaticColor(_ color: NSColor) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToStaticColor method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToOff() -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToOff method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToWave(speed: NSNumber, direction: String) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToWaveWithSpeed method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToSpectrum() -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToSpectrum method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToReactive(color: NSColor, speed: NSNumber) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToReactiveWithColor method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToStarlight(color: NSColor?, secondaryColor: NSColor?, speed: NSNumber) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToStarlightWithColor method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToBreathing(color: NSColor?, secondaryColor: NSColor?) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToBreathWithColor method not implemented").raise()
        return HSRazerResult()
    }

    func setBacklightToCustom(colors: NSMutableDictionary) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBacklightToCustomWithColors method not implemented").raise()
        return HSRazerResult()
    }

    // MARK: - Brightness Placeholders

    func getBrightness() -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "getBrightness method not implemented").raise()
        return HSRazerResult()
    }

    func setBrightness(_ brightness: NSNumber) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBrightness method not implemented").raise()
        return HSRazerResult()
    }

    // MARK: - Status Light Placeholders

    func getOrangeStatusLight() -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "getOrangeStatusLight method not implemented").raise()
        return HSRazerResult()
    }

    func setOrangeStatusLight(_ active: Bool) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setOrangeStatusLight method not implemented").raise()
        return HSRazerResult()
    }

    func getGreenStatusLight() -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "getGreenStatusLight method not implemented").raise()
        return HSRazerResult()
    }

    func setGreenStatusLight(_ active: Bool) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setGreenStatusLight method not implemented").raise()
        return HSRazerResult()
    }

    func getBlueStatusLight() -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "getBlueStatusLight method not implemented").raise()
        return HSRazerResult()
    }

    func setBlueStatusLight(_ active: Bool) -> HSRazerResult {
        NSException(name: NSExceptionName("HSRazerDeviceUnimplemented"),
                    reason: "setBlueStatusLight method not implemented").raise()
        return HSRazerResult()
    }

    // MARK: - USB Device Methods

    func getUSBRazerDevice() -> UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>? {
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)

        var iter: io_iterator_t = 0
        let kReturn = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter)

        guard kReturn == kIOReturnSuccess else {
            return nil
        }

        var usbDevice: io_service_t = IOIteratorNext(iter)
        while usbDevice != 0 {
            var plugInInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0

            let createResult = IOCreatePlugInInterfaceForService(
                usbDevice,
                kIOUSBDeviceUserClientTypeID,
                kIOCFPlugInInterfaceID,
                &plugInInterface,
                &score
            )

            IOObjectRelease(usbDevice)

            guard createResult == kIOReturnSuccess, let plugin = plugInInterface?.pointee?.pointee else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            var dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
            let uuidBytes = CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID)
            var uuidBytesCopy = uuidBytes
            let hResult = withUnsafeMutablePointer(to: &dev) { devPtr in
                plugin.QueryInterface(
                    plugInInterface,
                    uuidBytesCopy,
                    UnsafeMutablePointer<LPVOID?>(OpaquePointer(devPtr))
                )
            }

            plugInInterface?.pointee?.pointee.Release(plugInInterface)

            guard hResult == S_OK, let devUnwrapped = dev, let devIface = devUnwrapped.pointee?.pointee else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Make sure the location ID matches:
            var locationIDValue: UInt32 = 0
            var kr = devIface.GetLocationID(devUnwrapped, &locationIDValue)
            guard kr == kIOReturnSuccess, locationIDValue == self.locationID?.uint32Value else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Make sure the vendor matches:
            var vendor: UInt16 = 0
            kr = devIface.GetDeviceVendor(devUnwrapped, &vendor)
            guard kr == kIOReturnSuccess, vendor == USB_VID_RAZER else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Make sure the product matches:
            var product: UInt16 = 0
            kr = devIface.GetDeviceProduct(devUnwrapped, &product)
            guard kr == kIOReturnSuccess, product == UInt16(self.productID) else {
                usbDevice = IOIteratorNext(iter)
                continue
            }

            // Open the device:
            let openResult = devIface.USBDeviceOpen(devUnwrapped)
            guard openResult == kIOReturnSuccess else {
                devIface.Release(devUnwrapped)
                usbDevice = IOIteratorNext(iter)
                continue
            }

            IOObjectRelease(iter)
            return devUnwrapped
        }

        return nil
    }

    func sendRazerReport(transactionID: Int32, commandClass: Int32, commandID: Int32, arguments: NSDictionary) -> HSRazerResult {
        let result = HSRazerResult()

        let wValue: Int32 = 0x300
        let wIndex: Int32 = 0x01
        let wLength: Int32 = 90

        // Setup an empty Razer Report:
        var report = HSRazerReport()

        let dataSize = Int32(arguments.count)

        report.status = 0x00
        report.transaction_id = HSTransactionID(rawID: UInt8(transactionID))
        report.remaining_packets = 0x00
        report.protocol_type = 0x00
        report.data_size = UInt8(dataSize)
        report.command_class = UInt8(commandClass)
        report.command_id = HSCommandID(rawID: UInt8(commandID))
        report.reserved = 0x00

        // Process the arguments:
        for x in 0..<arguments.count {
            if let argument = arguments.object(forKey: NSNumber(value: x)) as? NSNumber {
                setArgument(&report, index: x, value: UInt8(argument.intValue))
            }
        }

        // Compute CRC (XOR bytes 2..87):
        var crc: UInt8 = 0
        withUnsafeBytes(of: &report) { buf in
            for i in 2..<88 {
                crc ^= buf[i]
            }
        }
        report.crc = crc

        // Build the USB device request:
        var request = IOUSBDevRequest()
        request.bmRequestType = UInt8(kIOUSBDeviceRequestDirectionOut | kIOUSBDeviceRequestTypeClass | kIOUSBDeviceRequestRecipientValueInterface)
        request.bRequest = UInt8(kIOUSBDeviceRequestSetConfiguration)
        request.wValue = UInt16(wValue)
        request.wIndex = UInt16(wIndex)
        request.wLength = UInt16(wLength)

        let reportSize = MemoryLayout<HSRazerReport>.size
        let reportPtr = UnsafeMutablePointer<HSRazerReport>.allocate(capacity: 1)
        reportPtr.initialize(to: report)
        request.pData = UnsafeMutableRawPointer(reportPtr)

        // Get the Razer USB device:
        guard let razerDevice = getUSBRazerDevice(),
              let iface = razerDevice.pointee?.pointee else {
            reportPtr.deallocate()
            result.errorMessage = "Failed to create a Razer device for the initial report."
            return result
        }

        // Send the report to the device:
        let deviceRequestResult = iface.DeviceRequest(razerDevice, &request)
        reportPtr.deallocate()

        if deviceRequestResult != kIOReturnSuccess {
            iface.USBDeviceClose(razerDevice)
            iface.Release(razerDevice)
            result.errorMessage = "Failed to send Device Request: \(deviceRequestResult)" as NSString
            return result
        }

        // Wait for a response back:
        usleep(500)

        // Build a response request:
        var responseRequest = IOUSBDevRequest()
        var responseReport = HSRazerReport()

        responseRequest.bmRequestType = UInt8(kIOUSBDeviceRequestDirectionIn | kIOUSBDeviceRequestTypeClass | kIOUSBDeviceRequestRecipientValueInterface)
        responseRequest.bRequest = UInt8(kIOUSBDeviceRequestClearFeature)
        responseRequest.wValue = UInt16(wValue)
        responseRequest.wIndex = UInt16(wIndex)
        responseRequest.wLength = UInt16(wLength)
        responseRequest.pData = UnsafeMutableRawPointer(&responseReport)

        let responseResult = iface.DeviceRequest(razerDevice, &responseRequest)

        // Close & Release the USB Device:
        iface.USBDeviceClose(razerDevice)
        iface.Release(razerDevice)

        // Process the response:
        if responseResult != kIOReturnSuccess {
            result.errorMessage = "Failed to get a response back from the Razer Device: \(String(cString: mach_error_string(responseResult)))" as NSString
        } else {
            if responseReport.remaining_packets != report.remaining_packets {
                result.errorMessage = "The sent report remaining packets don't match the response remaining packets."
            } else if responseReport.command_class != report.command_class {
                result.errorMessage = "The sent report command class doesn't match the response command class."
            } else if responseReport.command_id.id != report.command_id.id {
                result.errorMessage = "The sent report command ID doesn't match the response command ID."
            } else if responseReport.status == 0x01 {
                // "Busy" -- still successfully executes the command.
                result.success = true
            } else if responseReport.status == 0x02 {
                result.success = true
            } else if responseReport.status == 0x03 {
                result.errorMessage = "The command sent to the Razer device failed."
            } else if responseReport.status == 0x04 {
                result.errorMessage = "The command sent to the Razer device timed out."
            } else if responseReport.status == 0x05 {
                result.errorMessage = "The command sent to the Razer device is not supported."
            } else {
                result.errorMessage = "Unexpected status back from the Razer device: \(responseReport.status)" as NSString
            }
        }

        // Put any useful arguments into the result:
        result.argumentTwo = getArgument(responseReport, index: 2)

        return result
    }
}
