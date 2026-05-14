/// === hs.webview.datastore ===
///
/// Provides methods to list and purge the various types of data used by websites visited with `hs.webview`.

import Foundation
import Cocoa
import WebKit
import LuaSkin

private let USERDATA_DS_TAG = "hs.webview.datastore"
private var refTable: Int32 = LUA_NOREF

private var backgroundCallbacks = NSMutableSet()

// MARK: - Module Functions

/// hs.webview.datastore.websiteDataTypes() -> table
/// Function
/// Returns a list of the currently available data types within a datastore.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a list of strings where each string is a specific data type stored in a datastore.
private func datastore_allWebsiteDataTypes(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(WKWebsiteDataStore.allWebsiteDataTypes() as NSSet)
    return 1
}

/// hs.webview.datastore.default() -> datastoreObject
/// Constructor
/// Returns an object representing the default datastore for Hammerspoon `hs.webview` instances.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a datastoreObject
///
/// Notes:
///  * this is the datastore used unless otherwise specified when creating an `hs.webview` instance.
private func datastore_newDefaultDataStore(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(WKWebsiteDataStore.default())
    return 1
}

/// hs.webview.datastore.newPrivate() -> datastoreObject
/// Constructor
/// Returns an object representing a newly created non-persistent (private) datastore for use with a Hammerspoon `hs.webview` instance.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a datastoreObject
///
/// Notes:
///  * The datastore represented by this object will be initially empty.  You can use this function to create a non-persistent datastore that you wish to share among multiple `hs.webview` instances.
private func datastore_newPrivateDataStore(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(WKWebsiteDataStore.nonPersistent())
    return 1
}

/// hs.webview.datastore.fromWebview(webview) -> datastoreObject
/// Constructor
/// Returns an object representing the datastore for the specified `hs.webview` instance.
///
/// Parameters:
///  * `webview` - an `hs.webview` instance (webviewObject)
///
/// Returns:
///  * a datastoreObject
private func datastore_fromWebview(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, "hs.webview", LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, "hs.webview")!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let theWindow = Unmanaged<NSWindow>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    let theView = theWindow.contentView as! WKWebView
    let theConfiguration = theView.configuration
    skin.pushNSObject(theConfiguration.websiteDataStore)
    return 1
}

// MARK: - Module Methods

/// hs.webview.datastore:fetchRecords([dataTypes], callback) -> datastoreObject
/// Method
/// Generates a list of the datastore records of the specified type, and invokes the callback function with the list.
///
/// Parameters:
///  * `dataTypes` - an optional string or table specifying the data types to fetch from the datastore.
///  * `callback`  - a function which accepts as it's argument an array-table containing tables with the following key-value pairs:
///    * `displayName` - a string containing the site's display name.
///    * `dataTypes`   - a table containing strings representing the types of data stored for the website.
///
/// Returns:
///  * the datastore object
private func datastore_fetchRecords(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_DS_TAG,
                   LS_TSTRING | LS_TTABLE | LS_TFUNCTION,
                   LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)

    let dataStore = skin.toNSObject(atIndex: 1) as! WKWebsiteDataStore
    var dataTypes: [String] = WKWebsiteDataStore.allWebsiteDataTypes().map { $0 as! String }

    lua_pushvalue(L, lua_gettop(L))
    let fnRef = skin.luaRef(refTable)
    backgroundCallbacks.add(NSNumber(value: fnRef))

    if lua_type(L, 2) == LUA_TSTRING {
        dataTypes = [skin.toNSObject(atIndex: 2) as! String]
    } else if lua_type(L, 2) == LUA_TTABLE {
        let arr = skin.toNSObject(atIndex: 2) as? [Any]
        if let arr = arr as? [String] {
            dataTypes = arr
        } else {
            return luaL_argerror(L, 2, "expected a string or an array of string values")
        }
    }

    let typeSet = Set(dataTypes)
    if !typeSet.isSubset(of: WKWebsiteDataStore.allWebsiteDataTypes() as! Set<String>) {
        return luaL_argerror(L, 3, "invalid datastore data type specified")
    }

    dataStore.fetchDataRecords(ofTypes: typeSet) { records in
        DispatchQueue.main.async {
            if backgroundCallbacks.contains(NSNumber(value: fnRef)) {
                let _skin = LuaSkin.shared(withState: nil)!
                _skin.pushLuaRef(refTable, ref: fnRef)
                _skin.pushNSObject(records as NSArray)
                _skin.protectedCallAndError("hs.webview.datastore:fetchRecords callback",
                                            nargs: 1, nresults: 0)
                _skin.luaUnref(refTable, ref: fnRef)
                backgroundCallbacks.remove(NSNumber(value: fnRef))
            }
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.datastore:removeRecordsFor(displayNames, dataTypes, [callback]) -> datastoreObject
/// Method
/// Remove data from the datastore of the specified type(s) for the specified site(s).
///
/// Parameters:
///  * `displayNames` - a string or array of strings specifying the display names (sites) to remove records for.
///  * `dataTypes`    - a string or array of strings specifying the types of data to remove from the datastore for the specified sites.
///  * `callback`     - an optional function, which should expect no arguments, that will be called when the specified items have been removed from the datastore.
///
/// Returns:
///  * the datastore object
private func datastore_removeRecords(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_DS_TAG,
                   LS_TTABLE | LS_TSTRING,
                   LS_TTABLE | LS_TSTRING,
                   LS_TFUNCTION | LS_TOPTIONAL,
                   LS_TBREAK)
    let dataStore = skin.toNSObject(atIndex: 1) as! WKWebsiteDataStore

    var recordNames: [String]
    var recordTypes: [String]
    var fnRef: Int32 = LUA_NOREF

    if lua_type(L, 2) == LUA_TSTRING {
        recordNames = [skin.toNSObject(atIndex: 2) as! String]
    } else {
        guard let arr = skin.toNSObject(atIndex: 2) as? [String] else {
            return luaL_argerror(L, 2, "expected a single string or an array of string values")
        }
        recordNames = arr
    }

    if lua_type(L, 3) == LUA_TSTRING {
        recordTypes = [skin.toNSObject(atIndex: 3) as! String]
    } else {
        guard let arr = skin.toNSObject(atIndex: 3) as? [String] else {
            return luaL_argerror(L, 3, "expected a single string or an array of string values")
        }
        recordTypes = arr
    }

    let typeSet = Set(recordTypes)
    if !typeSet.isSubset(of: WKWebsiteDataStore.allWebsiteDataTypes() as! Set<String>) {
        return luaL_argerror(L, 3, "invalid datastore data type specified")
    }

    if lua_type(L, 4) == LUA_TFUNCTION {
        lua_pushvalue(L, 4)
        fnRef = skin.luaRef(refTable)
        backgroundCallbacks.add(NSNumber(value: fnRef))
    }

    dataStore.fetchDataRecords(ofTypes: typeSet) { records in
        let targets = records.filter { recordNames.contains($0.displayName) }
        dataStore.removeData(ofTypes: typeSet, for: targets) {
            DispatchQueue.main.async {
                if fnRef != LUA_NOREF && backgroundCallbacks.contains(NSNumber(value: fnRef)) {
                    let _skin = LuaSkin.shared(withState: nil)!
                    _skin.pushLuaRef(refTable, ref: fnRef)
                    _skin.protectedCallAndError("hs.webview.datastore:removeRecordsFor callback",
                                                nargs: 0, nresults: 0)
                    _skin.luaUnref(refTable, ref: fnRef)
                    backgroundCallbacks.remove(NSNumber(value: fnRef))
                }
            }
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.datastore:removeRecordsAfter(date, dataTypes, [callback]) -> datastoreObject
/// Method
/// Removes the specified types of data from the datastore if the data was added or changed since the given date.
///
/// Parameters:
///  * `date`         - an integer representing seconds since `1970-01-01 00:00:00 +0000` (e.g. `os.time()`), or a string containing a date in RFC3339 format (`YYYY-MM-DD[T]HH:MM:SS[Z]`).
///  * `dataTypes`    - a string or array of strings specifying the types of data to remove from the datastore for the specified sites.
///  * `callback`     - an optional function, which should expect no arguments, that will be called when the specified items have been removed from the datastore.
///
/// Returns:
///  * the datastore object
private func datastore_removeDataFrom(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_DS_TAG,
                   LS_TNUMBER | LS_TINTEGER | LS_TSTRING,
                   LS_TTABLE | LS_TSTRING,
                   LS_TFUNCTION | LS_TOPTIONAL,
                   LS_TBREAK)
    let dataStore = skin.toNSObject(atIndex: 1) as! WKWebsiteDataStore

    var theDate: Date
    var recordTypes: [String]
    var fnRef: Int32 = LUA_NOREF

    if lua_type(L, 2) == LUA_TSTRING {
        let rfc3339DateFormatter = DateFormatter()
        let enUSPOSIXLocale = Locale(identifier: "en_US_POSIX")
        rfc3339DateFormatter.locale = enUSPOSIXLocale
        rfc3339DateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
        rfc3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let parsed = rfc3339DateFormatter.date(from: skin.toNSObject(atIndex: 2) as! String) else {
            return luaL_argerror(L, 2, "invalid date format")
        }
        theDate = parsed
    } else {
        theDate = Date(timeIntervalSince1970: TimeInterval(lua_tointeger(L, 2)))
    }

    if lua_type(L, 3) == LUA_TSTRING {
        recordTypes = [skin.toNSObject(atIndex: 3) as! String]
    } else {
        guard let arr = skin.toNSObject(atIndex: 3) as? [String] else {
            return luaL_argerror(L, 3, "expected a single string or an array of string values")
        }
        recordTypes = arr
    }

    let typeSet = Set(recordTypes)
    if !typeSet.isSubset(of: WKWebsiteDataStore.allWebsiteDataTypes() as! Set<String>) {
        return luaL_argerror(L, 3, "invalid datastore data type specified")
    }

    if lua_type(L, 4) == LUA_TFUNCTION {
        lua_pushvalue(L, 4)
        fnRef = skin.luaRef(refTable)
        backgroundCallbacks.add(NSNumber(value: fnRef))
    }

    dataStore.removeData(ofTypes: typeSet, modifiedSince: theDate) {
        DispatchQueue.main.async {
            if fnRef != LUA_NOREF && backgroundCallbacks.contains(NSNumber(value: fnRef)) {
                let _skin = LuaSkin.shared(withState: nil)!
                _skin.pushLuaRef(refTable, ref: fnRef)
                _skin.protectedCallAndError("hs.webview.datastore:removeRecordsAfter callback",
                                            nargs: 0, nresults: 0)
                _skin.luaUnref(refTable, ref: fnRef)
                backgroundCallbacks.remove(NSNumber(value: fnRef))
            }
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.datastore:persistent() -> bool
/// Method
/// Returns whether or not the datastore is persistent.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not the datastore is persistent (true) or private (false)
///
/// Notes:
///  * Note that this value is the inverse of `hs.webview:privateBrowsing()`, since private browsing uses a non-persistent datastore.
private func datastore_persistent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_DS_TAG, LS_TBREAK)
    let dataStore = skin.toNSObject(atIndex: 1) as! WKWebsiteDataStore
    lua_pushboolean(L, dataStore.isPersistent ? 1 : 0)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushWKWebsiteDataStore(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let value = obj as! WKWebsiteDataStore
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_DS_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func pushWKWebsiteDataRecord(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let value = obj as! WKWebsiteDataRecord

    lua_newtable(L)
    skin.pushNSObject(value.displayName as NSString)
    lua_setfield(L, -2, "displayName")
    skin.pushNSObject(value.dataTypes as NSSet)
    lua_setfield(L, -2, "dataTypes")
    return 1
}

private func toWKWebsiteDataStoreFromLua(_ L: OpaquePointer!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.shared(withState: L)!
    if luaL_testudata(L, idx, USERDATA_DS_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_DS_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<WKWebsiteDataStore>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        skin.logError(String(format: "expected %s object, found %s",
                             USERDATA_DS_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let obj = skin.luaObject(atIndex: 1, toClass: "WKWebsiteDataStore") as? WKWebsiteDataStore
    let title: String = (obj?.isPersistent ?? false) ? "persistent" : "non-persistent"
    skin.pushNSObject(String(format: "%s: %@ (%p)", USERDATA_DS_TAG, title as NSString, lua_topointer(L, 1)!) as NSString)
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_DS_TAG) != nil && luaL_testudata(L, 2, USERDATA_DS_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)!
        let obj1 = skin.luaObject(atIndex: 1, toClass: "WKWebsiteDataStore") as? WKWebsiteDataStore
        let obj2 = skin.luaObject(atIndex: 2, toClass: "WKWebsiteDataStore") as? WKWebsiteDataStore
        lua_pushboolean(L, (obj1 != nil && obj2 != nil && obj1!.isEqual(obj2!)) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_DS_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let _ = Unmanaged<WKWebsiteDataStore>.fromOpaque(rawPtr).takeRetainedValue()
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    backgroundCallbacks.enumerateObjects { obj, _ in
        if let ref = obj as? NSNumber {
            skin.luaUnref(refTable, ref: ref.int32Value)
        }
    }
    backgroundCallbacks.removeAllObjects()
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("fetchRecords"), func: datastore_fetchRecords),
    luaL_Reg(name: strdup("removeRecordsFor"), func: datastore_removeRecords),
    luaL_Reg(name: strdup("removeRecordsAfter"), func: datastore_removeDataFrom),
    luaL_Reg(name: strdup("persistent"), func: datastore_persistent),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("websiteDataTypes"), func: datastore_allWebsiteDataTypes),
    luaL_Reg(name: strdup("default"), func: datastore_newDefaultDataStore),
    luaL_Reg(name: strdup("newPrivate"), func: datastore_newPrivateDataStore),
    luaL_Reg(name: strdup("fromWebview"), func: datastore_fromWebview),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwebviewdatastore")
public func luaopen_hs_libwebviewdatastore(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!

    refTable = skin.registerLibrary(withObject: USERDATA_DS_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushWKWebsiteDataStore, forClass: "WKWebsiteDataStore")
    skin.registerPushNSHelper(pushWKWebsiteDataRecord, forClass: "WKWebsiteDataRecord")

    skin.registerLuaObjectHelper(toWKWebsiteDataStoreFromLua, forClass: "WKWebsiteDataStore",
                                 withUserdataMapping: USERDATA_DS_TAG)

    backgroundCallbacks = NSMutableSet()
    return 1
}
