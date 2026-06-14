import Cocoa
import CLua
import Lua
import CoreWLAN
import os.log

private let USERDATA_TAG = "hs.wifi"

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
    var callback: LuaValue?
    var isDone: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    init(callback: LuaValue?, onInterface interface: String?) {
        self.callback = callback
        self.isDone = false
        self.generation = lua_currentStateGeneration()
        super.init()
        self.performSelector(inBackground: #selector(doBackgroundScan(_:)),
                             with: interface as NSString?)
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        callback = nil
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
        guard lua_isStateGenerationValid(generation) else { return }
        guard let cb = callback else { return }
        let L = lua_getCurrentState()!
        cb.push(onto: L)
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
private func setPower(_ L: LuaState) throws -> CInt {
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
        L.push(true)
    } catch let error as NSError {
        L.push(false)
        L.push(error.localizedDescription)
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
private func disassociate(_ L: LuaState) throws -> CInt {
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
private func associate(_ L: LuaState) throws -> CInt {

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

    L.push(success)
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
private func wifi_interfaces(_ L: LuaState) throws -> CInt {
    let sharedClient = CWWiFiClient.shared()
    if let names = sharedClient.interfaceNames() {
        pushWifiValue(L, names)
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
private func wifi_scan(_ L: LuaState) throws -> CInt {
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
        L.push(i)
        i += 1
        L.push(network.ssid ?? "")
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
private func wifi_scan_background(_ L: LuaState) throws -> CInt {

    let cb: LuaValue? = (lua_type(L, 1) != LUA_TNIL) ? L.ref(index: 1) : nil

    var theName: String?
    if lua_gettop(L) == 2 {
        theName = String(cString: luaL_checkstring(L, 2))
    }

    let scanner = HSWifiScan(callback: cb, onInterface: theName)
    L.push(userdata: scanner)

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
private func wifi_current_ssid(_ L: LuaState) throws -> CInt {
    var theName: String?
    if lua_gettop(L) == 1 {
        theName = String(cString: luaL_checkstring(L, 1))
    }

    let interface = get_wifi_interface(theName)
    if let ssid = interface?.ssid() {
        L.push(ssid)
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
private func interfaceDetails(_ L: LuaState) throws -> CInt {
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

    guard let value else {
        lua_pushnil(L)
        return
    }

    switch value {
    case is NSNull:
        lua_pushnil(L)
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
    var index: lua_Integer = 1
    for value in values {
        pushWifiValue(L, value, depth: depth + 1)
        lua_rawseti(L, -2, index)
        index += 1
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
        L.push(key)
        pushWifiValue(L, value, depth: depth + 1)
        lua_settable(L, -3)
    }
}

private func pushCWInterface(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theInterface = obj as! CWInterface
    lua_newtable(L)

    pushWifiValue(L, theInterface.wlanChannel())
    lua_setfield(L, -2, "wlanChannel")
    L.push(lua_Number(theInterface.transmitRate()))
    lua_setfield(L, -2, "transmitRate")
    L.push(lua_Integer(theInterface.transmitPower()))
    lua_setfield(L, -2, "transmitPower")
    pushWifiValue(L, theInterface.supportedWLANChannels() as NSSet?)
    lua_setfield(L, -2, "supportedChannels")
    lua_pushany(L, theInterface.ssidData() as NSData?)
    lua_setfield(L, -2, "ssidData")
    lua_pushany(L, theInterface.ssid() as NSString?)
    lua_setfield(L, -2, "ssid")
    L.push(theInterface.serviceActive())
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
    L.push(securityStr)
    lua_setfield(L, -2, "security")

    L.push(lua_Integer(theInterface.rssiValue()))
    lua_setfield(L, -2, "rssi")
    L.push(theInterface.powerOn())
    lua_setfield(L, -2, "power")
    L.push(lua_Integer(theInterface.noiseMeasurement()))
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
    L.push(modeStr)
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
    L.push(phyStr)
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
    L.push(widthStr)
    lua_setfield(L, -2, "width")

    L.push(lua_Integer(theChannel.channelNumber))
    lua_setfield(L, -2, "number")

    let bandStr: String
    switch theChannel.channelBand {
    case .band2GHz:    bandStr = "2GHz"
    case .band5GHz:    bandStr = "5GHz"
    case .band6GHz:    bandStr = "6GHz"
    case .bandUnknown: bandStr = "unknown"
    @unknown default:  bandStr = "unrecognized (\(theChannel.channelBand.rawValue))"
    }
    L.push(bandStr)
    lua_setfield(L, -2, "band")

    return 1
}

private func pushCWConfiguration(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theConfig = obj as! CWConfiguration
    lua_newtable(L)
    L.push(theConfig.requireAdministratorForPower)
    lua_setfield(L, -2, "requireAdministratorForPower")
    L.push(theConfig.requireAdministratorForIBSSMode)
    lua_setfield(L, -2, "requireAdministratorForIBSSMode")
    L.push(theConfig.requireAdministratorForAssociation)
    lua_setfield(L, -2, "requireAdministratorForAssociation")
    L.push(theConfig.rememberJoinedNetworks)
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
    L.push(lua_Integer(theNetwork.rssiValue))
    lua_setfield(L, -2, "rssi")
    L.push(lua_Integer(theNetwork.noiseMeasurement))
    lua_setfield(L, -2, "noise")
    L.push(theNetwork.ibss)
    lua_setfield(L, -2, "ibss")
    lua_pushany(L, theNetwork.countryCode as NSString?)
    lua_setfield(L, -2, "countryCode")
    lua_pushany(L, theNetwork.bssid as NSString?)
    lua_setfield(L, -2, "bssid")
    L.push(lua_Integer(theNetwork.beaconInterval))
    lua_setfield(L, -2, "beaconInterval")

    // security table
    lua_newtable(L)
    let secTypes: [(CWSecurity, String)] = [
        (.none, "None"), (.WEP, "WEP"), (.wpaPersonal, "WPA Personal"),
        (.wpaPersonalMixed, "WPA Personal Mixed"), (.wpa2Personal, "WPA2 Personal"),
        (.personal, "Personal"), (.dynamicWEP, "Dynamic WEP"),
        (.wpaEnterprise, "WPA Enterprise"), (.wpaEnterpriseMixed, "WPA Enterprise Mixed"),
        (.wpa2Enterprise, "WPA2 Enterprise"), (.enterprise, "Enterprise"),
        (.wpa3Personal, "WPA3 Personal"), (.wpa3Enterprise, "WPA3 Enterprise"),
        (.wpa3Transition, "WPA3 Transition"), (.OWE, "OWE"),
        (.oweTransition, "OWE Transition"),
    ]
    var securityIndex: lua_Integer = 1
    for (secType, name) in secTypes {
        if theNetwork.supportsSecurity(secType) {
            L.push(name)
            lua_rawseti(L, -2, securityIndex)
            securityIndex += 1
        }
    }
    lua_setfield(L, -2, "security")

    // PHY modes table
    lua_newtable(L)
    let phyModes: [(CWPHYMode, String)] = [
        (.modeNone, "None"), (.mode11a, "A"), (.mode11b, "B"),
        (.mode11g, "G"), (.mode11n, "N"), (.mode11ac, "AC"),
        (.mode11ax, "AX"), (.mode11be, "BE"),
    ]
    var phyIndex: lua_Integer = 1
    for (mode, name) in phyModes {
        if theNetwork.supportsPHYMode(mode) {
            L.push(name)
            lua_rawseti(L, -2, phyIndex)
            phyIndex += 1
        }
    }
    lua_setfield(L, -2, "PHYModes")

    // informationElementData as array of integers
    lua_newtable(L)
    if let ied = theNetwork.informationElementData {
        let bytes = [UInt8](ied)
        var byteIndex: lua_Integer = 1
        for byte in bytes {
            L.push(lua_Integer(byte))
            lua_rawseti(L, -2, byteIndex)
            byteIndex += 1
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
    L.push(securityStr)
    lua_setfield(L, -2, "security")

    return 1
}

// MARK: - Cosmic Hammer Infrastructure

@_cdecl("luaopen_hs_libwifi")
public func luaopen_hs_libwifi(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    L.register(Metatable<HSWifiScan>(
        fields: [
            "isDone": .memberfn { $0.isDone },
        ],
        tostring: .closure { L in
            let scanner: HSWifiScan = try L.checkArgument(1)
            L.push("\(USERDATA_TAG): \(scanner.isDone ? "done" : "scanning") (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // Post-registration __gc patch: teardown() + deinitialize the Any box
    L.pushMetatable(for: HSWifiScan.self)

    L.push({ (L: LuaState!) -> CInt in
        if let scanner: HSWifiScan = L.touserdata(1) {
            scanner.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    })
    lua_setfield(L, -2, "__gc")

    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.wifi") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Module table
    lua_createtable(L, 0, 8)
    L.push(wifi_scan)
    lua_setfield(L, -2, "availableNetworks")
    L.push(wifi_scan_background)
    lua_setfield(L, -2, "backgroundScan")
    L.push(wifi_interfaces)
    lua_setfield(L, -2, "interfaces")
    L.push(wifi_current_ssid)
    lua_setfield(L, -2, "currentNetwork")
    L.push(interfaceDetails)
    lua_setfield(L, -2, "interfaceDetails")
    L.push(setPower)
    lua_setfield(L, -2, "setPower")
    L.push(disassociate)
    lua_setfield(L, -2, "disassociate")
    L.push(associate)
    lua_setfield(L, -2, "associate")

    return 1
}
