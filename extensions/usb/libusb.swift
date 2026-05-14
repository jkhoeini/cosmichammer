import Cocoa
import IOKit
import IOKit.usb
import LuaSkin

private let productNameKey = kUSBProductString as CFString
private let vendorNameKey = kUSBVendorString as CFString
private let productIDKey = kUSBProductID as CFString
private let vendorIDKey = kUSBVendorID as CFString

private func usb_gc(_ L: OpaquePointer!) -> Int32 {
    return 0
}

/// hs.usb.attachedDevices() -> table or nil
/// Function
/// Gets details about currently attached USB devices
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing information about currently attached USB devices, or nil if an error occurred. The table contains a sub-table for each USB device, the keys of which are:
///   * productName - A string containing the name of the device
///   * vendorName - A string containing the name of the device vendor
///   * vendorID - A number containing the Vendor ID of the device
///   * productID - A number containing the Product ID of the device
private func usb_attachedDevices(_ L: OpaquePointer!) -> Int32 {
    guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
        lua_pushnil(L)
        return 1
    }

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    var i: lua_Integer = 1

    var usbDevice = IOIteratorNext(iterator)
    while usbDevice != 0 {
        lua_pushinteger(L, i)
        i += 1

        var deviceData: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(usbDevice, &deviceData, kCFAllocatorDefault, 0)

        if let dict = deviceData?.takeRetainedValue() as? [CFString: Any] {
            let productName = dict[productNameKey] as? String ?? ""
            let vendorName = dict[vendorNameKey] as? String ?? ""
            let productID = (dict[productIDKey] as? NSNumber)?.intValue ?? 0
            let vendorID = (dict[vendorIDKey] as? NSNumber)?.intValue ?? 0

            lua_newtable(L)
            lua_pushstring(L, "productName")
            lua_pushstring(L, productName)
            lua_settable(L, -3)
            lua_pushstring(L, "vendorName")
            lua_pushstring(L, vendorName)
            lua_settable(L, -3)
            lua_pushstring(L, "productID")
            lua_pushinteger(L, lua_Integer(productID))
            lua_settable(L, -3)
            lua_pushstring(L, "vendorID")
            lua_pushinteger(L, lua_Integer(vendorID))
            lua_settable(L, -3)
        } else {
            lua_newtable(L)
        }

        IOObjectRelease(usbDevice)
        lua_settable(L, -3)

        usbDevice = IOIteratorNext(iterator)
    }

    IOObjectRelease(iterator)
    return 1
}

private var usblib: [luaL_Reg] = [
    luaL_Reg(name: strdup("attachedDevices"), func: usb_attachedDevices),
    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: usb_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libusb")
public func luaopen_hs_libusb(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.registerLibrary("hs.usb", functions: &usblib, metaFunctions: &metalib)
    return 1
}
