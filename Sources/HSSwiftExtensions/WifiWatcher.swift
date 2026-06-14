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
                guard lua_isStateGenerationValid(aWatcher.generation) else { return }
                if let cb = aWatcher.callback {
                    let L = lua_getCurrentState()!
                    cb.push(onto: L)
                    pushHSWifiWatcher(L, aWatcher)
                    L.push(message)
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

private class HSWifiWatcher: NSObject, LuaTeardownable {
    var callback: LuaValue?
    var selfRef: Int32 = 0
    var watchingFor: Set<String>? = Set(["SSIDChange"])
    var generation: UInt64 = 0
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        callback = nil
        manager?.watchers.remove(self)
    }
}

// MARK: - Lua<->NSObject Conversion Functions

/// Push an HSWifiWatcher as userdata with Unmanaged retain (for selfRef counting).
/// This is called from the callback path where the watcher pushes itself.
@discardableResult
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

/// Extract an HSWifiWatcher from Unmanaged raw-pointer userdata at the given stack index.
private func getHSWifiWatcher(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSWifiWatcher? {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(rawPtr).takeUnretainedValue() as? HSWifiWatcher
}

// MARK: - Module Constants

/// hs.wifi.watcher.eventTypes[]
/// Constant
/// A table containing the possible event types that this watcher can monitor for.
private func pushEventTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushany(L, Array(watchableTypes.keys))
    return 1
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libwifiwatcher")
public func luaopen_hs_libwifiwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable.
        // HSWifiWatcher uses Unmanaged raw-pointer layout (pushHSWifiWatcher) for both
        // constructor and callback paths, with selfRef counting. Cannot use Metatable<T>.
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        // start
        L.push({ (L: LuaState) throws -> CInt in
            guard let watcher = getHSWifiWatcher(L, at: 1) else {
                throw LuaCallError("expected \(USERDATA_TAG) object")
            }
            manager?.watchers.add(watcher)
            lua_pushvalue(L, 1)
            return 1
        })
        lua_setfield(L, -2, "start")

        // stop
        L.push({ (L: LuaState) throws -> CInt in
            guard let watcher = getHSWifiWatcher(L, at: 1) else {
                throw LuaCallError("expected \(USERDATA_TAG) object")
            }
            manager?.watchers.remove(watcher)
            lua_pushvalue(L, 1)
            return 1
        })
        lua_setfield(L, -2, "stop")

        // watchingFor
        L.push({ (L: LuaState) throws -> CInt in
            guard let watcher = getHSWifiWatcher(L, at: 1) else {
                throw LuaCallError("expected \(USERDATA_TAG) object")
            }
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
        })
        lua_setfield(L, -2, "watchingFor")

        // __tostring
        L.push({ (L: LuaState) throws -> CInt in
            let str = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
            L.push(str)
            return 1
        })
        lua_setfield(L, -2, "__tostring")

        // __eq
        L.push({ (L: LuaState) throws -> CInt in
            var isEqual = false
            if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
                if let obj1 = getHSWifiWatcher(L, at: 1), let obj2 = getHSWifiWatcher(L, at: 2) {
                    isEqual = obj1.isEqual(obj2)
                }
            }
            L.push(isEqual)
            return 1
        })
        lua_setfield(L, -2, "__eq")

        // __gc — handles the raw-pointer layout from pushHSWifiWatcher
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let rawPtr = ptr.pointee {
                let obj = Unmanaged<HSWifiWatcher>.fromOpaque(rawPtr).takeRetainedValue()
                obj.selfRef -= 1
                if obj.selfRef == 0 {
                    obj.teardown()
                }
                ptr.pointee = nil
            }
            lua_pushnil(L)
            lua_setmetatable(L, 1)
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")

        // __type and __name
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the registry name
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 1)

        // new constructor
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)
            let newWatcher = HSWifiWatcher()
            newWatcher.callback = L.ref(index: 1)
            newWatcher.generation = lua_currentStateGeneration()
            pushHSWifiWatcher(L, newWatcher)
            return 1
        })
        lua_setfield(L, -2, "new")

        // Set module metatable for __gc (manager cleanup)
        lua_createtable(L, 0, 1)
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            manager?.watchers.removeAllObjects()
            manager = nil
            return 0
        }, 0)
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
