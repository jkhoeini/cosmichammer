import Cocoa
import LuaSkin
import IOKit
import IOKit.hid

private let CAPSLOCK_OFF:    Int32 = 0
private let CAPSLOCK_ON:     Int32 = 1
private let CAPSLOCK_TOGGLE: Int32 = -1
private let CAPSLOCK_QUERY:  Int32 = 9

// MARK: - LED control (ported from led.m)

private func _createMatchingDict(isDevice: Bool, usagePage: UInt32, usage: UInt32) -> NSMutableDictionary? {
    let key = isDevice ? kIOHIDDeviceUsagePageKey : kIOHIDElementUsagePageKey
    let dic = NSMutableDictionary()
    dic[key as String] = NSNumber(value: usagePage)
    if usage != 0 {
        let usageKey = isDevice ? kIOHIDDeviceUsageKey : kIOHIDElementUsageKey
        dic[usageKey as String] = NSNumber(value: usage)
    }
    return dic
}

private func hidled_set(_ usage: UInt32, _ targetValue: Int) -> Bool {
    var success = false

    guard let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)) as IOHIDManager? else {
        return false
    }
    defer {
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    guard let dic = _createMatchingDict(isDevice: true, usagePage: UInt32(kHIDPage_GenericDesktop), usage: UInt32(kHIDUsage_GD_Keyboard)) else {
        return false
    }
    IOHIDManagerSetDeviceMatching(mgr, dic)

    let err = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard err == kIOReturnSuccess else { return false }

    guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        return false
    }

    guard let elDic = _createMatchingDict(isDevice: false, usagePage: UInt32(kHIDPage_LEDs), usage: 0) else {
        return false
    }

    for device in deviceSet {
        guard IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) else {
            continue
        }
        guard let elements = IOHIDDeviceCopyMatchingElements(device, elDic, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            continue
        }
        for element in elements {
            let usagePage = IOHIDElementGetUsagePage(element)
            guard usagePage == kHIDPage_LEDs else { continue }
            let elUsage = IOHIDElementGetUsage(element)
            if elUsage == usage {
                let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, targetValue)
                IOHIDDeviceSetValue(device, element, val)
                success = true
                break
            }
        }
    }

    return success
}

// Source: https://discussions.apple.com/thread/7094207

private func accessCapslock(_ op: Int32) -> Int32 {
    var state = false

    let mdict = IOServiceMatching(kIOHIDSystemClass)
    let ios = IOServiceGetMatchingService(kIOMainPortDefault, mdict)
    guard ios != 0 else {
        return -1
    }

    var ioc: io_connect_t = 0
    var kr = IOServiceOpen(ios, mach_task_self_, UInt32(kIOHIDParamConnectType), &ioc)
    IOObjectRelease(ios)
    guard kr == KERN_SUCCESS else {
        return Int32(kr)
    }

    switch op {
    case CAPSLOCK_ON, CAPSLOCK_OFF:
        state = (op == CAPSLOCK_ON)
        kr = IOHIDSetModifierLockState(ioc, Int32(kIOHIDCapsLockState), state)
        if kr != KERN_SUCCESS {
            IOServiceClose(ioc)
            fputs("IOHIDSetModifierLockState() failed: \(kr)\n", stderr)
            return Int32(kr)
        }

    case CAPSLOCK_TOGGLE:
        kr = IOHIDGetModifierLockState(ioc, Int32(kIOHIDCapsLockState), &state)
        if kr != KERN_SUCCESS {
            IOServiceClose(ioc)
            fputs("IOHIDGetModifierLockState() failed: \(kr)\n", stderr)
            return Int32(kr)
        }
        state = !state
        kr = IOHIDSetModifierLockState(ioc, Int32(kIOHIDCapsLockState), state)
        if kr != KERN_SUCCESS {
            IOServiceClose(ioc)
            fputs("IOHIDSetModifierLockState() failed: \(kr)\n", stderr)
            return Int32(kr)
        }

    case CAPSLOCK_QUERY:
        kr = IOHIDGetModifierLockState(ioc, Int32(kIOHIDCapsLockState), &state)
        if kr != KERN_SUCCESS {
            IOServiceClose(ioc)
            return Int32(kr)
        }

    default:
        assertionFailure("Unexpected CAPS_LOCK op passed to accessCapslock: \(op)")
    }

    IOServiceClose(ioc)
    return state ? 1 : 0
}

// hs.hid.capslock.get() -> bool
// Function
// Checks the state of the caps lock via HID
private func hid_capslock_query(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let state = accessCapslock(CAPSLOCK_QUERY)
    lua_pushboolean(L, state)
    return 1
}

// hs.hid.capslock.toggle() -> bool
// Function
// Toggles the state of caps lock via HID
private func hid_capslock_toggle(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let state = accessCapslock(CAPSLOCK_TOGGLE)
    lua_pushboolean(L, state)
    return 1
}

// hs.hid.capslock.set(true) -> bool
// Function
// Assigns capslock to the desired state
private func hid_capslock_on(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let state = accessCapslock(CAPSLOCK_ON)
    lua_pushboolean(L, state)
    return 1
}

// hs.hid.capslock.set(false) -> bool
// Function
// Assigns capslock to the desired state
private func hid_capslock_off(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let state = accessCapslock(CAPSLOCK_OFF)
    lua_pushboolean(L, state)
    return 1
}

private func hid_led_set(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBOOLEAN, LS_TBREAK)

    let name = skin.toNSObject(atIndex: 1) as! String
    let targetValue = Int(lua_toboolean(L, 2))
    var ret = false

    switch name {
    case "caps":
        ret = hidled_set(UInt32(kHIDUsage_LED_CapsLock), targetValue)
    case "scroll":
        ret = hidled_set(UInt32(kHIDUsage_LED_ScrollLock), targetValue)
    case "num":
        ret = hidled_set(UInt32(kHIDUsage_LED_NumLock), targetValue)
    default:
        skin.logError("Unsupported LED name")
    }

    lua_pushboolean(L, ret ? 1 : 0)
    return 1
}

private var hid_lib: [luaL_Reg] = [
    luaL_Reg(name: ("_capslock_query"  as NSString).utf8String, func: hid_capslock_query),
    luaL_Reg(name: ("_capslock_toggle" as NSString).utf8String, func: hid_capslock_toggle),
    luaL_Reg(name: ("_capslock_on"     as NSString).utf8String, func: hid_capslock_on),
    luaL_Reg(name: ("_capslock_off"    as NSString).utf8String, func: hid_capslock_off),
    luaL_Reg(name: ("_led_set"         as NSString).utf8String, func: hid_led_set),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhid")
func luaopen_hs_libhid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.hid", functions: &hid_lib, metaFunctions: nil)
    return 1
}
