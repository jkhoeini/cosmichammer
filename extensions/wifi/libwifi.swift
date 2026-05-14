import Cocoa
import CoreWLAN
import LuaSkin

private let USERDATA_TAG = "hs.wifi"
private var refTable: Int32 = LUA_NOREF

// MARK: - Support Functions

private func get_wifi_interface(_ theInterface: String?) -> CWInterface? {
    let sharedClient = CWWiFiClient.shared()
    if let name = theInterface {
        return sharedClient.interface(withName: name)
    }
    return sharedClient.interface()
}

// MARK: - HSWifiScan

private class HSWifiScan: NSObject {
    var fnRef: Int32
    var isDone: Bool = false

    init(callback fnReference: Int32, onInterface interface: String?) {
        self.fnRef = fnReference
        self.isDone = false
        super.init()
        self.performSelector(inBackground: #selector(doBackgroundScan(_:)),
                             with: interface as NSString?)
    }

    @objc func doBackgroundScan(_ object: Any?) {
        let theInterface = object as? String

        var theError: NSError?
        let interface = get_wifi_interface(theInterface)
        var availableNetworks: Set<CWNetwork>?
        do {
            availableNetworks = try interface?.scanForNetworks(withName: nil)
        } catch let error as NSError {
            theError = error
        }
        isDone = true
        if let error = theError {
            self.performSelector(onMainThread: #selector(invokeCallback(_:)),
                                 with: error, waitUntilDone: false)
        } else {
            self.performSelector(onMainThread: #selector(invokeCallback(_:)),
                                 with: availableNetworks, waitUntilDone: false)
        }
    }

    @objc func invokeCallback(_ object: Any?) {
        if fnRef != LUA_NOREF {
            let skin = LuaSkin.shared(withState: nil)!
            _lua_stackguard_entry(skin.L)
            skin.pushLuaRef(refTable, ref: fnRef)
            if let error = object as? NSError {
                skin.logInfo(error.localizedDescription)
                skin.pushNSObject(error.localizedDescription as NSString)
            } else if let networks = object as? Set<CWNetwork> {
                skin.pushNSObject(networks as NSSet)
            } else {
                lua_pushnil(skin.L)
            }
            skin.protectedCallAndError("hs.wifi callback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(skin.L)
        }
    }
}

// MARK: - Module Functions

/// hs.wifi.setPower(state, [interface]) -> boolean
/// Function
/// Turns a wifi interface on or off
///
/// Parameters:
///  * state - a boolean value indicating if the Wifi device should be powered on (true) or off (false).
///  * interface - an optional interface name as listed in the results of [hs.wifi.interfaces](#interfaces).  If not present, the interface defaults to the systems default WLAN device.
///
/// Returns:
///  * True if the power change was successful, or false and an error string if an error occurred attempting to set the power state.  Returns nil if there is a problem attaching to the interface.
private func setPower(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBOOLEAN, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let powerState = lua_toboolean(L, 1) != 0
    var theName: String?
    if lua_gettop(L) == 2 {
        theName = String(cString: luaL_checkstring(L, 2))
    }

    guard let interface = get_wifi_interface(theName) else {
        lua_pushnil(L)
        return 1
    }

    do {
        try interface.setPower(powerState)
        lua_pushboolean(L, 1)
    } catch let error as NSError {
        lua_pushboolean(L, 0)
        lua_pushstring(L, error.localizedDescription)
        return 2
    }

    return 1
}

/// hs.wifi.disassociate([interface]) -> nil
/// Function
/// Disconnect the interface from its current network.
///
/// Parameters:
///  * interface - an optional interface name as listed in the results of [hs.wifi.interfaces](#interfaces).  If not present, the interface defaults to the systems default WLAN device.
///
/// Returns:
///  * None
private func disassociate(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    var theName: String?
    if lua_gettop(L) == 1 {
        theName = String(cString: luaL_checkstring(L, 1))
    }

    let interface = get_wifi_interface(theName)
    interface?.disassociate()
    return 0
}

/// hs.wifi.associate(network, passphrase[, interface]) -> boolean
/// Function
/// Connect the interface to a wireless network
///
/// Parameters:
///  * network - A string containing the SSID of the network to associate to
///  * passphrase - A string containing the passphrase of the network
///  * interface - An optional string containing the name of an interface (see [hs.wifi.interfaces](#interfaces)). If not present, the default system WLAN device will be used
///
/// Returns:
///  * A boolean, true if the network was joined successfully, false if an error occurred
///
/// Notes:
///  * Enterprise WiFi networks are not currently supported. Please file an issue on GitHub if you need support for enterprise networks
///  * This function blocks Hammerspoon until the operation is completed
///  * If multiple access points are available with the same SSID, one will be chosen at random to connect to
private func associate(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    var success = false
    var interfaceName: String?

    if lua_type(L, 3) == LUA_TSTRING {
        interfaceName = skin.toNSObject(atIndex: 3) as? String
    }

    let interface = get_wifi_interface(interfaceName)
    let ssid = skin.toNSObject(atIndex: 1) as? String
    let networks = try? interface?.scanForNetworks(withName: ssid)
    if let network = networks?.first {
        let password = skin.toNSObject(atIndex: 2) as? String ?? ""
        success = (try? interface?.associate(toNetwork: network, password: password)) != nil
    }

    lua_pushboolean(L, success ? 1 : 0)
    return 1
}

/// hs.wifi.interfaces() -> table
/// Function
/// Returns a list of interface names for WLAN devices attached to the system
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the names of all WLAN interfaces for this system.
///
/// Notes:
///  * For most systems, this will be one interface, but the result is still returned as an array.
private func wifi_interfaces(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)
    let sharedClient = CWWiFiClient.shared()
    if let names = sharedClient.interfaceNames() {
        skin.pushNSObject(names as NSSet)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.wifi.availableNetworks([interface]) -> table
/// Function
/// Gets a list of available WiFi networks
///
/// Parameters:
///  * interface - an optional interface name as listed in the results of [hs.wifi.interfaces](#interfaces).  If not present, the interface defaults to the systems default WLAN device.
///
/// Returns:
///  * A table containing the names of all visible WiFi networks
///
/// Notes:
///  * WARNING: This function will block all Lua execution until the scan has completed. It's probably not very sensible to use this function very much, if at all.
private func wifi_scan(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    var theName: String?
    if lua_gettop(L) == 1 {
        theName = String(cString: luaL_checkstring(L, 1))
    }

    let interface = get_wifi_interface(theName)
    guard let availableNetworks = try? interface?.scanForNetworks(withName: nil) else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    var i: lua_Integer = 1
    for network in availableNetworks {
        lua_pushinteger(L, i)
        i += 1
        lua_pushstring(L, network.ssid ?? "")
        lua_settable(L, -3)
    }

    return 1
}

/// hs.wifi.backgroundScan(fn, [interface]) -> scanObject
/// Constructor
/// Perform a scan for available wifi networks in the background (non-blocking)
///
/// Parameters:
///  * fn        - the function to callback when the scan is completed.
///  * interface - an optional interface name as listed in the results of [hs.wifi.interfaces](#interfaces).  If not present, the interface defaults to the systems default WLAN device.
///
/// Returns:
///  * returns a scan object
private func wifi_scan_background(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TFUNCTION | LS_TNIL, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    var callbackRef: Int32 = LUA_NOREF
    if lua_type(L, 1) != LUA_TNIL {
        lua_pushvalue(L, 1)
        callbackRef = skin.luaRef(refTable)
    }

    var theName: String?
    if lua_gettop(L) == 2 {
        theName = String(cString: luaL_checkstring(L, 2))
    }

    let scanner = HSWifiScan(callback: callbackRef, onInterface: theName)
    let scannerPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    scannerPtr.pointee = Unmanaged.passRetained(scanner).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.wifi.currentNetwork([interface]) -> string or nil
/// Function
/// Gets the name of the current WiFi network
///
/// Parameters:
///  * interface - an optional interface name as listed in the results of [hs.wifi.interfaces](#interfaces).  If not present, the interface defaults to the systems default WLAN device.
///
/// Returns:
///  * A string containing the SSID of the WiFi network currently joined, or nil if no there is no WiFi connection
private func wifi_current_ssid(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    var theName: String?
    if lua_gettop(L) == 1 {
        theName = String(cString: luaL_checkstring(L, 1))
    }

    let interface = get_wifi_interface(theName)
    if let ssid = interface?.ssid() {
        lua_pushstring(L, ssid)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.wifi.interfaceDetails([interface]) -> table
/// Function
/// Returns a table containing details about the wireless interface.
///
/// Parameters:
///  * interface - an optional interface name as listed in the results of [hs.wifi.interfaces](#interfaces).  If not present, the interface defaults to the systems default WLAN device.
///
/// Returns:
///  * A table containing details about the interface.
private func interfaceDetails(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    var theName: String?
    if lua_gettop(L) == 1 {
        theName = String(cString: luaL_checkstring(L, 1))
    }

    let interface = get_wifi_interface(theName)
    if let iface = interface {
        skin.pushNSObject(iface)
    } else {
        lua_pushnil(L)
    }

    return 1
}

// MARK: - Module Object Methods

/// hs.wifi:isDone() -> boolean
/// Method
/// Returns whether or not a scan object has completed its scan for wireless networks.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not the scan has been completed.
private func backgroundScanIsDone(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let scannerPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let scanner = Unmanaged<HSWifiScan>.fromOpaque(scannerPtr.pointee!).takeUnretainedValue()
    lua_pushboolean(L, scanner.isDone ? 1 : 0)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushCWInterface(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let theInterface = obj as! CWInterface
    lua_newtable(L)

    skin.pushNSObject(theInterface.wlanChannel())
    lua_setfield(L, -2, "wlanChannel")
    lua_pushnumber(L, lua_Number(theInterface.transmitRate()))
    lua_setfield(L, -2, "transmitRate")
    lua_pushinteger(L, lua_Integer(theInterface.transmitPower()))
    lua_setfield(L, -2, "transmitPower")
    skin.pushNSObject(theInterface.supportedWLANChannels() as NSSet?)
    lua_setfield(L, -2, "supportedChannels")
    skin.pushNSObject(theInterface.ssidData() as NSData?)
    lua_setfield(L, -2, "ssidData")
    skin.pushNSObject(theInterface.ssid() as NSString?)
    lua_setfield(L, -2, "ssid")
    lua_pushboolean(L, theInterface.serviceActive() ? 1 : 0)
    lua_setfield(L, -2, "active")

    let securityStr: String
    switch theInterface.security() {
    case .none:                securityStr = "None"
    case .WEP:                 securityStr = "WEP"
    case .wpaPersonal:         securityStr = "WPA Personal"
    case .wpaPersonalMixed:    securityStr = "WPA Personal Mixed"
    case .wpa2Personal:        securityStr = "WPA2 Personal"
    case .personal:            securityStr = "Personal"
    case .dynamicWEP:          securityStr = "Dynamic WEP"
    case .wpaEnterprise:       securityStr = "WPA Enterprise"
    case .wpaEnterpriseMixed:  securityStr = "WPA Enterprise Mixed"
    case .wpa2Enterprise:      securityStr = "WPA2 Enterprise"
    case .enterprise:          securityStr = "Enterprise"
    case .unknown:             securityStr = "Unknown"
    @unknown default:          securityStr = "unrecognized (\(theInterface.security().rawValue))"
    }
    lua_pushstring(L, securityStr)
    lua_setfield(L, -2, "security")

    lua_pushinteger(L, lua_Integer(theInterface.rssiValue()))
    lua_setfield(L, -2, "rssi")
    lua_pushboolean(L, theInterface.powerOn() ? 1 : 0)
    lua_setfield(L, -2, "power")
    lua_pushinteger(L, lua_Integer(theInterface.noiseMeasurement()))
    lua_setfield(L, -2, "noise")
    skin.pushNSObject(theInterface.interfaceName as NSString?)
    lua_setfield(L, -2, "interface")

    let modeStr: String
    switch theInterface.interfaceMode() {
    case .none:    modeStr = "None"
    case .station: modeStr = "Station"
    case .IBSS:    modeStr = "IBSS"
    case .hostAP:  modeStr = "Host AP"
    @unknown default: modeStr = "unrecognized (\(theInterface.interfaceMode().rawValue))"
    }
    lua_pushstring(L, modeStr)
    lua_setfield(L, -2, "interfaceMode")

    skin.pushNSObject(theInterface.hardwareAddress() as NSString?)
    lua_setfield(L, -2, "hardwareAddress")
    skin.pushNSObject(theInterface.countryCode() as NSString?)
    lua_setfield(L, -2, "countryCode")
    skin.pushNSObject(theInterface.configuration())
    lua_setfield(L, -2, "configuration")
    skin.pushNSObject(theInterface.cachedScanResults() as NSSet?)
    lua_setfield(L, -2, "cachedScanResults")
    skin.pushNSObject(theInterface.bssid() as NSString?)
    lua_setfield(L, -2, "bssid")

    let phyStr: String
    switch theInterface.activePHYMode() {
    case .modeNone: phyStr = "None"
    case .mode11a:  phyStr = "A"
    case .mode11b:  phyStr = "B"
    case .mode11g:  phyStr = "G"
    case .mode11n:  phyStr = "N"
    case .mode11ac: phyStr = "AC"
    @unknown default: phyStr = "unrecognized (\(theInterface.activePHYMode().rawValue))"
    }
    lua_pushstring(L, phyStr)
    lua_setfield(L, -2, "activePHYMode")

    return 1
}

private func pushCWChannel(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let theChannel = obj as! CWChannel
    lua_newtable(L)

    let widthStr: String
    switch theChannel.channelWidth {
    case .width20MHz:    widthStr = "20MHz"
    case .width40MHz:    widthStr = "40MHz"
    case .width80MHz:    widthStr = "80MHz"
    case .width160MHz:   widthStr = "160MHz"
    case .widthUnknown:  widthStr = "unknown"
    @unknown default:    widthStr = "unrecognized (\(theChannel.channelWidth.rawValue))"
    }
    lua_pushstring(L, widthStr)
    lua_setfield(L, -2, "width")

    lua_pushinteger(L, lua_Integer(theChannel.channelNumber))
    lua_setfield(L, -2, "number")

    let bandStr: String
    switch theChannel.channelBand {
    case .band2GHz:    bandStr = "2GHz"
    case .band5GHz:    bandStr = "5GHz"
    case .bandUnknown: bandStr = "unknown"
    @unknown default:  bandStr = "unrecognized (\(theChannel.channelBand.rawValue))"
    }
    lua_pushstring(L, bandStr)
    lua_setfield(L, -2, "band")

    return 1
}

private func pushCWConfiguration(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let theConfig = obj as! CWConfiguration
    lua_newtable(L)
    lua_pushboolean(L, theConfig.requireAdministratorForPower ? 1 : 0)
    lua_setfield(L, -2, "requireAdministratorForPower")
    lua_pushboolean(L, theConfig.requireAdministratorForIBSSMode ? 1 : 0)
    lua_setfield(L, -2, "requireAdministratorForIBSSMode")
    lua_pushboolean(L, theConfig.requireAdministratorForAssociation ? 1 : 0)
    lua_setfield(L, -2, "requireAdministratorForAssociation")
    lua_pushboolean(L, theConfig.rememberJoinedNetworks ? 1 : 0)
    lua_setfield(L, -2, "rememberJoinedNetworks")
    skin.pushNSObject(theConfig.networkProfiles.array as NSArray)
    lua_setfield(L, -2, "networkProfiles")

    return 1
}

private func pushCWNetwork(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let theNetwork = obj as! CWNetwork
    lua_newtable(L)

    skin.pushNSObject(theNetwork.wlanChannel)
    lua_setfield(L, -2, "wlanChannel")
    skin.pushNSObject(theNetwork.ssidData as NSData?)
    lua_setfield(L, -2, "ssidData")
    skin.pushNSObject(theNetwork.ssid as NSString?)
    lua_setfield(L, -2, "ssid")
    lua_pushinteger(L, lua_Integer(theNetwork.rssiValue))
    lua_setfield(L, -2, "rssi")
    lua_pushinteger(L, lua_Integer(theNetwork.noiseMeasurement))
    lua_setfield(L, -2, "noise")
    lua_pushboolean(L, theNetwork.ibss ? 1 : 0)
    lua_setfield(L, -2, "ibss")
    skin.pushNSObject(theNetwork.countryCode as NSString?)
    lua_setfield(L, -2, "countryCode")
    skin.pushNSObject(theNetwork.bssid as NSString?)
    lua_setfield(L, -2, "bssid")
    lua_pushinteger(L, lua_Integer(theNetwork.beaconInterval))
    lua_setfield(L, -2, "beaconInterval")

    // security table
    lua_newtable(L)
    let secTypes: [(CWSecurity, String)] = [
        (.none, "None"), (.WEP, "WEP"), (.wpaPersonal, "WPA Personal"),
        (.wpaPersonalMixed, "WPA Personal Mixed"), (.wpa2Personal, "WPA2 Personal"),
        (.personal, "Personal"), (.dynamicWEP, "Dynamic WEP"),
        (.wpaEnterprise, "WPA Enterprise"), (.wpaEnterpriseMixed, "WPA Enterprise Mixed"),
        (.wpa2Enterprise, "WPA2 Enterprise"), (.enterprise, "Enterprise"),
    ]
    for (secType, name) in secTypes {
        if theNetwork.supportsSecurity(secType) {
            lua_pushstring(L, name)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    lua_setfield(L, -2, "security")

    // PHY modes table
    lua_newtable(L)
    let phyModes: [(CWPHYMode, String)] = [
        (.modeNone, "None"), (.mode11a, "A"), (.mode11b, "B"),
        (.mode11g, "G"), (.mode11n, "N"), (.mode11ac, "AC"),
    ]
    for (mode, name) in phyModes {
        if theNetwork.supportsPHYMode(mode) {
            lua_pushstring(L, name)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    lua_setfield(L, -2, "PHYModes")

    // informationElementData as array of integers
    lua_newtable(L)
    if let ied = theNetwork.informationElementData {
        let bytes = [UInt8](ied)
        for byte in bytes {
            lua_pushinteger(L, lua_Integer(byte))
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    }
    lua_setfield(L, -2, "informationElementData")

    return 1
}

private func pushCWNetworkProfile(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let theProfile = obj as! CWNetworkProfile
    lua_newtable(L)

    skin.pushNSObject(theProfile.ssidData as NSData?)
    lua_setfield(L, -2, "ssidData")
    skin.pushNSObject(theProfile.ssid as NSString?)
    lua_setfield(L, -2, "ssid")

    let securityStr: String
    switch theProfile.security {
    case .none:                securityStr = "None"
    case .WEP:                 securityStr = "WEP"
    case .wpaPersonal:         securityStr = "WPA Personal"
    case .wpaPersonalMixed:    securityStr = "WPA Personal Mixed"
    case .wpa2Personal:        securityStr = "WPA2 Personal"
    case .personal:            securityStr = "Personal"
    case .dynamicWEP:          securityStr = "Dynamic WEP"
    case .wpaEnterprise:       securityStr = "WPA Enterprise"
    case .wpaEnterpriseMixed:  securityStr = "WPA Enterprise Mixed"
    case .wpa2Enterprise:      securityStr = "WPA2 Enterprise"
    case .enterprise:          securityStr = "Enterprise"
    case .unknown:             securityStr = "Unknown"
    @unknown default:          securityStr = "unrecognized (\(theProfile.security.rawValue))"
    }
    lua_pushstring(L, securityStr)
    lua_setfield(L, -2, "security")

    return 1
}

// MARK: - Hammerspoon Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let scannerPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let scanner = Unmanaged<HSWifiScan>.fromOpaque(scannerPtr.pointee!).takeUnretainedValue()
    skin.pushNSObject(NSString(format: "%s: %s (%p)", USERDATA_TAG, scanner.isDone ? "done" : "scanning", scannerPtr))
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let scannerPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let scanner = Unmanaged<HSWifiScan>.fromOpaque(scannerPtr.pointee!).takeRetainedValue()
    let skin = LuaSkin.shared(withState: L)!

    scanner.fnRef = skin.luaUnref(refTable, ref: scanner.fnRef)

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)

    return 0
}

private var wifilib: [luaL_Reg] = [
    luaL_Reg(name: strdup("availableNetworks"), func: wifi_scan),
    luaL_Reg(name: strdup("backgroundScan"), func: wifi_scan_background),
    luaL_Reg(name: strdup("interfaces"), func: wifi_interfaces),
    luaL_Reg(name: strdup("currentNetwork"), func: wifi_current_ssid),
    luaL_Reg(name: strdup("interfaceDetails"), func: interfaceDetails),
    luaL_Reg(name: strdup("setPower"), func: setPower),
    luaL_Reg(name: strdup("disassociate"), func: disassociate),
    luaL_Reg(name: strdup("associate"), func: associate),
    luaL_Reg(name: nil, func: nil),
]

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("isDone"), func: backgroundScanIsDone),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwifi")
public func luaopen_hs_libwifi(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &wifilib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushCWInterface, forClass: "CWInterface")
    skin.registerPushNSHelper(pushCWChannel, forClass: "CWChannel")
    skin.registerPushNSHelper(pushCWConfiguration, forClass: "CWConfiguration")
    skin.registerPushNSHelper(pushCWNetwork, forClass: "CWNetwork")
    skin.registerPushNSHelper(pushCWNetworkProfile, forClass: "CWNetworkProfile")

    return 1
}
