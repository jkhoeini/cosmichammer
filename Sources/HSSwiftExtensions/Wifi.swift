import Cocoa
import CLua
import CoreWLAN
import os.log

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
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fnRef))
            if let error = object as? NSError {
                os_log(.info, "%{public}s", error.localizedDescription)
                lua_pushany(L, error.localizedDescription as NSString)
            } else if let networks = object as? Set<CWNetwork> {
                pushWifiValue(L, networks)
            } else if let networks = object as? NSSet {
                pushWifiValue(L, networks)
            } else {
                lua_pushnil(L)
            }
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
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
private func setPower(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func disassociate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
///  * This function blocks Cosmic Hammer until the operation is completed
///  * If multiple access points are available with the same SSID, one will be chosen at random to connect to
private func associate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    var success = false
    var interfaceName: String?

    if lua_type(L, 3) == LUA_TSTRING {
        interfaceName = lua_tovalue(L, at: 3) as? String
    }

    let interface = get_wifi_interface(interfaceName)
    let ssid = lua_tovalue(L, at: 1) as? String
    let networks = try? interface?.scanForNetworks(withName: ssid)
    if let network = networks?.first {
        let password = lua_tovalue(L, at: 2) as? String ?? ""
        success = (try? interface?.associate(to: network, password: password)) != nil
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
private func wifi_interfaces(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let sharedClient = CWWiFiClient.shared()
    if let names = sharedClient.interfaceNames() {
        pushWifiValue(L, NSSet(array: names))
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
private func wifi_scan(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func wifi_scan_background(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    var callbackRef: Int32 = LUA_NOREF
    if lua_type(L, 1) != LUA_TNIL {
        lua_pushvalue(L, 1)
        callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
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
private func wifi_current_ssid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func interfaceDetails(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var theName: String?
    if lua_gettop(L) == 1 {
        theName = String(cString: luaL_checkstring(L, 1))
    }

    let interface = get_wifi_interface(theName)
    if let iface = interface {
        _ = pushCWInterface(L, iface)
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
private func backgroundScanIsDone(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let scannerPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let scanner = Unmanaged<HSWifiScan>.fromOpaque(scannerPtr.pointee!).takeUnretainedValue()
    lua_pushboolean(L, scanner.isDone ? 1 : 0)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private let wifiMaxPushDepth = 50

private func pushWifiValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?) {
    pushWifiValue(L, value, depth: 0)
}

private func pushWifiValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?, depth: Int) {
    guard depth < wifiMaxPushDepth else {
        lua_pushnil(L)
        return
    }

    guard let value = value else {
        lua_pushnil(L)
        return
    }

    switch value {
    case let interface as CWInterface:
        _ = pushCWInterface(L, interface)
    case let network as CWNetwork:
        _ = pushCWNetwork(L, network)
    case let channel as CWChannel:
        _ = pushCWChannel(L, channel)
    case let configuration as CWConfiguration:
        _ = pushCWConfiguration(L, configuration)
    case let profile as CWNetworkProfile:
        _ = pushCWNetworkProfile(L, profile)
    case let networks as Set<CWNetwork>:
        pushWifiSequence(L, networks, depth: depth)
    case let channels as Set<CWChannel>:
        pushWifiSequence(L, channels, depth: depth)
    case let profiles as Set<CWNetworkProfile>:
        pushWifiSequence(L, profiles, depth: depth)
    case let set as NSSet:
        pushWifiSequence(L, set, depth: depth)
    case let array as NSArray:
        pushWifiSequence(L, array, depth: depth)
    case let array as [Any]:
        pushWifiSequence(L, array, depth: depth)
    case let dict as NSDictionary:
        pushWifiDictionary(L, dict, depth: depth)
    case let dict as [String: Any]:
        pushWifiDictionary(L, dict, depth: depth)
    default:
        lua_pushany(L, value)
    }
}

private func pushWifiSequence<S: Sequence>(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ sequence: S,
    depth: Int
) {
    let values = Array(sequence)
    lua_createtable(L, Int32(values.count), 0)
    for value in values {
        pushWifiValue(L, value, depth: depth + 1)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
}

private func pushWifiDictionary(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ dict: NSDictionary,
    depth: Int
) {
    lua_createtable(L, 0, Int32(dict.count))
    for (key, value) in dict {
        lua_pushany(L, key)
        pushWifiValue(L, value, depth: depth + 1)
        lua_settable(L, -3)
    }
}

private func pushWifiDictionary(
    _ L: UnsafeMutablePointer<lua_State>!,
    _ dict: [String: Any],
    depth: Int
) {
    lua_createtable(L, 0, Int32(dict.count))
    for (key, value) in dict {
        lua_pushstring(L, key)
        pushWifiValue(L, value, depth: depth + 1)
        lua_settable(L, -3)
    }
}

private func pushCWInterface(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theInterface = obj as! CWInterface
    lua_newtable(L)

    pushWifiValue(L, theInterface.wlanChannel())
    lua_setfield(L, -2, "wlanChannel")
    lua_pushnumber(L, lua_Number(theInterface.transmitRate()))
    lua_setfield(L, -2, "transmitRate")
    lua_pushinteger(L, lua_Integer(theInterface.transmitPower()))
    lua_setfield(L, -2, "transmitPower")
    pushWifiValue(L, theInterface.supportedWLANChannels() as NSSet?)
    lua_setfield(L, -2, "supportedChannels")
    lua_pushany(L, theInterface.ssidData() as NSData?)
    lua_setfield(L, -2, "ssidData")
    lua_pushany(L, theInterface.ssid() as NSString?)
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
    case .wpa3Personal:        securityStr = "WPA3 Personal"
    case .wpa3Enterprise:      securityStr = "WPA3 Enterprise"
    case .wpa3Transition:      securityStr = "WPA3 Transition"
    case .OWE:                 securityStr = "OWE"
    case .oweTransition:       securityStr = "OWE Transition"
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
    lua_pushany(L, theInterface.interfaceName as NSString?)
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

    lua_pushany(L, theInterface.hardwareAddress() as NSString?)
    lua_setfield(L, -2, "hardwareAddress")
    lua_pushany(L, theInterface.countryCode() as NSString?)
    lua_setfield(L, -2, "countryCode")
    pushWifiValue(L, theInterface.configuration())
    lua_setfield(L, -2, "configuration")
    pushWifiValue(L, theInterface.cachedScanResults() as NSSet?)
    lua_setfield(L, -2, "cachedScanResults")
    lua_pushany(L, theInterface.bssid() as NSString?)
    lua_setfield(L, -2, "bssid")

    let phyStr: String
    switch theInterface.activePHYMode() {
    case .modeNone: phyStr = "None"
    case .mode11a:  phyStr = "A"
    case .mode11b:  phyStr = "B"
    case .mode11g:  phyStr = "G"
    case .mode11n:  phyStr = "N"
    case .mode11ac: phyStr = "AC"
    case .mode11ax: phyStr = "AX"
    case .mode11be: phyStr = "BE"
    @unknown default: phyStr = "unrecognized (\(theInterface.activePHYMode().rawValue))"
    }
    lua_pushstring(L, phyStr)
    lua_setfield(L, -2, "activePHYMode")

    return 1
}

private func pushCWChannel(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
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
    case .band6GHz:    bandStr = "6GHz"
    case .bandUnknown: bandStr = "unknown"
    @unknown default:  bandStr = "unrecognized (\(theChannel.channelBand.rawValue))"
    }
    lua_pushstring(L, bandStr)
    lua_setfield(L, -2, "band")

    return 1
}

private func pushCWConfiguration(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
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
    pushWifiValue(L, theConfig.networkProfiles.array as NSArray)
    lua_setfield(L, -2, "networkProfiles")

    return 1
}

private func pushCWNetwork(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theNetwork = obj as! CWNetwork
    lua_newtable(L)

    pushWifiValue(L, theNetwork.wlanChannel)
    lua_setfield(L, -2, "wlanChannel")
    lua_pushany(L, theNetwork.ssidData as NSData?)
    lua_setfield(L, -2, "ssidData")
    lua_pushany(L, theNetwork.ssid as NSString?)
    lua_setfield(L, -2, "ssid")
    lua_pushinteger(L, lua_Integer(theNetwork.rssiValue))
    lua_setfield(L, -2, "rssi")
    lua_pushinteger(L, lua_Integer(theNetwork.noiseMeasurement))
    lua_setfield(L, -2, "noise")
    lua_pushboolean(L, theNetwork.ibss ? 1 : 0)
    lua_setfield(L, -2, "ibss")
    lua_pushany(L, theNetwork.countryCode as NSString?)
    lua_setfield(L, -2, "countryCode")
    lua_pushany(L, theNetwork.bssid as NSString?)
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

private func pushCWNetworkProfile(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theProfile = obj as! CWNetworkProfile
    lua_newtable(L)

    lua_pushany(L, theProfile.ssidData as NSData?)
    lua_setfield(L, -2, "ssidData")
    lua_pushany(L, theProfile.ssid as NSString?)
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
    case .wpa3Personal:        securityStr = "WPA3 Personal"
    case .wpa3Enterprise:      securityStr = "WPA3 Enterprise"
    case .wpa3Transition:      securityStr = "WPA3 Transition"
    case .OWE:                 securityStr = "OWE"
    case .oweTransition:       securityStr = "OWE Transition"
    case .unknown:             securityStr = "Unknown"
    @unknown default:          securityStr = "unrecognized (\(theProfile.security.rawValue))"
    }
    lua_pushstring(L, securityStr)
    lua_setfield(L, -2, "security")

    return 1
}

// MARK: - Cosmic Hammer Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let scannerPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let scanner = Unmanaged<HSWifiScan>.fromOpaque(scannerPtr.pointee!).takeUnretainedValue()
    lua_pushany(L, NSString(format: "%s: %s (%p)", USERDATA_TAG, scanner.isDone ? "done" : "scanning", scannerPtr))
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let scannerPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let scanner = Unmanaged<HSWifiScan>.fromOpaque(scannerPtr.pointee!).takeRetainedValue()

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, scanner.fnRef)


    scanner.fnRef = LUA_NOREF

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
public func luaopen_hs_libwifi(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(wifilib.count - 1))
    luaL_setfuncs(L, &wifilib, 0)

    return 1
}
