import Cocoa
import LuaSkin
import IOKit
import IOKit.hid
import os.log

// We need a mutable array and a callback outside HSmouse so they can be used at the IOKit level
private var mice: NSMutableArray? = nil

private let enum_callback: IOHIDDeviceCallback = { context, result, sender, device in
    guard result == kIOReturnSuccess else { return }

    var vendor = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
    var product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String

    if vendor == nil { vendor = "Unknown vendor" }
    if product == nil { product = "Unknown mouse" }

    mice?.add("\(vendor!)::\(product!)")
}

// MARK: - HSmouse class
private class HSmouse {
    private static let RUNLOOPMODE = CFRunLoopMode("hs.mouse" as CFString)
    private static let MOUSE_TRACKING_FACTOR: Double = 65536

    var hasInternalMouse: Bool {
        for name in getNames() {
            if name.contains("Apple Internal") {
                return true
            }
        }
        return false
    }

    var count: Int {
        return getNames().count
    }

    // MARK: Mouse enumeration
    func getNames() -> [String] {
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ]

        let hidman = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerRegisterDeviceMatchingCallback(hidman, enum_callback, nil)
        IOHIDManagerScheduleWithRunLoop(hidman, CFRunLoopGetCurrent(), HSmouse.RUNLOOPMODE.rawValue)
        IOHIDManagerSetDeviceMatching(hidman, matchingDict as CFDictionary)
        IOHIDManagerOpen(hidman, IOOptionBits(kIOHIDOptionsTypeNone))

        mice = NSMutableArray()

        // Run a sub-runloop until the initial enumeration of mice is completed
        while CFRunLoopRunInMode(HSmouse.RUNLOOPMODE, 0, true) == .handledSource {
            // Do nothing
        }

        // Remove our callback and unschedule from the runloop
        IOHIDManagerRegisterDeviceMatchingCallback(hidman, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(hidman, CFRunLoopGetCurrent(), HSmouse.RUNLOOPMODE.rawValue)
        IOHIDManagerClose(hidman, IOOptionBits(kIOHIDOptionsTypeNone))

        return (mice as? [String]) ?? []
    }

    // MARK: Mouse position
    var absolutePosition: NSPoint {
        get {
            let ourEvent = CGEvent(source: nil)!
            let point = ourEvent.location
            return point
        }
        set {
            CGWarpMouseCursorPosition(newValue)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: HID parameters
    var isScrollDirectionNatural: Bool {
        return UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
    }

    private func createIOHIDSystem() -> io_service_t {
        return IORegistryEntryFromPath(kIOMainPortDefault, kIOServicePlane + ":/IOResources/IOHIDSystem")
    }

    private func getIOHIDParameters(from service: io_service_t) -> NSDictionary? {
        return IORegistryEntryCreateCFProperty(service, kIOHIDParametersKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary
    }

    private func getIOHIDParameters() -> NSDictionary? {
        let service = createIOHIDSystem()
        let parameters = getIOHIDParameters(from: service)
        IOObjectRelease(service)
        return parameters
    }

    private func getTrackingSpeed(forKey key: String) -> Double {
        var speed: Double = 0
        IOHIDGetAccelerationWithKey(NXOpenEventStatus(), key as CFString, &speed)
        return speed
    }

    var trackingSpeed: Double {
        return getTrackingSpeed(forKey: kIOHIDMouseAccelerationType)
    }

    var trackpadTrackingSpeed: Double {
        return getTrackingSpeed(forKey: kIOHIDTrackpadAccelerationType)
    }

    @discardableResult
    private func setTrackingSpeed(_ trackingSpeed: Double, forKey key: String) -> kern_return_t {
        return IOHIDSetAccelerationWithKey(NXOpenEventStatus(), key as CFString, trackingSpeed)
    }

    @discardableResult
    func setTrackingSpeed(_ trackingSpeed: Double) -> kern_return_t {
        return setTrackingSpeed(trackingSpeed, forKey: kIOHIDMouseAccelerationType)
    }

    @discardableResult
    func setTrackpadTrackingSpeed(_ trackingSpeed: Double) -> kern_return_t {
        return setTrackingSpeed(trackingSpeed, forKey: kIOHIDTrackpadAccelerationType)
    }
}

/// hs.mouse.count([includeInternal]) -> number
/// Function
/// Gets the total number of mice connected to your system.
///
/// Parameters:
///  * includeInternal - A boolean which sets whether or not you want to include internal Trackpad's in the count. Defaults to false.
///
/// Returns:
///  * The number of mice connected to your system
///
/// Notes:
///  * This function leverages code from [ManyMouse](http://icculus.org/manymouse/).
///  * This function considers any mouse labelled as "Apple Internal Keyboard / Trackpad" to be an internal mouse.
private func mouse_count(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let includeInternal = lua_toboolean(L, 1) != 0

    let mouseManager = HSmouse()
    var mouseCount = mouseManager.count

    if !includeInternal && mouseManager.hasInternalMouse {
        mouseCount -= 1
    }

    lua_pushinteger(L, lua_Integer(mouseCount))
    return 1
}

/// hs.mouse.names() -> table
/// Function
/// Gets the names of any mice connected to the system.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing strings of all the mice connected to the system.
///
/// Notes:
///  * This function leverages code from [ManyMouse](http://icculus.org/manymouse/).
private func mouse_names(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let mouseManager = HSmouse()

    lua_pushany(L, mouseManager.getNames() as NSArray)
    return 1
}

/// hs.mouse.absolutePosition([point]) -> point
/// Function
/// Get or set the absolute co-ordinates of the mouse pointer
///
/// Parameters:
///  * An optional point table containing the absolute x and y co-ordinates to move the mouse pointer to
///
/// Returns:
///  * A point table containing the absolute x and y co-ordinates of the mouse pointer
///
/// Notes:
///  * If no parameters are supplied, the current position will be returned. If a point table parameter is supplied, the mouse pointer position will be set and the new co-ordinates returned
private func mouse_absolutePosition(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let mouseManager = HSmouse()

    if lua_type(L, 1) == LUA_TTABLE {
        let point = lua_tableToPoint(L, at: 1)
        mouseManager.absolutePosition = point
    }

    lua_pushNSPoint(L, mouseManager.absolutePosition)
    return 1
}

/// hs.mouse.trackingSpeed([speed], [trackpad]) -> number
/// Function
/// Gets/Sets the current system mouse or trackpad tracking speed setting
///
/// Parameters:
///  * speed - An optional number containing the new tracking speed to set. If this is omitted, the current setting is returned
///  * trackpad - An optional boolean, default false, indicating whether or not this function affects the mouse tracking speed (false) or the trackpad tracking speed (true)
///
/// Returns:
///  * A number indicating the current tracking speed setting for mouse or trackpad
///
/// Notes:
///  * This is represented in the System Preferences as the "Tracking speed" setting for Mouse or Trackpad
///  * Note that not all values will work, they should map to the steps defined in the System Preferences app, which are:
///    * 0.0, 0.125, 0.5, 0.6875, 0.875, 1.0, 1.5, 2.0, 2.5, 3.0
///  * Note that changes to this value will not be noticed immediately by macOS
private func mouse_mouseAcceleration(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let mouseManager = HSmouse()

    var isTrackpad = false
    if lua_gettop(L) > 0 {
        isTrackpad = (lua_type(L, -1) != LUA_TNUMBER) ? (lua_toboolean(L, -1) != 0) : false
    }

    if lua_type(L, 1) == LUA_TNUMBER {
        let result = isTrackpad ? mouseManager.setTrackpadTrackingSpeed(lua_tonumber(L, 1))
                                : mouseManager.setTrackingSpeed(lua_tonumber(L, 1))

        if result != KERN_SUCCESS {
            os_log(.error, "Unable to set %{public}@ tracking speed: %d",
                   isTrackpad ? "trackpad" : "mouse", result)
        }
    }

    lua_pushnumber(L, isTrackpad ? mouseManager.trackpadTrackingSpeed : mouseManager.trackingSpeed)
    return 1
}

/// hs.mouse.scrollDirection() -> string
/// Function
/// Gets the system-wide direction of scrolling
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string, either "natural" or "normal"
private func mouse_scrollDirection(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let mouseManager = HSmouse()

    lua_pushstring(L, mouseManager.isScrollDirectionNatural ? "natural" : "normal")
    return 1
}

/// hs.mouse.currentCursorType() -> string
/// Function
/// Gets the identifier of the current mouse cursor type.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string.
///
/// Notes:
///  * Possible values include: arrowCursor, contextualMenuCursor, closedHandCursor, crosshairCursor, disappearingItemCursor, dragCopyCursor, dragLinkCursor, IBeamCursor, operationNotAllowedCursor, pointingHandCursor, resizeDownCursor, resizeLeftCursor, resizeLeftRightCursor, resizeRightCursor, resizeUpCursor, resizeUpDownCursor, IBeamCursorForVerticalLayout or unknown if the cursor type cannot be determined.
///  * This function can also return daVinciResolveHorizontalArrows, when hovering over mouse-draggable text-boxes in DaVinci Resolve. This is determined using the "hotspot" value of the cursor.
private func mouse_currentCursorType(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var value = "unknown"

    guard let currentCursor = NSCursor.currentSystem else {
        lua_pushstring(L, value)
        return 1
    }

    let currentCursorData = currentCursor.image.tiffRepresentation

    // NOTE: Whilst you can just compare [NSCursor currentCursor] values using ==, the same is not true for [NSCursor currentSystemCursor],
    //       for some weird reason, hence why the only solution I could come up with was to compare the image data.
    let cursorChecks: [(NSCursor, String)] = [
        (.arrow, "arrowCursor"),
        (.contextualMenu, "contextualMenuCursor"),
        (.closedHand, "closedHandCursor"),
        (.crosshair, "crosshairCursor"),
        (.disappearingItem, "disappearingItemCursor"),
        (.dragCopy, "dragCopyCursor"),
        (.dragLink, "dragLinkCursor"),
        (.iBeam, "IBeamCursor"),
        (.operationNotAllowed, "operationNotAllowedCursor"),
        (.pointingHand, "pointingHandCursor"),
        (.resizeDown, "resizeDownCursor"),
        (.resizeLeft, "resizeLeftCursor"),
        (.resizeLeftRight, "resizeLeftRightCursor"),
        (.resizeRight, "resizeRightCursor"),
        (.resizeUp, "resizeUpCursor"),
        (.resizeUpDown, "resizeUpDownCursor"),
        (.iBeamCursorForVerticalLayout, "IBeamCursorForVerticalLayout"),
    ]

    var matched = false
    for (cursor, name) in cursorChecks {
        if currentCursorData == cursor.image.tiffRepresentation {
            value = name
            matched = true
            break
        }
    }

    if !matched {
        // This is a very non-eloquent solution for detecting custom cursors:
        let hotSpot = currentCursor.hotSpot
        if hotSpot.x == 11 && hotSpot.y == 6 {
            value = "daVinciResolveHorizontalArrows"
        }
    }

    lua_pushstring(L, value)
    return 1
}

// Note to future authors, there is no function to use kIOHIDTrackpadAccelerationType because it doesn't appear to do anything on modern systems.

private var mouseLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("absolutePosition"), func: mouse_absolutePosition),
    luaL_Reg(name: strdup("trackingSpeed"), func: mouse_mouseAcceleration),
    luaL_Reg(name: strdup("scrollDirection"), func: mouse_scrollDirection),
    luaL_Reg(name: strdup("currentCursorType"), func: mouse_currentCursorType),
    luaL_Reg(name: strdup("count"), func: mouse_count),
    luaL_Reg(name: strdup("names"), func: mouse_names),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libmouse")
public func luaopen_hs_libmouse(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_createtable(L, 0, Int32(mouseLib.count - 1))
    luaL_setfuncs(L, &mouseLib, 0)
    return 1
}
