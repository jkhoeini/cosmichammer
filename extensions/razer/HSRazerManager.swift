import Foundation
import IOKit
import IOKit.hid
import LuaSkin

// MARK: - IOKit C callbacks

private func HIDcallback(context: UnsafeMutableRawPointer?,
                          result: IOReturn,
                          sender: UnsafeMutableRawPointer?,
                          value: IOHIDValue) {
    guard let sender = sender else { return }
    let senderDevice = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()

    guard let locationID = IOHIDDeviceGetProperty(senderDevice, kIOHIDLocationIDKey as CFString) as? NSNumber else {
        return
    }
    guard let context = context else { return }
    let manager = Unmanaged<HSRazerManager>.fromOpaque(context).takeUnretainedValue()

    for device in manager.devices {
        guard let razerDevice = device as? HSRazerDevice else { continue }
        if razerDevice.locationID == locationID {
            let elem = IOHIDValueGetElement(value)
            let scancode = IOHIDElementGetUsage(elem)
            let pressed = IOHIDValueGetIntegerValue(value)

            if scancode < 4 || scancode > 231 {
                return
            }

            let scancodeString = "\(scancode)"
            razerDevice.deviceButtonPress(scancodeString, pressed: Int(pressed))
        }
    }
}

private func HIDconnect(context: UnsafeMutableRawPointer?,
                         result: IOReturn,
                         sender: UnsafeMutableRawPointer?,
                         device: IOHIDDevice) {
    guard let context = context else { return }
    let manager = Unmanaged<HSRazerManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceDidConnect(device)
}

private func HIDdisconnect(context: UnsafeMutableRawPointer?,
                            result: IOReturn,
                            sender: UnsafeMutableRawPointer?,
                            device: IOHIDDevice) {
    guard let context = context else { return }
    let manager = Unmanaged<HSRazerManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceDidDisconnect(device)
    IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
}

// MARK: - HSRazerManager

@objcMembers
class HSRazerManager: NSObject {
    var ioHIDManager: IOHIDManager?
    var devices: NSMutableArray
    var discoveryCallbackRef: Int32 = LUA_NOREF

    override init() {
        devices = NSMutableArray(capacity: 1)

        super.init()

        discoveryCallbackRef = LUA_NOREF

        // Create a HID device manager:
        ioHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDManagerOptionNone))

        // Configure the HID manager to match against Razer devices:
        let vendorIDKey = kIOHIDVendorIDKey
        let productIDKey = kIOHIDProductIDKey

        let matchTartarusV2: [String: Any] = [
            vendorIDKey: USB_VID_RAZER,
            productIDKey: USB_PID_RAZER_TARTARUS_V2
        ]

        IOHIDManagerSetDeviceMatchingMultiple(ioHIDManager!, [matchTartarusV2] as CFArray)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Add callbacks for relevant events:
        IOHIDManagerRegisterDeviceMatchingCallback(ioHIDManager!, HIDconnect, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(ioHIDManager!, HIDdisconnect, selfPtr)
        IOHIDManagerRegisterInputValueCallback(ioHIDManager!, HIDcallback, selfPtr)

        // Start HID manager on the current runloop:
        IOHIDManagerScheduleWithRunLoop(ioHIDManager!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func doGC() {
        guard let mgr = ioHIDManager else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Remove callbacks:
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, selfPtr)

        // Remove from runloop:
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Deallocate:
        ioHIDManager = nil
    }

    @discardableResult
    func startHIDManager() -> Bool {
        guard let mgr = ioHIDManager else { return false }
        let tIOReturn = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        return tIOReturn == kIOReturnSuccess
    }

    @discardableResult
    func stopHIDManager() -> Bool {
        guard let mgr = ioHIDManager else { return true }
        let tIOReturn = IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        return tIOReturn == kIOReturnSuccess
    }

    @discardableResult
    func deviceDidConnect(_ device: IOHIDDevice) -> HSRazerDevice? {
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber

        // Make sure the vendor is Razer:
        guard let vendorID = vendorID, vendorID.int32Value == USB_VID_RAZER else {
            return nil
        }

        var razerDevice: HSRazerDevice? = nil

        // Make sure the product ID matches:
        switch productID?.int32Value {
        case Int32(USB_PID_RAZER_TARTARUS_V2):
            // We only want to register each device once:
            var alreadyRegistered = false
            for checkDevice in devices {
                if let existing = checkDevice as? HSRazerDevice, existing.locationID == locationID {
                    alreadyRegistered = true
                    break
                }
            }

            if !alreadyRegistered {
                razerDevice = HSRazerTartarusV2Device(device: device, manager: self)
                razerDevice!.locationID = locationID
                razerDevice!.setupEventTap()
            }
        default:
            break
        }

        guard let razerDevice = razerDevice else {
            return nil
        }

        devices.add(razerDevice)

        let skin = LuaSkin.shared(withState: nil)
        razerDevice.lsCanary = skin.createGCCanary()

        _lua_stackguard_entry(skin.L)
        if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
            skin.logWarn("hs.razer detected a device connecting, but no discovery callback has been set. See hs.razer.discoveryCallback()")
        } else {
            skin.pushLuaRef(razerRefTable, ref: discoveryCallbackRef)
            lua_pushboolean(skin.L, 1)
            skin.pushNSObject(razerDevice)
            skin.protectedCallAndError("hs.razer:deviceDidConnect", nargs: 2, nresults: 0)
        }
        _lua_stackguard_exit(skin.L)

        return razerDevice
    }

    func deviceDidDisconnect(_ device: IOHIDDevice) {
        for obj in devices {
            guard let razerDevice = obj as? HSRazerDevice else { continue }
            if razerDevice.device === device {
                razerDevice.invalidate()
                let skin = LuaSkin.shared(withState: nil)
                _lua_stackguard_entry(skin.L)
                if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
                    skin.logWarn("hs.razer detected a device disconnecting, but no callback has been set. See hs.razer.discoveryCallback()")
                } else {
                    skin.pushLuaRef(razerRefTable, ref: discoveryCallbackRef)
                    lua_pushboolean(skin.L, 0)
                    skin.pushNSObject(razerDevice)
                    skin.protectedCallAndError("hs.razer:deviceDidDisconnect", nargs: 2, nresults: 0)
                }
                devices.remove(razerDevice)
                _lua_stackguard_exit(skin.L)
                return
            }
        }
    }
}
