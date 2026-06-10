/// === hs.wifi.watcher ===
///
/// Watch for changes to the associated wifi network

import Foundation
import CLua
import Lua
import Cocoa
import CoreWLAN
import os.log

private let USERDATA_TAG = "hs.wifi.watcher"

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
            break // unrecognized notification
        }
    }

    func invokeCallbacks(for message: String, withDetails details: [Any]?) {
        guard watchableTypes[message] != nil else {
            return
        }
        watchers.enumerateObjects { obj, _ in
            guard let aWatcher = obj as? HSWifiWatcher else { return }
            guard let watchingFor = aWatcher.watchingFor, watchingFor.contains(message) else { return }
            DispatchQueue.main.async {
                if aWatcher.callbackRef != LUA_NOREF {
                    let L = lua_getCurrentState()!
                    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(aWatcher.callbackRef))
                    pushHSWifiWatcher(L, aWatcher)
                    lua_pushstring(L, message)
                    let count = details?.count ?? 0
                    if let details = details {
                        for argument in details {
                            lua_pushany(L, argument)
                        }
                    }
                    if lua_pcall(L, Int32(2 + count), 0, 0) != LUA_OK {
                        lua_pop(L, 1)
                    }
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
private func wifi_watcher_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)
    let newWatcher = HSWifiWatcher()
    lua_pushvalue(L, 1)
    newWatcher.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    pushHSWifiWatcher(L, newWatcher)
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
private func wifi_watcher_start(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSWifiWatcher>.fromOpaque(ptr.pointee!).takeUnretainedValue()
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
private func wifi_watcher_stop(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSWifiWatcher>.fromOpaque(ptr.pointee!).takeUnretainedValue()
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
private func wifi_watcher_watchingFor(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let watcher = Unmanaged<HSWifiWatcher>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    if lua_gettop(L) == 1 {
        lua_pushany(L, watcher.watchingFor.map { Array($0) })
    } else {
        let messages = lua_tovalue(L, at: 2) as? [Any]
        if let messages = messages as? [String] {
            for (idx, msg) in messages.enumerated() {
                if watchableTypes[msg] == nil {
                    let keys = watchableTypes.keys.joined(separator: ", ")
                    throw LuaCallError("bad argument #2 (unrecognized message at index \(idx + 1); expected one of \(keys))")
                }
            }
            watcher.watchingFor = Set(messages)
            lua_pushvalue(L, 1)
        } else {
            throw LuaCallError("bad argument #2 (expected an array of messages)")
        }
    }
    return 1
}

// MARK: - Module Constants

/// hs.wifi.watcher.eventTypes[]
/// Constant
/// A table containing the possible event types that this watcher can monitor for.
private func pushEventTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushany(L, Array(watchableTypes.keys))
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
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<HSWifiWatcher>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        os_log(.error, "expected %{public}s object, found %{public}s",
               USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx))))
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let str = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, str)
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let ptr1 = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        let ptr2 = luaL_checkudata(L, 2, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        if let raw1 = ptr1.pointee, let raw2 = ptr2.pointee {
            let obj1 = Unmanaged<HSWifiWatcher>.fromOpaque(raw1).takeUnretainedValue()
            let obj2 = Unmanaged<HSWifiWatcher>.fromOpaque(raw2).takeUnretainedValue()
            lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
        } else {
            lua_pushboolean(L, 0)
        }
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<HSWifiWatcher>.fromOpaque(rawPtr).takeRetainedValue()
        obj.selfRef -= 1
        if obj.selfRef == 0 {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.callbackRef)
            obj.callbackRef = LUA_NOREF
            manager?.watchers.remove(obj)
        }
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    manager?.watchers.removeAllObjects()
    manager = nil
    return 0
}

@_cdecl("luaopen_hs_libwifiwatcher")
public func luaopen_hs_libwifiwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(wifi_watcher_start)
        lua_setfield(L, -2, "start")
        L.push(wifi_watcher_stop)
        lua_setfield(L, -2, "stop")
        L.push(wifi_watcher_watchingFor)
        lua_setfield(L, -2, "watchingFor")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(wifi_watcher_new)
        lua_setfield(L, -2, "new")

        // Set module metatable for __gc
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

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

        pushEventTypes(L)
        lua_setfield(L, -2, "eventTypes")
    }
}
