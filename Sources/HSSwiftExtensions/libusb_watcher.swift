import Foundation
import Cocoa
import IOKit
import IOKit.usb
import LuaSkin

// kIOMessageServiceIsTerminated is a C macro not bridged to Swift
private let kIOMessageServiceIsTerminated: UInt32 = 0xE000_0010

/// === hs.usb.watcher ===
///
/// Watch for USB device connection/disconnection events

private let USERDATA_TAG = "hs.usb.watcher"
private var refTable: Int32 = 0

// Userdata object for each watcher
private struct USBWatcher {
    var running: Bool
    var isFirstRun: Bool
    var fn: Int32
    var gNotifyPort: IONotificationPortRef?
    var gAddedIter: io_iterator_t
    var runLoopSource: Unmanaged<CFRunLoopSource>?
    var lsCanary: LSGCCanary
}

// Private data for each USB device
private struct USBPrivData {
    var watcher: UnsafeMutablePointer<USBWatcher>
    var notification: io_object_t
    var productName: UnsafeMutablePointer<CChar>?
    var vendorName: UnsafeMutablePointer<CChar>?
    var productID: Int32
    var vendorID: Int32
}

// Process an IOKit notification, discarding it if it's not about a device being removed
private func DeviceNotification(refCon: UnsafeMutableRawPointer?,
                                service: io_service_t,
                                messageType: natural_t,
                                messageArgument: UnsafeMutableRawPointer?) {
    guard let refCon = refCon else { return }
    let privateDataRef = refCon.assumingMemoryBound(to: USBPrivData.self)
    let watcher = privateDataRef.pointee.watcher

    if messageType == kIOMessageServiceIsTerminated {
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!
        if !skin.check(watcher.pointee.lsCanary) {
            return
        }
        _lua_stackguard_entry(L)

        skin.pushLuaRef(refTable, ref: watcher.pointee.fn)

        // Prepare the callback's argument table
        lua_newtable(L)
        lua_pushstring(L, "productName")
        lua_pushstring(L, privateDataRef.pointee.productName)
        lua_settable(L, -3)
        lua_pushstring(L, "vendorName")
        lua_pushstring(L, privateDataRef.pointee.vendorName)
        lua_settable(L, -3)
        lua_pushstring(L, "productID")
        lua_pushinteger(L, lua_Integer(privateDataRef.pointee.productID))
        lua_settable(L, -3)
        lua_pushstring(L, "vendorID")
        lua_pushinteger(L, lua_Integer(privateDataRef.pointee.vendorID))
        lua_settable(L, -3)
        lua_pushstring(L, "eventType")
        lua_pushstring(L, "removed")
        lua_settable(L, -3)

        skin.protectedCallAndError("hs.usb.watcher:removed callback", nargs: 1, nresults: 0)

        // Free the USB private data
        IOObjectRelease(privateDataRef.pointee.notification)
        if let pName = privateDataRef.pointee.productName {
            free(pName)
            privateDataRef.pointee.productName = nil
        }
        if let vName = privateDataRef.pointee.vendorName {
            free(vName)
            privateDataRef.pointee.vendorName = nil
        }
        free(privateDataRef)

        _lua_stackguard_exit(L)
    }
}

// Iterate over new devices
private func DeviceAdded(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    let skin = LuaSkin.skin(with: nil)
    let L = skin.l!
    _lua_stackguard_entry(L)

    let watcher = refCon!.assumingMemoryBound(to: USBWatcher.self)

    var usbDevice = IOIteratorNext(iterator)
    while usbDevice != 0 {
        // Prepare an object to store private data about this USB device
        let privateDataRef = UnsafeMutablePointer<USBPrivData>.allocate(capacity: 1)
        privateDataRef.initialize(to: USBPrivData(
            watcher: watcher,
            notification: 0,
            productName: nil,
            vendorName: nil,
            productID: 0,
            vendorID: 0
        ))

        // Fetch the IOKit properties for this device
        var deviceData: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(usbDevice, &deviceData, kCFAllocatorDefault, 0)

        if let dict = deviceData?.takeRetainedValue() as? [String: Any] {
            // Extract the USB device's name
            let productName = (dict[kUSBProductString] as? String) ?? ""
            let length = productName.utf8.count + 1
            privateDataRef.pointee.productName = UnsafeMutablePointer<CChar>.allocate(capacity: length)
            _ = productName.withCString { src in
                strcpy(privateDataRef.pointee.productName!, src)
            }

            // Extract the USB device's vendor's name
            let vendorName = (dict[kUSBVendorString] as? String) ?? ""
            let vLength = vendorName.utf8.count + 1
            privateDataRef.pointee.vendorName = UnsafeMutablePointer<CChar>.allocate(capacity: vLength)
            _ = vendorName.withCString { src in
                strcpy(privateDataRef.pointee.vendorName!, src)
            }

            // Extract the USB device's product/vendor IDs
            privateDataRef.pointee.productID = Int32((dict[kUSBProductID] as? NSNumber)?.intValue ?? 0)
            privateDataRef.pointee.vendorID = Int32((dict[kUSBVendorID] as? NSNumber)?.intValue ?? 0)
        }

        // Register for notifications relating to this device
        let kr = IOServiceAddInterestNotification(
            watcher.pointee.gNotifyPort,
            usbDevice,
            kIOGeneralInterest,
            DeviceNotification,
            privateDataRef,
            &privateDataRef.pointee.notification
        )
        if kr != KERN_SUCCESS {
            skin.logBreadcrumb(String(format: "IOServiceAddInterestNotification returned 0x%08x", kr))
        }

        IOObjectRelease(usbDevice)

        // Don't trigger callbacks for devices attached before the watcher starts
        if !watcher.pointee.isFirstRun && watcher.pointee.fn != LUA_REFNIL && watcher.pointee.fn != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: watcher.pointee.fn)

            lua_newtable(L)
            lua_pushstring(L, "productName")
            lua_pushstring(L, privateDataRef.pointee.productName)
            lua_settable(L, -3)
            lua_pushstring(L, "vendorName")
            lua_pushstring(L, privateDataRef.pointee.vendorName)
            lua_settable(L, -3)
            lua_pushstring(L, "productID")
            lua_pushinteger(L, lua_Integer(privateDataRef.pointee.productID))
            lua_settable(L, -3)
            lua_pushstring(L, "vendorID")
            lua_pushinteger(L, lua_Integer(privateDataRef.pointee.vendorID))
            lua_settable(L, -3)
            lua_pushstring(L, "eventType")
            lua_pushstring(L, "added")
            lua_settable(L, -3)

            skin.protectedCallAndError("hs.usb.watcher:added callback", nargs: 1, nresults: 0)
        }

        usbDevice = IOIteratorNext(iterator)
    }
    _lua_stackguard_exit(L)
}

/// hs.usb.watcher.new(fn) -> watcher
/// Constructor
/// Creates a new watcher for USB device events
///
/// Parameters:
///  * fn - A function that will be called when a USB device is inserted or removed. The function should accept a single parameter, which is a table containing the following keys:
///   * eventType - A string containing either "added" or "removed" depending on whether the USB device was connected or disconnected
///   * productName - A string containing the name of the device
///   * vendorName - A string containing the name of the device vendor
///   * vendorID - A number containing the Vendor ID of the device
///   * productID - A number containing the Product ID of the device
///
/// Returns:
///  * A `hs.usb.watcher` object
private func usb_watcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    luaL_checktype(L, 1, LUA_TFUNCTION)

    let usbwatcher = lua_newuserdata(L, MemoryLayout<USBWatcher>.size)!
        .assumingMemoryBound(to: USBWatcher.self)
    memset(usbwatcher, 0, MemoryLayout<USBWatcher>.size)
    lua_pushvalue(L, 1)

    usbwatcher.pointee.fn = skin.luaRef(refTable)
    usbwatcher.pointee.running = false
    usbwatcher.pointee.gNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
    usbwatcher.pointee.runLoopSource = IONotificationPortGetRunLoopSource(usbwatcher.pointee.gNotifyPort)
    usbwatcher.pointee.lsCanary = skin.createGCCanary()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.usb.watcher:start() -> watcher
/// Method
/// Starts the USB watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.usb.watcher` object
private func usb_watcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let usbwatcher = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: USBWatcher.self)
    lua_settop(L, 1)

    if usbwatcher.pointee.running { return 1 }

    guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
        skin.logBreadcrumb("Unable to create USB watcher matching dictionary")
        return 1
    }

    usbwatcher.pointee.running = true
    usbwatcher.pointee.isFirstRun = true

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       usbwatcher.pointee.runLoopSource?.takeUnretainedValue(),
                       .defaultMode)

    if IOServiceAddMatchingNotification(
        usbwatcher.pointee.gNotifyPort,
        kIOFirstMatchNotification,
        matchingDict,
        DeviceAdded,
        usbwatcher,
        &usbwatcher.pointee.gAddedIter
    ) == KERN_SUCCESS {
        DeviceAdded(refCon: usbwatcher, iterator: usbwatcher.pointee.gAddedIter)
        usbwatcher.pointee.isFirstRun = false
    }

    return 1
}

/// hs.usb.watcher:stop() -> watcher
/// Method
/// Stops the USB watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.usb.watcher` object
private func usb_watcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let usbwatcher = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: USBWatcher.self)
    lua_settop(L, 1)

    if !usbwatcher.pointee.running { return 1 }

    usbwatcher.pointee.running = false
    IOObjectRelease(usbwatcher.pointee.gAddedIter)
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                          usbwatcher.pointee.runLoopSource?.takeUnretainedValue(),
                          .defaultMode)

    return 1
}

private func usb_watcher_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let usbwatcher = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: USBWatcher.self)

    lua_pushcfunction(L, usb_watcher_stop)
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)

    usbwatcher.pointee.fn = skin.luaUnref(refTable, ref: usbwatcher.pointee.fn)
    skin.destroy(&usbwatcher.pointee.lsCanary)

    IONotificationPortDestroy(usbwatcher.pointee.gNotifyPort)

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let str = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, str)
    return 1
}

// Metatable for created objects when _new invoked
private var usb_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"), func: usb_watcher_start),
    luaL_Reg(name: strdup("stop"), func: usb_watcher_stop),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: usb_watcher_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var usbLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: usb_watcher_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libusbwatcher")
public func luaopen_hs_libusbwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &usbLib,
                                    metaFunctions: &meta_gcLib,
                                    objectFunctions: &usb_metalib)
    return 1
}
