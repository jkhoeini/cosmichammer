import Cocoa
import LuaSkin
import SystemConfiguration

private let USERDATA_TAG = "hs.network.configuration"
private var refTable: LSRefTable = LUA_NOREF
private var dynamicStoreQueue: DispatchQueue! = nil

private struct DynamicStoreData {
    var storeObject: SCDynamicStore?
    var callbackRef: Int32
    var selfRef: Int32
    var watcherEnabled: Bool
    var lsCanary: LSGCCanary
}

private func getPtr(_ L: OpaquePointer!, _ idx: Int32) -> UnsafeMutablePointer<DynamicStoreData> {
    return luaL_checkudata(L, idx, USERDATA_TAG)!.assumingMemoryBound(to: DynamicStoreData.self)
}

// MARK: - Support Functions

private let doDynamicStoreCallback: SCDynamicStoreCallBack = { store, changedKeys, info in
    guard let info = info else { return }
    let thePtr = info.assumingMemoryBound(to: DynamicStoreData.self)
    let nsChangedKeys = (changedKeys as NSArray).copy() as! NSArray
    DispatchQueue.main.async {
        if thePtr.pointee.callbackRef != LUA_NOREF && thePtr.pointee.selfRef != LUA_NOREF {
            let skin = LuaSkin.shared(withState: nil)
            let L = skin.L!
            if !skin.checkGCCanary(thePtr.pointee.lsCanary) {
                return
            }
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: thePtr.pointee.callbackRef)
            skin.pushLuaRef(refTable, ref: thePtr.pointee.selfRef)
            skin.pushNSObject(nsChangedKeys)
            skin.protectedCallAndError("hs.network.configuration callback", nargs: 2, nresults: 0)
            _lua_stackguard_exit(L)
        }
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
private func newStoreObject(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)
    let theName = UUID().uuidString
    let thePtr = lua_newuserdata(L, MemoryLayout<DynamicStoreData>.size)!.assumingMemoryBound(to: DynamicStoreData.self)
    memset(thePtr, 0, MemoryLayout<DynamicStoreData>.size)

    var context = SCDynamicStoreContext(version: 0, info: thePtr, retain: nil, release: nil, copyDescription: nil)
    if let theStore = SCDynamicStoreCreate(kCFAllocatorDefault, theName as CFString, doDynamicStoreCallback, &context) {
        thePtr.pointee.storeObject = theStore
        thePtr.pointee.callbackRef = LUA_NOREF
        thePtr.pointee.selfRef = LUA_NOREF
        thePtr.pointee.watcherEnabled = false
        thePtr.pointee.lsCanary = skin.createGCCanary()

        luaL_getmetatable(L, USERDATA_TAG)
        lua_setmetatable(L, -2)
    } else {
        return luaL_error(L, "** unable to get dynamicStore reference:%s", SCErrorString(SCError()))
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
private func dynamicStoreContents(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TSTRING | LS_TTABLE | LS_TOPTIONAL,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    var keys: NSArray
    var keysIsPattern = false
    if lua_gettop(L) == 1 {
        keys = [".*"] as NSArray
        keysIsPattern = true
    } else {
        if lua_type(L, 2) == LUA_TTABLE {
            keys = skin.toNSObject(atIndex: 2) as! NSArray
        } else {
            keys = [skin.toNSObject(atIndex: 2)!] as NSArray
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
        skin.pushNSObject(results as NSDictionary, withOptions: UInt(LS_NSDescribeUnknownTypes | LS_NSUnsignedLongLongPreserveBits))
    } else {
        return luaL_error(L, "** unable to get dynamicStore contents:%s", SCErrorString(SCError()))
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
private func dynamicStoreKeys(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    let keysPattern: String = (lua_gettop(L) == 1) ? ".*" : (skin.toNSObject(atIndex: 2) as! String)
    if let results = SCDynamicStoreCopyKeyList(theStore, keysPattern as CFString) {
        skin.pushNSObject(results as NSArray, withOptions: UInt(LS_NSDescribeUnknownTypes | LS_NSUnsignedLongLongPreserveBits))
    } else {
        return luaL_error(L, "** unable to get dynamicStore keys:%s", SCErrorString(SCError()))
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
private func dynamicStoreDHCPInfo(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    let serviceID: CFString?
    if lua_gettop(L) == 2 {
        serviceID = (skin.toNSObject(atIndex: 2) as! String) as CFString
    } else {
        serviceID = nil
    }

    if let results = SCDynamicStoreCopyDHCPInfo(theStore, serviceID) {
        skin.pushNSObject(results as NSDictionary, withOptions: UInt(LS_NSDescribeUnknownTypes | LS_NSUnsignedLongLongPreserveBits))
    } else {
        return luaL_error(L, "** unable to get DHCP info:%s", SCErrorString(SCError()))
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
private func dynamicStoreComputerName(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    var encoding: CFStringEncoding = 0
    if let computerName = SCDynamicStoreCopyComputerName(theStore, &encoding) {
        skin.pushNSObject(computerName as String)
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
        skin.pushNSObject(encodingName)
    } else {
        return luaL_error(L, "** error retrieving computer name:%s", SCErrorString(SCError()))
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
private func dynamicStoreConsoleUser(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    var uid: uid_t = 0
    var gid: gid_t = 0
    if let consoleUser = SCDynamicStoreCopyConsoleUser(theStore, &uid, &gid) {
        skin.pushNSObject(consoleUser as String)
        lua_pushinteger(L, lua_Integer(uid))
        lua_pushinteger(L, lua_Integer(gid))
    } else {
        return luaL_error(L, "** error retrieving console user:%s", SCErrorString(SCError()))
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
private func dynamicStoreLocalHostName(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    if let localHostName = SCDynamicStoreCopyLocalHostName(theStore) {
        skin.pushNSObject(localHostName as String)
    } else {
        return luaL_error(L, "** error retrieving local host name:%s", SCErrorString(SCError()))
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
private func dynamicStoreSetLocation(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)

    let target = skin.toNSObject(atIndex: 2) as! String

    var authorization: AuthorizationRef?
    let flags: AuthorizationFlags = [.defaults]
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
private func dynamicStoreLocation(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    if let location = SCDynamicStoreCopyLocation(theStore) {
        skin.pushNSObject(location as String)
    } else {
        return luaL_error(L, "** error retrieving location:%s", SCErrorString(SCError()))
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
private func dynamicStoreLocations(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    guard let prefs = SCPreferencesCreate(nil, "Hammerspoon" as CFString, nil) else {
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
    skin.pushNSObject(dict)

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
private func dynamicStoreProxies(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    if let proxies = SCDynamicStoreCopyProxies(theStore) {
        skin.pushNSObject(proxies as NSDictionary)
    } else {
        return luaL_error(L, "** error retrieving proxies:%s", SCErrorString(SCError()))
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
private func dynamicStoreSetCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let thePtr = getPtr(L, 1)

    // in either case, we need to remove an existing callback, so...
    thePtr.pointee.callbackRef = skin.luaUnref(refTable, ref: thePtr.pointee.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        thePtr.pointee.callbackRef = skin.luaRef(refTable)
        if thePtr.pointee.selfRef == LUA_NOREF {
            lua_pushvalue(L, 1)
            thePtr.pointee.selfRef = skin.luaRef(refTable)
        }
    } else {
        thePtr.pointee.selfRef = skin.luaUnref(refTable, ref: thePtr.pointee.selfRef)
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
private func dynamicStoreStartWatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let thePtr = getPtr(L, 1)
    if !thePtr.pointee.watcherEnabled {
        if SCDynamicStoreSetDispatchQueue(thePtr.pointee.storeObject!, dynamicStoreQueue) {
            thePtr.pointee.watcherEnabled = true
        } else {
            return luaL_error(L, "unable to set watcher dispatch queue:%s", SCErrorString(SCError()))
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
private func dynamicStoreStopWatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let thePtr = getPtr(L, 1)
    if !SCDynamicStoreSetDispatchQueue(thePtr.pointee.storeObject!, nil) {
        skin.logBreadcrumb("\(USERDATA_TAG):stop, error removing watcher from dispatch queue:\(SCErrorString(SCError()))")
    }
    thePtr.pointee.watcherEnabled = false
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
private func dynamicStoreMonitorKeys(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TSTRING | LS_TTABLE | LS_TOPTIONAL,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let theStore = getPtr(L, 1).pointee.storeObject!

    var keys: NSArray
    var keysIsPattern = false
    if lua_gettop(L) == 1 {
        keys = [".*"] as NSArray
        keysIsPattern = true
    } else {
        if lua_type(L, 2) == LUA_TTABLE {
            keys = skin.toNSObject(atIndex: 2) as! NSArray
        } else {
            keys = [skin.toNSObject(atIndex: 2)!] as NSArray
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
        return luaL_error(L, "** unable to set keys to monitor:%s", SCErrorString(SCError()))
    }
    return 1
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject("\(USERDATA_TAG): (\(String(describing: ptr)))" as NSString)
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let theStore1 = getPtr(L, 1).pointee.storeObject!
        let theStore2 = getPtr(L, 2).pointee.storeObject!
        lua_pushboolean(L, CFEqual(theStore1, theStore2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let thePtr = getPtr(L, 1)
    if thePtr.pointee.callbackRef != LUA_NOREF {
        thePtr.pointee.callbackRef = skin.luaUnref(refTable, ref: thePtr.pointee.callbackRef)
        if !SCDynamicStoreSetDispatchQueue(thePtr.pointee.storeObject!, nil) {
            skin.logBreadcrumb("\(USERDATA_TAG):__gc, error removing watcher from dispatch queue:\(SCErrorString(SCError()))")
        }
    }
    thePtr.pointee.selfRef = skin.luaUnref(refTable, ref: thePtr.pointee.selfRef)
    skin.destroyGCCanary(&thePtr.pointee.lsCanary)

    // storeObject is managed by Swift ARC through the optional, no explicit CFRelease needed
    thePtr.pointee.storeObject = nil
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    dynamicStoreQueue = nil
    return 0
}

// Metatable for userdata objects
private let userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: ("contents" as NSString).utf8String, func: dynamicStoreContents),
    luaL_Reg(name: ("keys" as NSString).utf8String, func: dynamicStoreKeys),
    luaL_Reg(name: ("dhcpInfo" as NSString).utf8String, func: dynamicStoreDHCPInfo),
    luaL_Reg(name: ("computerName" as NSString).utf8String, func: dynamicStoreComputerName),
    luaL_Reg(name: ("consoleUser" as NSString).utf8String, func: dynamicStoreConsoleUser),
    luaL_Reg(name: ("hostname" as NSString).utf8String, func: dynamicStoreLocalHostName),
    luaL_Reg(name: ("location" as NSString).utf8String, func: dynamicStoreLocation),
    luaL_Reg(name: ("locations" as NSString).utf8String, func: dynamicStoreLocations),
    luaL_Reg(name: ("proxies" as NSString).utf8String, func: dynamicStoreProxies),
    luaL_Reg(name: ("monitorKeys" as NSString).utf8String, func: dynamicStoreMonitorKeys),
    luaL_Reg(name: ("setCallback" as NSString).utf8String, func: dynamicStoreSetCallback),
    luaL_Reg(name: ("setLocation" as NSString).utf8String, func: dynamicStoreSetLocation),
    luaL_Reg(name: ("start" as NSString).utf8String, func: dynamicStoreStartWatcher),
    luaL_Reg(name: ("stop" as NSString).utf8String, func: dynamicStoreStopWatcher),

    luaL_Reg(name: ("__tostring" as NSString).utf8String, func: userdata_tostring),
    luaL_Reg(name: ("__eq" as NSString).utf8String, func: userdata_eq),
    luaL_Reg(name: ("__gc" as NSString).utf8String, func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: ("open" as NSString).utf8String, func: newStoreObject),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private let module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: ("__gc" as NSString).utf8String, func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libnetworkconfiguration")
public func luaopen_hs_libnetworkconfiguration(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: moduleLib,
                                    metaFunctions: module_metaLib,
                                    objectFunctions: userdata_metaLib)

    dynamicStoreQueue = DispatchQueue.global(qos: .utility)

    return 1
}
