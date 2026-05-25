/// === hs.wifi.watcher ===
///
/// Watch for changes to the associated wifi network

import Foundation
import Cocoa
import CoreWLAN
import LuaSkin

private let USERDATA_TAG = "hs.wifi.watcher"
private var refTable: Int32 = LUA_NOREF

private var watchableTypes: [String: String] = [:]
private var manager: HSWifiWatcherManager?

// MARK: - Support Functions and Classes

private class HSWifiWatcherManager: NSObject {
    var interface: CWInterface?
    var watchers: NSMutableSet = NSMutableSet()

    override init() {
        super.init()
        interface = CWWiFiClient.shared().interface()

        let nc = NotificationCenter.default
        for (_, value) in watchableTypes {
            nc.addObserver(self,
                           selector: #selector(identifyNotification(_:)),
                           name: NSNotification.Name(value),
                           object: nil)
        }
    }

    deinit {
        let nc = NotificationCenter.default
        for (_, value) in watchableTypes {
            nc.removeObserver(self, name: NSNotification.Name(value), object: nil)
        }
    }

    @objc func identifyNotification(_ notification: Notification) {
        let type = notification.name.rawValue
        let iface = interface?.interfaceName ?? ""

        switch type {
        case NSNotification.Name.CWPowerDidChange.rawValue:
            invokeCallbacks(for: "powerChange", withDetails: [iface])
        case NSNotification.Name.CWSSIDDidChange.rawValue:
            invokeCallbacks(for: "SSIDChange", withDetails: [iface])
        case NSNotification.Name.CWBSSIDDidChange.rawValue:
            invokeCallbacks(for: "BSSIDChange", withDetails: [iface])
        case NSNotification.Name.CWCountryCodeDidChange.rawValue:
            invokeCallbacks(for: "countryCodeChange", withDetails: [iface])
        case NSNotification.Name.CWLinkDidChange.rawValue:
            invokeCallbacks(for: "linkChange", withDetails: [iface])
        case NSNotification.Name.CWLinkQualityDidChange.rawValue:
            let rssi = notification.userInfo?[CWLinkQualityNotificationRSSIKey] as? NSNumber ?? NSNumber(value: 0)
            let transmitRate = notification.userInfo?[CWLinkQualityNotificationTransmitRateKey] as? NSNumber ?? NSNumber(value: 0.0)
            invokeCallbacks(for: "linkQualityChange", withDetails: [iface, rssi, transmitRate])
        case NSNotification.Name.CWModeDidChange.rawValue:
            invokeCallbacks(for: "modeChange", withDetails: [iface])
        case NSNotification.Name.CWScanCacheDidUpdate.rawValue:
            invokeCallbacks(for: "scanCacheUpdated", withDetails: [iface])
        default:
            LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):identifyNotification - unrecognized notification received: \(type)")
        }
    }

    func invokeCallbacks(for message: String, withDetails details: [Any]?) {
        guard watchableTypes[message] != nil else {
            LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):invokeCallbacksFor called with unrecognized label:\(message)")
            return
        }
        watchers.enumerateObjects { obj, _ in
            guard let aWatcher = obj as? HSWifiWatcher else { return }
            guard let watchingFor = aWatcher.watchingFor, watchingFor.contains(message) else { return }
            DispatchQueue.main.async {
                if aWatcher.callbackRef != LUA_NOREF {
                    let skin = LuaSkin.skin(with: nil)
                    let L = skin.l!
                    _lua_stackguard_entry(L)
                    skin.pushLuaRef(refTable, ref: aWatcher.callbackRef)
                    skin.pushNSObject(aWatcher)
                    skin.pushNSObject(message as NSString)
                    let count = details?.count ?? 0
                    if count > 0 {
                        skin.growStack(Int32(count), withMessage: "hs.wifi.watcher:invokeCallbacksFor")
                    }
                    if let details = details {
                        for argument in details {
                            skin.pushNSObject(argument as? NSObject, withOptions: UInt(1 << 1))
                        }
                    }
                    skin.protectedCallAndError("hs.wifi.watcher callback for \(message)",
                                               nargs: Int32(2 + count), nresults: 0)
                    _lua_stackguard_exit(L)
                }
            }
        }
    }
}

private class HSWifiWatcher: NSObject {
    var callbackRef: Int32 = LUA_NOREF
    var selfRef: Int32 = 0
    var watchingFor: Set<String>? = Set(["SSIDChange"])
}

// MARK: - Module Functions

/// hs.wifi.watcher.new(fn) -> watcher
/// Constructor
/// Creates a new watcher for WiFi network events
///
/// Parameters:
///  * fn - A function that will be called when a WiFi event that is being monitored occurs. The function should expect 2 or 4 arguments as described in the notes below.
///
/// Returns:
///  * A `hs.wifi.watcher` object
///
/// Notes:
///  * For backwards compatibility, only "SSIDChange" is watched for by default, so existing code can continue to ignore the callback function arguments unless you add or change events with the [hs.wifi.watcher:watchingFor](#watchingFor).
///  * The callback function should expect between 3 and 5 arguments, depending upon the events being watched.  The possible arguments are as follows:
///    * `watcher`, "SSIDChange", `interface` - occurs when the associated network for the Wi-Fi interface changes
///      * `watcher`   - the watcher object itself
///      * `message`   - the message specifying the event, in this case "SSIDChange"
///      * `interface` - the name of the interface for which the event occurred
///    * Use `hs.wifi.currentNetwork([interface])` to identify the new network, which may be nil when you leave a network.
///    * `watcher`, "BSSIDChange", `interface` - occurs when the base station the Wi-Fi interface is connected to changes
///    * `watcher`, "countryCodeChange", `interface` - occurs when the adopted country code of the Wi-Fi interface changes
///    * `watcher`, "linkChange", `interface` - occurs when the link state for the Wi-Fi interface changes
///    * `watcher`, "linkQualityChange", `interface`, `rssi`, `rate` - occurs when the RSSI or transmit rate for the Wi-Fi interface changes
///    * `watcher`, "modeChange", `interface` - occurs when the operating mode of the Wi-Fi interface changes
///    * `watcher`, "powerChange", `interface` - occurs when the power state of the Wi-Fi interface changes
///    * `watcher`, "scanCacheUpdated", `interface` - occurs when the scan cache of the Wi-Fi interface is updated with new information
private func wifi_watcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)
    let newWatcher = HSWifiWatcher()
    lua_pushvalue(L, 1)
    newWatcher.callbackRef = skin.luaRef(refTable)
    skin.pushNSObject(newWatcher)
    return 1
}

// MARK: - Module Methods

/// hs.wifi.watcher:start() -> watcher
/// Method
/// Starts the SSID watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.wifi.watcher` object
private func wifi_watcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let watcher: HSWifiWatcher = skin.toNSObject(atIndex: 1) as! HSWifiWatcher
    manager?.watchers.add(watcher)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.wifi.watcher:stop() -> watcher
/// Method
/// Stops the SSID watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.wifi.watcher` object
private func wifi_watcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let watcher: HSWifiWatcher = skin.toNSObject(atIndex: 1) as! HSWifiWatcher
    manager?.watchers.remove(watcher)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.wifi.watcher:watchingFor([messages]) -> watcher | current-value
/// Method
/// Get or set the specific types of wifi events to generate a callback for with this watcher.
///
/// Parameters:
///  * `messages` - an optional table of or list of strings specifying the types of events this watcher should invoke a callback for.  You can specify multiple types of events to watch for. Defaults to `{ "SSIDChange" }`.
///
/// Returns:
///  * if a value is provided, returns the watcher object; otherwise returns the current values as a table of strings.
///
/// Notes:
///  * the possible values for this method are described in [hs.wifi.watcher.eventTypes](#eventTypes).
///  * the special string "all" specifies that all event types should be watched for.
private func wifi_watcher_watchingFor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let watcher: HSWifiWatcher = skin.toNSObject(atIndex: 1) as! HSWifiWatcher
    if lua_gettop(L) == 1 {
        skin.pushNSObject(watcher.watchingFor as NSSet?)
    } else {
        let messages = skin.toNSObject(atIndex: 2) as? [Any]
        if let messages = messages as? [String] {
            for (idx, msg) in messages.enumerated() {
                if watchableTypes[msg] == nil {
                    let keys = watchableTypes.keys.joined(separator: ", ")
                    return luaL_argerror(L, 2,
                        "unrecognized message at index \(idx + 1); expected one of \(keys)")
                }
            }
            watcher.watchingFor = Set(messages)
            lua_pushvalue(L, 1)
        } else {
            return luaL_argerror(L, 2, "expected an array of messages")
        }
    }
    return 1
}

// MARK: - Module Constants

/// hs.wifi.watcher.eventTypes[]
/// Constant
/// A table containing the possible event types that this watcher can monitor for.
private func pushEventTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.pushNSObject(Array(watchableTypes.keys) as NSArray)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSWifiWatcher(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let value = obj as! HSWifiWatcher
    value.selfRef += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSWifiWatcherFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<HSWifiWatcher>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        skin.logError(String(format: "expected %s object, found %s",
                             USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let str = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, str)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "HSWifiWatcher") as? HSWifiWatcher
        let obj2 = skin.luaObject(at: 2, toClass: "HSWifiWatcher") as? HSWifiWatcher
        lua_pushboolean(L, (obj1 != nil && obj2 != nil && obj1!.isEqual(obj2!)) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<HSWifiWatcher>.fromOpaque(rawPtr).takeRetainedValue()
        obj.selfRef -= 1
        if obj.selfRef == 0 {
            obj.callbackRef = LuaSkin.skin(with: L).luaUnref(refTable, ref: obj.callbackRef)
            manager?.watchers.remove(obj)
        }
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    manager?.watchers.removeAllObjects()
    manager = nil
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"), func: wifi_watcher_start),
    luaL_Reg(name: strdup("stop"), func: wifi_watcher_stop),
    luaL_Reg(name: strdup("watchingFor"), func: wifi_watcher_watchingFor),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: wifi_watcher_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwifiwatcher")
public func luaopen_hs_libwifiwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    watchableTypes = [
        "powerChange":       NSNotification.Name.CWPowerDidChange.rawValue,
        "SSIDChange":        NSNotification.Name.CWSSIDDidChange.rawValue,
        "BSSIDChange":       NSNotification.Name.CWBSSIDDidChange.rawValue,
        "countryCodeChange": NSNotification.Name.CWCountryCodeDidChange.rawValue,
        "linkChange":        NSNotification.Name.CWLinkDidChange.rawValue,
        "linkQualityChange": NSNotification.Name.CWLinkQualityDidChange.rawValue,
        "modeChange":        NSNotification.Name.CWModeDidChange.rawValue,
        "scanCacheUpdated":  NSNotification.Name.CWScanCacheDidUpdate.rawValue,
    ]

    manager = HSWifiWatcherManager()

    skin.registerPushNSHelper(pushHSWifiWatcher, forClass: "HSWifiWatcher")
    skin.registerLuaObjectHelper(toHSWifiWatcherFromLua, forClass: "HSWifiWatcher",
                                 withUserdataMapping: USERDATA_TAG)

    pushEventTypes(L)
    lua_setfield(L, -2, "eventTypes")

    return 1
}
