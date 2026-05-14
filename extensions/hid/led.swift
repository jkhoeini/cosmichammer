import Foundation
import IOKit
import IOKit.hid

private func createMatchingDict(isDevice: Bool, usagePage: UInt32, usage: UInt32) -> NSMutableDictionary {
    let pageKey = isDevice ? kIOHIDDeviceUsagePageKey : kIOHIDElementUsagePageKey
    let dic = NSMutableDictionary()
    dic[pageKey] = NSNumber(value: usagePage)
    if usage != 0 {
        let usageKey = isDevice ? kIOHIDDeviceUsageKey : kIOHIDElementUsageKey
        dic[usageKey] = NSNumber(value: usage)
    }
    return dic
}

@_cdecl("hidled_set")
func hidled_set(_ usage: UInt32, _ targetValue: Int) -> Bool {
    var success = false

    // create an IO HID Manager reference
    guard let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)) as IOHIDManager? else {
        return false
    }

    // Create a device matching dictionary
    let dic = createMatchingDict(isDevice: true, usagePage: UInt32(kHIDPage_GenericDesktop),
                                 usage: UInt32(kHIDUsage_GD_Keyboard))

    // set the HID device matching dictionary
    IOHIDManagerSetDeviceMatching(mgr, dic)

    // Now open the IO HID Manager reference
    let err = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard err == kIOReturnSuccess else {
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        return false
    }

    // and copy out its devices
    guard let deviceCFSetRef = IOHIDManagerCopyDevices(mgr) else {
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        return false
    }

    let deviceCount = CFSetGetCount(deviceCFSetRef)
    // allocate a block of memory to extract the device refs from the set into
    let refs = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: deviceCount)
    defer { refs.deallocate() }
    // now extract the device refs from the set
    CFSetGetValues(deviceCFSetRef, refs)

    // before we get into the device loop set up element matching dictionary
    let elementDic = createMatchingDict(isDevice: false, usagePage: UInt32(kHIDPage_LEDs), usage: 0)

    for deviceIndex in 0..<deviceCount {
        guard let rawRef = refs[deviceIndex] else { continue }
        let deviceRef = Unmanaged<IOHIDDevice>.fromOpaque(rawRef).takeUnretainedValue()

        // if this isn't a keyboard device, skip it
        guard IOHIDDeviceConformsTo(deviceRef, UInt32(kHIDPage_GenericDesktop),
                                    UInt32(kHIDUsage_GD_Keyboard)) else {
            continue
        }

        // copy all the elements
        guard let elements = IOHIDDeviceCopyMatchingElements(deviceRef, elementDic,
                                                              IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            continue
        }

        for element in elements {
            let usagePage = IOHIDElementGetUsagePage(element)
            // if this isn't an LED element, skip it
            guard usagePage == kHIDPage_LEDs else { continue }
            let elUsage = IOHIDElementGetUsage(element)
            if elUsage == usage {
                // create the IO HID Value to be sent to this LED element
                let timestamp: UInt64 = 0
                guard let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element,
                                                                  timestamp, targetValue) else {
                    break
                }
                // now set it on the device
                IOHIDDeviceSetValue(deviceRef, element, val)
                success = true
                break
            }
        }
        if success { break }
    }

    IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    return success
}
