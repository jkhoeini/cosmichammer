import Foundation
import CLua
import Lua
import Cocoa
import IOKit
import IOKit.usb
import os.log

// kIOMessageServiceIsTerminated is a C macro not bridged to Swift
private let kIOMessageServiceIsTerminated: UInt32 = 0xE000_0010

/// === hs.usb.watcher ===
///
/// Watch for USB device connection/disconnection events

private let USERDATA_TAG = "hs.usb.watcher"
private var refTable: Int32 = 0

/// Module-level map from userdata pointer to LuaValue callback.
/// We cannot store a LuaValue (class) inside a struct that lives in
/// lua_newuserdata raw memory, so we keep the association here.
private var callbackMap: [UnsafeMutableRawPointer: LuaValue] = [:]

// Userdata object for each watcher
private struct USBWatcher {
    var running: Bool
    var isFirstRun: Bool
    var gNotifyPort: IONotificationPortRef?
    var gAddedIter: io_iterator_t
    var runLoopSource: Unmanaged<CFRunLoopSource>?
    var generation: UInt64
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
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(watcher.pointee.generation) else { return }

        if let cb = callbackMap[UnsafeMutableRawPointer(watcher)] {
            cb.push(onto: L)

            lua_newtable(L)
            L.push("productName")
            L.push(String(cString: privateDataRef.pointee.productName!))
            lua_settable(L, -3)
            L.push("vendorName")
            L.push(String(cString: privateDataRef.pointee.vendorName!))
            lua_settable(L, -3)
            L.push("productID")
            L.push(Int(privateDataRef.pointee.productID))
            lua_settable(L, -3)
            L.push("vendorID")
            L.push(Int(privateDataRef.pointee.vendorID))
            lua_settable(L, -3)
            L.push("eventType")
            L.push("removed")
            lua_settable(L, -3)

            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                lua_pop(L, 1)
            }
        }

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
    }
}

// Iterate over new devices
private func DeviceAdded(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    let watcher = refCon!.assumingMemoryBound(to: USBWatcher.self)
    guard lua_isStateGenerationValid(watcher.pointee.generation) else {
        while IOIteratorNext(iterator) != IO_OBJECT_NULL {}
        return
    }
    let L = lua_getCurrentState()!

    var usbDevice = IOIteratorNext(iterator)
    while usbDevice != 0 {
        let privateDataRef = UnsafeMutablePointer<USBPrivData>.allocate(capacity: 1)
        privateDataRef.initialize(to: USBPrivData(
            watcher: watcher, notification: 0, productName: nil,
            vendorName: nil, productID: 0, vendorID: 0
        ))

        var deviceData: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(usbDevice, &deviceData, kCFAllocatorDefault, 0)

        if let dict = deviceData?.takeRetainedValue() as? [String: Any] {
            let productName = (dict[kUSBProductString] as? String) ?? ""
            let length = productName.utf8.count + 1
            privateDataRef.pointee.productName = UnsafeMutablePointer<CChar>.allocate(capacity: length)
            _ = productName.withCString { src in strcpy(privateDataRef.pointee.productName!, src) }

            let vendorName = (dict[kUSBVendorString] as? String) ?? ""
            let vLength = vendorName.utf8.count + 1
            privateDataRef.pointee.vendorName = UnsafeMutablePointer<CChar>.allocate(capacity: vLength)
            _ = vendorName.withCString { src in strcpy(privateDataRef.pointee.vendorName!, src) }

            privateDataRef.pointee.productID = Int32((dict[kUSBProductID] as? NSNumber)?.intValue ?? 0)
            privateDataRef.pointee.vendorID = Int32((dict[kUSBVendorID] as? NSNumber)?.intValue ?? 0)
        }

        let kr = IOServiceAddInterestNotification(
            watcher.pointee.gNotifyPort, usbDevice, kIOGeneralInterest,
            DeviceNotification, privateDataRef, &privateDataRef.pointee.notification
        )
        if kr != KERN_SUCCESS {
            os_log(.error, "IOServiceAddInterestNotification returned 0x%08x", kr)
        }

        IOObjectRelease(usbDevice)

        if !watcher.pointee.isFirstRun, let cb = callbackMap[UnsafeMutableRawPointer(watcher)] {
            cb.push(onto: L)

            lua_newtable(L)
            L.push("productName")
            L.push(String(cString: privateDataRef.pointee.productName!))
            lua_settable(L, -3)
            L.push("vendorName")
            L.push(String(cString: privateDataRef.pointee.vendorName!))
            lua_settable(L, -3)
            L.push("productID")
            L.push(Int(privateDataRef.pointee.productID))
            lua_settable(L, -3)
            L.push("vendorID")
            L.push(Int(privateDataRef.pointee.vendorID))
            lua_settable(L, -3)
            L.push("eventType")
            L.push("added")
            lua_settable(L, -3)

            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                lua_pop(L, 1)
            }
        }

        usbDevice = IOIteratorNext(iterator)
    }
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
private func usb_watcher_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let usbwatcher = lua_newuserdata(L, MemoryLayout<USBWatcher>.size)!
        .assumingMemoryBound(to: USBWatcher.self)
    memset(usbwatcher, 0, MemoryLayout<USBWatcher>.size)

    callbackMap[UnsafeMutableRawPointer(usbwatcher)] = L.ref(index: 1)

    usbwatcher.pointee.running = false
    usbwatcher.pointee.gNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
    usbwatcher.pointee.runLoopSource = IONotificationPortGetRunLoopSource(usbwatcher.pointee.gNotifyPort)
    usbwatcher.pointee.generation = lua_currentStateGeneration()

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
private func usb_watcher_start(_ L: LuaState) throws -> CInt {
    let usbwatcher = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: USBWatcher.self)
    lua_settop(L, 1)

    if usbwatcher.pointee.running { return 1 }

    guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
        os_log(.error, "Unable to create USB watcher matching dictionary")
        return 1
    }

    usbwatcher.pointee.running = true
    usbwatcher.pointee.isFirstRun = true

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       usbwatcher.pointee.runLoopSource?.takeUnretainedValue(),
                       .defaultMode)

    if IOServiceAddMatchingNotification(
        usbwatcher.pointee.gNotifyPort, kIOFirstMatchNotification,
        matchingDict, DeviceAdded, usbwatcher, &usbwatcher.pointee.gAddedIter
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
private func usb_watcher_stop(_ L: LuaState) throws -> CInt {
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

@_cdecl("luaopen_hs_libusbwatcher")
public func luaopen_hs_libusbwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        L.push(usb_watcher_start)
        lua_setfield(L, -2, "start")

        L.push(usb_watcher_stop)
        lua_setfield(L, -2, "stop")

        // __gc: stop watcher, clean up callback, destroy notification port
        L.push { (L: LuaState) throws -> CInt in
            let usbwatcher = luaL_checkudata(L, 1, USERDATA_TAG)!
                .assumingMemoryBound(to: USBWatcher.self)

            if usbwatcher.pointee.running {
                usbwatcher.pointee.running = false
                IOObjectRelease(usbwatcher.pointee.gAddedIter)
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                      usbwatcher.pointee.runLoopSource?.takeUnretainedValue(),
                                      .defaultMode)
            }

            callbackMap[UnsafeMutableRawPointer(usbwatcher)] = nil
            IONotificationPortDestroy(usbwatcher.pointee.gNotifyPort)

            return 0
        }
        lua_setfield(L, -2, "__gc")

        // __tostring
        L.push { (L: LuaState) throws -> CInt in
            let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
            L.push(desc)
            return 1
        }
        lua_setfield(L, -2, "__tostring")

        // __type and __name for lsunit.lua assertIsUserdataOfType
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(usb_watcher_new)
        lua_setfield(L, -2, "new")
    }
}
