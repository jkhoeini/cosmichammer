import Cocoa
import LuaSkin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import IOBluetooth

// Define the private API items of IOBluetooth we will be using
// Taken from https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/IOBluetooth/6.0.2f2/IOBluetoothDevice.h
@objc private protocol IOBluetoothDevicePrivate {
    static func connectedDevices() -> [AnyObject]
    func productID() -> UInt16
    func vendorID() -> UInt16
    func isAppleDevice() -> Bool
    var addressString: String { get }
    var isEnhancedDoubleTapSupported: Bool { get }
    var isANCSupported: Bool { get }
    var isInEarDetectionSupported: Bool { get }
    var batteryPercentCombined: UInt8 { get set }
    var batteryPercentCase: UInt8 { get set }
    var batteryPercentRight: UInt8 { get set }
    var batteryPercentLeft: UInt8 { get set }
    var batteryPercentSingle: UInt8 { get set }
    var primaryBud: UInt8 { get set }
    var rightDoubleTap: UInt8 { get set }
    var leftDoubleTap: UInt8 { get set }
    var buttonMode: UInt8 { get set }
    var micMode: UInt8 { get set }
    var secondaryInEar: UInt8 { get set }
    var primaryInEar: UInt8 { get set }
}

/// hs.battery.timeRemaining() -> number
/// Function
/// Returns the battery life remaining, in minutes
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the minutes of battery life remaining. The value may be:
///   * Greater than zero to indicate the number of minutes remaining
///   * -1 if the remaining battery life is still being calculated
///   * -2 if there is unlimited time remaining (i.e. the system is on AC power)
private func battery_timeremaining(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var remaining = IOPSGetTimeRemainingEstimate()

    if remaining > 0 {
        remaining /= 60
    }

    lua_pushnumber(L, remaining)
    return 1
}

/// hs.battery.powerSource() -> string
/// Function
/// Returns the current source providing power
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing one of {AC Power, Battery Power, UPS Power}.
private func battery_powerSource(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    if let sourcesBlob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
        let sourceType = IOPSGetProvidingPowerSourceType(sourcesBlob)?.takeUnretainedValue() as String?
        skin.pushNSObject(sourceType as NSString?)
        return 1
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "error retrieving power sources info")
        return 2
    }
}

/// hs.battery.warningLevel() -> string
/// Function
/// Returns a string specifying the current battery warning state.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string specifying the current warning level state. The string will be one of "none", "low", or "critical".
///
/// Notes:
///  * The meaning of the return strings is as follows:
///    * "none" - indicates that the system is not in a low battery situation, or is currently attached to an AC power source.
///    * "low"  - the system is in a low battery situation and can provide no more than 20 minutes of runtime. Note that this is a guess only; 20 minutes cannot be guaranteed and will be greatly influenced by what the computer is doing at the time, how many applications are running, screen brightness, etc.
///    * "critical" - the system is in a very low battery situation and can provide no more than 10 minutes of runtime. Note that this is a guess only; 10 minutes cannot be guaranteed and will be greatly influenced by what the computer is doing at the time, how many applications are running, screen brightness, etc.
private func battery_batteryWarningLevel(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let level = IOPSGetBatteryWarningLevel()
    switch level {
    case kIOPSLowBatteryWarningNone:
        lua_pushstring(L, "none")
    case kIOPSLowBatteryWarningEarly:
        lua_pushstring(L, "low")
    case kIOPSLowBatteryWarningFinal:
        lua_pushstring(L, "critical")
    default:
        lua_pushstring(L, "** unrecognized warning level: \(level.rawValue)")
    }
    return 1
}

/// hs.battery.otherBatteryInfo() -> table
/// Function
/// Returns information about non-PSU batteries (e.g. Bluetooth accessories)
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing information about other batteries known to the system, or an empty table if no devices were found
private func battery_others(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    var masterPort: mach_port_t = 0
    var ite: io_iterator_t = 0
    let batteryInfo = NSMutableArray(capacity: 5)

    let kr = IOMainPort(bootstrap_port, &masterPort)
    guard kr == KERN_SUCCESS else {
        NSLog("IOMasterPort() failed: %x\n", kr)
        skin.pushNSObject(batteryInfo)
        return 1
    }

    let krIter = IORegistryCreateIterator(masterPort, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &ite)
    guard krIter == KERN_SUCCESS else {
        skin.pushNSObject(batteryInfo)
        return 1
    }

    var obj = IOIteratorNext(ite)
    while obj != 0 {
        var properties: Unmanaged<CFMutableDictionary>?
        let propKr = IORegistryEntryCreateCFProperties(obj, &properties, kCFAllocatorDefault, 0)

        if propKr == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] {
            if let percent = props["BatteryPercent"] as? NSNumber {
                var s: Int32 = 0
                if CFNumberGetValue(percent as CFNumber, .sInt32Type, &s) {
                    batteryInfo.add(props)
                }
            }
        } else {
            NSLog("IORegistryEntryCreateCFProperties error %x\n", propKr)
            IOObjectRelease(obj)
            break
        }

        IOObjectRelease(obj)
        obj = IOIteratorNext(ite)
    }

    IOObjectRelease(ite)
    skin.pushNSObject(batteryInfo)
    return 1
}

/// hs.battery.privateBluetoothBatteryInfo() -> table
/// Function
/// Returns information about Bluetooth devices using Apple Private APIs
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing information about devices using private Apple APIs.
///
/// Notes:
///  * This function uses private Apple APIs - that means it can break without notice on any macOS version update. Please report breakage to us!
///  * This function will return information for all connected Bluetooth devices, but much of it will be meaningless for most devices
///  * The table contains the following keys:
///    * vendorID - Numerical identifier for the vendor of the device (Apple's ID is 76)
///    * productID - Numerical identifier for the device
///    * address - The Bluetooth address of the device
///    * isApple - A string containing "YES" or "NO", depending on whether or not this is an Apple/Beats product, or a third party product
///    * name - A human readable string containing the name of the device
///    * batteryPercentSingle - For some devices this will contain the percentage of the battery (e.g. Beats headphones)
///    * batteryPercentCombined - We do not currently understand what this field represents, please report if you find a non-zero value here
///    * batteryPercentCase - Battery percentage of AirPods cases (note that this will often read 0 - the AirPod case sleeps aggressively)
///    * batteryPercentLeft - Battery percentage of the left AirPod if it is out of the case
///    * batteryPercentRight - Battery percentage of the right AirPod if it is out of the case
///    * buttonMode - We do not currently understand what this field represents, please report if you find a value other than 1
///    * micMode - For AirPods this corresponds to the microphone option in the device's Bluetooth options
///    * leftDoubleTap - For AirPods this corresponds to the left double tap action in the device's Bluetooth options
///    * rightDoubleTap - For AirPods this corresponds to the right double tap action in the device's Bluetooth options
///    * primaryBud - For AirPods this is either "left" or "right" depending on which bud is currently considered the primary device
///    * primaryInEar - For AirPods this is "YES" or "NO" depending on whether or not the primary bud is currently in an ear
///    * secondaryInEar - For AirPods this is "YES" or "NO" depending on whether or not the secondary bud is currently in an ear
///    * isInEarDetectionSupported - Whether or not this device can detect when it is currently in an ear
///    * isEnhancedDoubleTapSupported - Whether or not this device supports double tapping
///    * isANCSupported - We believe this likely indicates whether or not this device supports Active Noise Cancelling (e.g. Beats Solo)
///  * Please report any crashes from this function - it's likely that there are Bluetooth devices we haven't tested which may return weird data
///  * Many/Most/All non-Apple party products will likely return zeros for all of the battery related fields here, as will Apple HID devices. It seems that these private APIs mostly exist to support Apple/Beats headphones.
private func battery_private(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let privateInfo = NSMutableArray()

    let connectedSel = NSSelectorFromString("connectedDevices")
    guard let devices = IOBluetoothDevice.perform(connectedSel)?.takeUnretainedValue() as? [IOBluetoothDevice] else {
        skin.pushNSObject(privateInfo)
        return 1
    }

    for device in devices {
        let deviceInfo = NSMutableDictionary()
        guard let priv = device as AnyObject as? IOBluetoothDevicePrivate else { continue }

        deviceInfo["name"] = device.name ?? ""
        deviceInfo["vendorID"] = "\(priv.vendorID())"
        deviceInfo["productID"] = "\(priv.productID())"
        deviceInfo["isApple"] = priv.isAppleDevice() ? "YES" : "NO"
        deviceInfo["address"] = (device as IOBluetoothDevice).addressString

        deviceInfo["buttonMode"] = "\(priv.buttonMode)"

        deviceInfo["batteryPercentCombined"] = "\(priv.batteryPercentCombined)"
        deviceInfo["batteryPercentSingle"] = "\(priv.batteryPercentSingle)"

        deviceInfo["batteryPercentCase"] = "\(priv.batteryPercentCase)"
        deviceInfo["batteryPercentRight"] = "\(priv.batteryPercentRight)"
        deviceInfo["batteryPercentLeft"] = "\(priv.batteryPercentLeft)"

        deviceInfo["primaryBud"] = priv.primaryBud == 1 ? "left" : "right"
        deviceInfo["isInEarDetectionSupported"] = priv.isInEarDetectionSupported ? "YES" : "NO"
        deviceInfo["secondaryInEar"] = priv.secondaryInEar != 0 ? "NO" : "YES"
        deviceInfo["primaryInEar"] = priv.primaryInEar != 0 ? "NO" : "YES"

        deviceInfo["isEnhancedDoubleTapSupported"] = priv.isEnhancedDoubleTapSupported ? "YES" : "NO"
        deviceInfo["rightDoubleTap"] = "\(priv.rightDoubleTap)"
        deviceInfo["leftDoubleTap"] = "\(priv.leftDoubleTap)"

        deviceInfo["micMode"] = "\(priv.micMode)"
        deviceInfo["isANCSupported"] = priv.isANCSupported ? "YES" : "NO"

        privateInfo.add(deviceInfo)
    }
    skin.pushNSObject(privateInfo)
    return 1
}

private func battery_externalAdapterDetails(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    if let psuInfo = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() {
        skin.pushNSObject(psuInfo as NSDictionary, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func battery_powerSources(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    guard let sourcesBlob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
        lua_pushnil(L)
        lua_pushstring(L, "error retrieving power sources info")
        return 2
    }

    guard let sourcesList = IOPSCopyPowerSourcesList(sourcesBlob)?.takeRetainedValue() as? [CFTypeRef] else {
        lua_pushnil(L)
        lua_pushstring(L, "error retrieving power sources list")
        return 2
    }

    lua_newtable(L)
    for i in 0..<sourcesList.count {
        if let powerSource = IOPSGetPowerSourceDescription(sourcesBlob, sourcesList[i])?.takeUnretainedValue() as? NSDictionary {
            skin.pushNSObject(powerSource, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
        } else {
            skin.pushNSObject("unable to get description of power source \(i + 1)" as NSString)
        }
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

private func battery_appleSmartBattery(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
    if entry != 0 {
        var battery: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(entry, &battery, nil, 0)
        if let batteryDict = battery?.takeRetainedValue() as? NSDictionary {
            skin.pushNSObject(batteryDict, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
        } else {
            lua_pushnil(L)
        }
        IOObjectRelease(entry)
        return 1
    } else {
        lua_pushnil(L)
        lua_pushstring(L, "unable to retrieve AppleSmartBattery IOService")
        return 2
    }
}

private func battery_iopmBatteryInfo(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    var masterPort: mach_port_t = 0
    var batteryInfo: Unmanaged<CFArray>?

    guard IOMainPort(mach_port_t(MACH_PORT_NULL), &masterPort) == kIOReturnSuccess else {
        lua_pushnil(L)
        lua_pushstring(L, "unable to get IO Master Port")
        return 2
    }

    guard IOPMCopyBatteryInfo(masterPort, &batteryInfo) == kIOReturnSuccess else {
        batteryInfo?.release()
        lua_pushnil(L)
        lua_pushstring(L, "unable to get IOPM Battery Info")
        return 2
    }

    if let info = batteryInfo?.takeRetainedValue() as? NSArray {
        skin.pushNSObject(info)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private var battery_lib: [luaL_Reg] = [
    luaL_Reg(name: strdup("timeRemaining"),               func: battery_timeremaining),
    luaL_Reg(name: strdup("powerSource"),                 func: battery_powerSource),
    luaL_Reg(name: strdup("otherBatteryInfo"),            func: battery_others),
    luaL_Reg(name: strdup("privateBluetoothBatteryInfo"), func: battery_private),
    luaL_Reg(name: strdup("warningLevel"),                func: battery_batteryWarningLevel),
    luaL_Reg(name: strdup("_adapterDetails"),             func: battery_externalAdapterDetails),
    luaL_Reg(name: strdup("_powerSources"),               func: battery_powerSources),
    luaL_Reg(name: strdup("_appleSmartBattery"),          func: battery_appleSmartBattery),
    luaL_Reg(name: strdup("_iopmBatteryInfo"),            func: battery_iopmBatteryInfo),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libbattery")
public func luaopen_hs_libbattery(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.battery", functions: &battery_lib, metaFunctions: nil)
    return 1
}
