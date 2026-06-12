import Cocoa
import CLua
import Lua
import os.log
import SystemConfiguration

// SCDynamicStoreCopyDHCPInfo is not in the SystemConfiguration umbrella header,
// so Swift doesn't see it. Declare it manually.
@_silgen_name("SCDynamicStoreCopyDHCPInfo")
private func _SCDynamicStoreCopyDHCPInfo(
    _ store: SCDynamicStore?,
    _ serviceID: CFString?
) -> CFDictionary?

private let USERDATA_TAG = "hs.network.configuration"
private var dynamicStoreQueue: DispatchQueue! = nil

// MARK: - HSDynamicStore class

private class HSDynamicStore: NSObject {
    var storeObject: SCDynamicStore?
    var callback: LuaValue?
    var selfRefValue: LuaValue?
    var watcherEnabled: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let store = storeObject, watcherEnabled {
            _ = SCDynamicStoreSetDispatchQueue(store, nil)
            watcherEnabled = false
        }
        callback = nil
        selfRefValue = nil
        storeObject = nil
    }
}

// MARK: - Support Functions

private let doDynamicStoreCallback: SCDynamicStoreCallBack = { store, changedKeys, info in
    guard let info = info else { return }
    let obj = Unmanaged<HSDynamicStore>.fromOpaque(info).takeUnretainedValue()
    let nsChangedKeys = (changedKeys as NSArray).copy() as! NSArray
    DispatchQueue.main.async {
        guard let cb = obj.callback else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(obj.generation) else { return }
        cb.push(onto: L)
        L.push(userdata: obj)
        lua_pushany(L, nsChangedKeys)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
}

// MARK: - Module Functions

/// hs.network.configuration.open() -> storeObject
/// Constructor
/// Opens a session to the dynamic store maintained by the System Configuration server.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the storeObject
private func newStoreObject(_ L: LuaState) throws -> CInt {
    let theName = UUID().uuidString
    let obj = HSDynamicStore()
    obj.generation = lua_currentStateGeneration()

    var context = SCDynamicStoreContext(
        version: 0,
        info: Unmanaged.passUnretained(obj).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil
    )
    if let theStore = SCDynamicStoreCreate(kCFAllocatorDefault, theName as CFString, doDynamicStoreCallback, &context) {
        obj.storeObject = theStore
        L.push(userdata: obj)
    } else {
        throw LuaCallError("** unable to get dynamicStore reference:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

// MARK: - Module Methods

/// hs.network.configuration:contents([keys], [pattern]) -> table
/// Method
/// Return the contents of the store for the specified keys or keys matching the specified pattern(s)
///
/// Parameters:
///  * keys    - a string or table of strings containing the keys or patterns of keys, if `pattern` is true.  Defaults to all keys.
///  * pattern - a boolean indicating wether or not the string(s) provided are to be considered regular expression patterns (true) or literal strings to match (false).  Defaults to false.
///
/// Returns:
///  * a table of key-value pairs from the dynamic store which match the specified keys or key patterns.
///
/// Notes:
///  * if no parameters are provided, then all key-value pairs in the dynamic store are returned.
private func dynamicStoreContents(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    var keys: NSArray
    var keysIsPattern = false
    if lua_gettop(L) == 1 {
        keys = [".*"] as NSArray
        keysIsPattern = true
    } else {
        if lua_type(L, 2) == LUA_TTABLE {
            keys = lua_tovalue(L, at: 2) as! NSArray
        } else {
            keys = [lua_tovalue(L, at: 2)!] as NSArray
        }
        if lua_gettop(L) == 3 { keysIsPattern = lua_toboolean(L, 3) != 0 }
    }

    let results: CFDictionary?
    if keysIsPattern {
        results = SCDynamicStoreCopyMultiple(theStore, nil, keys as CFArray)
    } else {
        results = SCDynamicStoreCopyMultiple(theStore, keys as CFArray, nil)
    }
    if let results = results {
        lua_pushany(L, results as NSDictionary)
    } else {
        throw LuaCallError("** unable to get dynamicStore contents:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

/// hs.network.configuration:keys([keypattern]) -> table
/// Method
/// Return the keys in the dynamic store which match the specified pattern
///
/// Parameters:
///  * keypattern - a regular expression specifying which keys to return (defaults to ".*", or all keys)
///
/// Returns:
///  * a table of keys from the dynamic store.
private func dynamicStoreKeys(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    let keysPattern: String = (lua_gettop(L) == 1) ? ".*" : (lua_tovalue(L, at: 2) as! String)
    if let results = SCDynamicStoreCopyKeyList(theStore, keysPattern as CFString) {
        lua_pushany(L, results as NSArray)
    } else {
        throw LuaCallError("** unable to get dynamicStore keys:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

/// hs.network.configuration:dhcpInfo([serviceID]) -> table
/// Method
/// Return the DHCP information for the specified service or the primary service if no parameter is specified.
///
/// Parameters:
///  * serviceID - an optional string containing the service ID of the interface for which to return DHCP info.  If this parameter is not provided, then the default (primary) service is queried.
///
/// Returns:
///  * a table containing DHCP information including lease time and DHCP options
///
/// Notes:
///  * a list of possible Service ID's can be retrieved with `hs.network.configuration:contents("Setup:/Network/Global/IPv4")`
///  * generates an error if the service ID is invalid or was not assigned an IP address via DHCP.
private func dynamicStoreDHCPInfo(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    let serviceID: CFString?
    if lua_gettop(L) == 2 {
        serviceID = (lua_tovalue(L, at: 2) as! String) as CFString
    } else {
        serviceID = nil
    }

    if let results = _SCDynamicStoreCopyDHCPInfo(theStore, serviceID) {
        lua_pushany(L, results as NSDictionary)
    } else {
        throw LuaCallError("** unable to get DHCP info:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

/// hs.network.configuration:computerName() -> name, encoding
/// Method
/// Returns the name of the computer as specified in the Sharing Preferences, and its string encoding
///
/// Parameters:
///  * None
///
/// Returns:
///  * name     - the computer name
///  * encoding - the encoding type
///
/// Notes:
///  * You can also retrieve this information as key-value pairs with `hs.network.configuration:contents("Setup:/System")`
private func dynamicStoreComputerName(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    var encoding: CFStringEncoding = 0
    if let computerName = SCDynamicStoreCopyComputerName(theStore, &encoding) {
        lua_pushany(L, computerName as String)
        let encodingName: String
        switch encoding {
        case CFStringBuiltInEncodings.macRoman.rawValue:       encodingName = "MacRoman"
        case CFStringBuiltInEncodings.windowsLatin1.rawValue:  encodingName = "WindowsLatin1"
        case CFStringBuiltInEncodings.isoLatin1.rawValue:      encodingName = "ISOLatin1"
        case CFStringBuiltInEncodings.nextStepLatin.rawValue:  encodingName = "NextStepLatin"
        case CFStringBuiltInEncodings.ASCII.rawValue:          encodingName = "ASCII"
        case CFStringBuiltInEncodings.UTF8.rawValue:           encodingName = "UTF8"
        case CFStringBuiltInEncodings.nonLossyASCII.rawValue:  encodingName = "NonLossyASCII"
        case CFStringBuiltInEncodings.UTF16.rawValue:          encodingName = "UTF16"
        case CFStringBuiltInEncodings.UTF16BE.rawValue:        encodingName = "UTF16BE"
        case CFStringBuiltInEncodings.UTF16LE.rawValue:        encodingName = "UTF16LE"
        case CFStringBuiltInEncodings.UTF32.rawValue:          encodingName = "UTF32"
        case CFStringBuiltInEncodings.UTF32BE.rawValue:        encodingName = "UTF32BE"
        case CFStringBuiltInEncodings.UTF32LE.rawValue:        encodingName = "UTF32LE"
        case kCFStringEncodingInvalidId:                       encodingName = "InvalidId"
        default:
            encodingName = "** unrecognized encoding:\(encoding)"
        }
        lua_pushany(L, encodingName)
    } else {
        throw LuaCallError("** error retrieving computer name:\(String(cString: SCErrorString(SCError())))")
    }
    return 2
}

/// hs.network.configuration:consoleUser() -> name, uid, gid
/// Method
/// Returns the name of the user currently logged into the system, including the users id and primary group id
///
/// Parameters:
///  * None
///
/// Returns:
///  * name - the user name
///  * uid  - the user ID for the user
///  * gid  - the user's primary group ID
///
/// Notes:
///  * You can also retrieve this information as key-value pairs with `hs.network.configuration:contents("State:/Users/ConsoleUser")`
private func dynamicStoreConsoleUser(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    var uid: uid_t = 0
    var gid: gid_t = 0
    if let consoleUser = SCDynamicStoreCopyConsoleUser(theStore, &uid, &gid) {
        lua_pushany(L, consoleUser as String)
        lua_pushinteger(L, lua_Integer(uid))
        lua_pushinteger(L, lua_Integer(gid))
    } else {
        throw LuaCallError("** error retrieving console user:\(String(cString: SCErrorString(SCError())))")
    }
    return 3
}

/// hs.network.configuration:hostname() -> name
/// Method
/// Returns the current local host name for the computer
///
/// Parameters:
///  * None
///
/// Returns:
///  * name - the local host name
///
/// Notes:
///  * You can also retrieve this information as key-value pairs with `hs.network.configuration:contents("Setup:/System")`
private func dynamicStoreLocalHostName(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    if let localHostName = SCDynamicStoreCopyLocalHostName(theStore) {
        lua_pushany(L, localHostName as String)
    } else {
        throw LuaCallError("** error retrieving local host name:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

// internal stuff to make setLocation work
private let kSCPreferencesOptionChangeNetworkSet = "change-network-set" as CFString

@_silgen_name("SCPreferencesCreateWithOptions")
func SCPreferencesCreateWithOptions(
    _ allocator: CFAllocator?,
    _ name: CFString,
    _ prefsID: CFString?,
    _ authorization: AuthorizationRef?,
    _ options: CFDictionary?
) -> SCPreferences?

/// hs.network.configuration:setLocation(location) -> boolean
/// Method
/// Switches to a new location
///
/// Parameters:
///  * location - string containing name or UUID of new location
///
/// Returns:
///  * bool - true if the location was successfully changed, false if there was an error
private func dynamicStoreSetLocation(_ L: LuaState) throws -> CInt {
    let _: HSDynamicStore = try L.checkArgument(1)

    luaL_checktype(L, 2, LUA_TSTRING)

    let target = lua_tovalue(L, at: 2) as! String

    var authorization: AuthorizationRef?
    let flags: AuthorizationFlags = []
    let status = AuthorizationCreate(nil, nil, flags, &authorization)

    if status != errAuthorizationSuccess {
        lua_pushboolean(L, 0)
        if let auth = authorization {
            AuthorizationFree(auth, [.destroyRights])
        }
        return 1
    }

    let options = NSMutableDictionary()
    options[kSCPreferencesOptionChangeNetworkSet] = kCFBooleanTrue

    guard let prefs = SCPreferencesCreateWithOptions(nil, "SystemConfiguration" as CFString, nil, authorization, options as CFDictionary) else {
        lua_pushboolean(L, 0)
        AuthorizationFree(authorization!, [.destroyRights])
        return 1
    }

    guard let locations = SCNetworkSetCopyAll(prefs) as? [SCNetworkSet] else {
        lua_pushboolean(L, 0)
        AuthorizationFree(authorization!, [.destroyRights])
        return 1
    }

    var success = false
    for item in locations {
        let name = SCNetworkSetGetName(item) as String? ?? ""
        let uuid = SCNetworkSetGetSetID(item) as String? ?? ""
        if name == target || uuid == target {
            let res = SCNetworkSetSetCurrent(item)
            let res2 = SCPreferencesCommitChanges(prefs)
            let res3 = SCPreferencesApplyChanges(prefs)
            success = res || res2 || res3
            break
        }
    }
    lua_pushboolean(L, success ? 1 : 0)
    AuthorizationFree(authorization!, [.destroyRights])

    return 1
}

/// hs.network.configuration:location() -> location
/// Method
/// Returns the current location identifier
///
/// Parameters:
///  * None
///
/// Returns:
///  * location - the UUID for the currently active network location
///
/// Notes:
///  * You can also retrieve this information as key-value pairs with `hs.network.configuration:contents("Setup:")`
///  * If you have different locations defined in the Network preferences panel, this can be used to determine the currently active location.
private func dynamicStoreLocation(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    if let location = SCDynamicStoreCopyLocation(theStore) {
        lua_pushany(L, location as String)
    } else {
        throw LuaCallError("** error retrieving location:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

/// hs.network.configuration:locations() -> table
/// Method
/// Returns all configured locations
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table of key-value pairs mapping location UUIDs to their names
private func dynamicStoreLocations(_ L: LuaState) throws -> CInt {
    let _: HSDynamicStore = try L.checkArgument(1)
    guard let prefs = SCPreferencesCreate(nil, "Cosmic Hammer" as CFString, nil) else {
        lua_pushnil(L)
        return 1
    }

    guard let locations = SCNetworkSetCopyAll(prefs) as? [SCNetworkSet] else {
        lua_pushnil(L)
        return 1
    }

    let dict = NSMutableDictionary()
    for location in locations {
        let setID = SCNetworkSetGetSetID(location) as String? ?? ""
        let name = SCNetworkSetGetName(location) as String? ?? ""
        dict[setID] = name
    }
    lua_pushany(L, dict)

    return 1
}

/// hs.network.configuration:proxies() -> table
/// Method
/// Returns information about the currently active proxies, if any
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table of key-value pairs describing the current proxies in effect, both globally, and scoped to specific interfaces.
///
/// Notes:
///  * You can also retrieve this information as key-value pairs with `hs.network.configuration:contents("State:/Network/Global/Proxies")`
private func dynamicStoreProxies(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    if let proxies = SCDynamicStoreCopyProxies(theStore) {
        lua_pushany(L, proxies as NSDictionary)
    } else {
        throw LuaCallError("** error retrieving proxies:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

/// hs.network.configuration:setCallback(function) -> storeObject
/// Method
/// Set or remove the callback function for a store object
///
/// Parameters:
///  * a function or nil to set or remove the store object callback function
///
/// Returns:
///  * the store object
///
/// Notes:
///  * The callback function will be invoked each time a monitored key changes value and the callback function should accept two parameters: the storeObject itself, and an array of the keys which contain values that have changed.
///  * This method just sets the callback function.  You specify which keys to watch with [hs.network.configuration:monitorKeys](#monitorKeys) and start or stop the watcher with [hs.network.configuration:start](#start) or [hs.network.configuration:stop](#stop)
private func dynamicStoreSetCallback(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)

    // in either case, we need to remove an existing callback, so...
    obj.callback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        obj.callback = L.ref(index: 2)
        if obj.selfRefValue == nil {
            lua_pushvalue(L, 1)
            obj.selfRefValue = L.ref(index: -1)
            lua_pop(L, 1)
        }
    } else {
        obj.selfRefValue = nil
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.configuration:start() -> storeObject
/// Method
/// Starts watching the store object for changes to the monitored keys and invokes the callback function (if any) when a change occurs.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the store object
///
/// Notes:
///  * The callback function should be specified with [hs.network.configuration:setCallback](#setCallback) and the keys to monitor should be specified with [hs.network.configuration:monitorKeys](#monitorKeys).
private func dynamicStoreStartWatcher(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    if !obj.watcherEnabled {
        if SCDynamicStoreSetDispatchQueue(obj.storeObject!, dynamicStoreQueue) {
            obj.watcherEnabled = true
        } else {
            throw LuaCallError("unable to set watcher dispatch queue:\(String(cString: SCErrorString(SCError())))")
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.configuration:stop() -> storeObject
/// Method
/// Stops watching the store object for changes.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the store object
private func dynamicStoreStopWatcher(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    if !SCDynamicStoreSetDispatchQueue(obj.storeObject!, nil) {
        os_log(.debug, "%{public}s", "\(USERDATA_TAG):stop, error removing watcher from dispatch queue:\(SCErrorString(SCError()))")
    }
    obj.watcherEnabled = false
    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.configuration:monitorKeys([keys], [pattern]) -> storeObject
/// Method
/// Specify the key(s) or key pattern(s) to monitor for changes.
///
/// Parameters:
///  * keys    - a string or table of strings containing the keys or patterns of keys, if `pattern` is true.  Defaults to all keys.
///  * pattern - a boolean indicating wether or not the string(s) provided are to be considered regular expression patterns (true) or literal strings to match (false).  Defaults to false.
///
/// Returns:
///  * the store Object
///
/// Notes:
///  * if no parameters are provided, then all key-value pairs in the dynamic store are monitored for changes.
private func dynamicStoreMonitorKeys(_ L: LuaState) throws -> CInt {
    let obj: HSDynamicStore = try L.checkArgument(1)
    let theStore = obj.storeObject!

    var keys: NSArray
    var keysIsPattern = false
    if lua_gettop(L) == 1 {
        keys = [".*"] as NSArray
        keysIsPattern = true
    } else {
        if lua_type(L, 2) == LUA_TTABLE {
            keys = lua_tovalue(L, at: 2) as! NSArray
        } else {
            keys = [lua_tovalue(L, at: 2)!] as NSArray
        }
        if lua_gettop(L) == 3 { keysIsPattern = lua_toboolean(L, 3) != 0 }
    }

    let result: Bool
    if keysIsPattern {
        result = SCDynamicStoreSetNotificationKeys(theStore, nil, keys as CFArray)
    } else {
        result = SCDynamicStoreSetNotificationKeys(theStore, keys as CFArray, nil)
    }
    if result {
        lua_pushvalue(L, 1)
    } else {
        throw LuaCallError("** unable to set keys to monitor:\(String(cString: SCErrorString(SCError())))")
    }
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func meta_gc(_ L: LuaState) throws -> CInt {
    dynamicStoreQueue = nil
    return 0
}

@_cdecl("luaopen_hs_libnetworkconfiguration")
public func luaopen_hs_libnetworkconfiguration(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register idiomatic Metatable<HSDynamicStore> with LuaSwift.
        L.register(Metatable<HSDynamicStore>(
            fields: [
                "contents": .closure { L in try dynamicStoreContents(L) },
                "keys": .closure { L in try dynamicStoreKeys(L) },
                "dhcpInfo": .closure { L in try dynamicStoreDHCPInfo(L) },
                "computerName": .closure { L in try dynamicStoreComputerName(L) },
                "consoleUser": .closure { L in try dynamicStoreConsoleUser(L) },
                "hostname": .closure { L in try dynamicStoreLocalHostName(L) },
                "location": .closure { L in try dynamicStoreLocation(L) },
                "locations": .closure { L in try dynamicStoreLocations(L) },
                "proxies": .closure { L in try dynamicStoreProxies(L) },
                "monitorKeys": .closure { L in try dynamicStoreMonitorKeys(L) },
                "setCallback": .closure { L in try dynamicStoreSetCallback(L) },
                "setLocation": .closure { L in try dynamicStoreSetLocation(L) },
                "start": .closure { L in try dynamicStoreStartWatcher(L) },
                "stop": .closure { L in try dynamicStoreStopWatcher(L) },
            ],
            tostring: .closure { L in
                let _: HSDynamicStore = try L.checkArgument(1)
                let ptr = lua_topointer(L, 1)
                lua_pushany(L, "\(USERDATA_TAG): (\(String(describing: ptr)))" as NSString)
                return 1
            }
        ))

        // -- Post-registration metatable patching --
        L.pushMetatable(for: HSDynamicStore.self)

        // __eq: compare underlying SCDynamicStore objects
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            if let obj1: HSDynamicStore = L.touserdata(1),
               let obj2: HSDynamicStore = L.touserdata(2),
               let store1 = obj1.storeObject,
               let store2 = obj2.storeObject {
                lua_pushboolean(L, CFEqual(store1, store2) ? 1 : 0)
            } else {
                lua_pushboolean(L, 0)
            }
            return 1
        }, 0)
        lua_setfield(L, -2, "__eq")

        // __gc: teardown the watcher and deinitialize the Any box
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            if let obj: HSDynamicStore = L.touserdata(1) {
                obj.teardown()
            }
            let rawptr = lua_touserdata(L, 1)!
            let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
            anyPtr.deinitialize(count: 1)
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for core_getObjectMetatable and tostring
        lua_pushstring(L, USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        lua_pushstring(L, USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the legacy registry name
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(newStoreObject)
        lua_setfield(L, -2, "open")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        dynamicStoreQueue = DispatchQueue.global(qos: .utility)
    }
}
