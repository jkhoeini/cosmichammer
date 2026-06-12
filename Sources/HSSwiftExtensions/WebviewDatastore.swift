/// === hs.webview.datastore ===
///
/// Provides methods to list and purge the various types of data used by websites visited with `hs.webview`.

import Foundation
import CLua
import Lua
import Cocoa
import WebKit
import os.log

private let USERDATA_DS_TAG = "hs.webview.datastore"

/// Holds LuaValue refs for in-flight async callbacks so they stay alive until completion.
private var backgroundCallbacks: [ObjectIdentifier: LuaValue] = [:]

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
private func datastore_allWebsiteDataTypes(_ L: LuaState) throws -> CInt {
    lua_pushany(L, Array(WKWebsiteDataStore.allWebsiteDataTypes()) as NSArray)
    return 1
}

/// hs.webview.datastore.default() -> datastoreObject
/// Constructor
/// Returns an object representing the default datastore for Cosmic Hammer `hs.webview` instances.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a datastoreObject
///
/// Notes:
///  * this is the datastore used unless otherwise specified when creating an `hs.webview` instance.
private func datastore_newDefaultDataStore(_ L: LuaState) throws -> CInt {
    wv_pushAny(L, WKWebsiteDataStore.default())
    return 1
}

/// hs.webview.datastore.newPrivate() -> datastoreObject
/// Constructor
/// Returns an object representing a newly created non-persistent (private) datastore for use with a Cosmic Hammer `hs.webview` instance.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a datastoreObject
///
/// Notes:
///  * The datastore represented by this object will be initially empty.  You can use this function to create a non-persistent datastore that you wish to share among multiple `hs.webview` instances.
private func datastore_newPrivateDataStore(_ L: LuaState) throws -> CInt {
    wv_pushAny(L, WKWebsiteDataStore.nonPersistent())
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
private func datastore_fromWebview(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, "hs.webview")!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let theWindow = Unmanaged<NSWindow>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    let theView = theWindow.contentView as! WKWebView
    let theConfiguration = theView.configuration
    wv_pushAny(L, theConfiguration.websiteDataStore)
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
private func datastore_fetchRecords(_ L: LuaState) throws -> CInt {

    let dataStore = wv_toWKWebsiteDataStore(L, 1)!
    var dataTypes: [String] = Array(WKWebsiteDataStore.allWebsiteDataTypes())

    let fnValue = L.ref(index: lua_gettop(L))
    let key = ObjectIdentifier(fnValue)
    backgroundCallbacks[key] = fnValue

    if lua_type(L, 2) == LUA_TSTRING {
        dataTypes = [lua_tovalue(L, at: 2) as! String]
    } else if lua_type(L, 2) == LUA_TTABLE {
        let arr = lua_tovalue(L, at: 2) as? [Any]
        if let arr = arr as? [String] {
            dataTypes = arr
        } else {
            throw LuaCallError("bad argument #2 (expected a string or an array of string values)")
        }
    }

    let typeSet = Set(dataTypes)
    if !typeSet.isSubset(of: WKWebsiteDataStore.allWebsiteDataTypes()) {
        throw LuaCallError("bad argument #3 (invalid datastore data type specified)")
    }

    dataStore.fetchDataRecords(ofTypes: typeSet) { records in
        DispatchQueue.main.async {
            if backgroundCallbacks[key] != nil {
                fnValue.push(onto: L)
                lua_createtable(L, Int32(records.count), 0)
                for record in records {
                    wv_pushAny(L, record)
                    lua_rawseti(L, -2, luaL_len(L, -2) + 1)
                }
                if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
                backgroundCallbacks.removeValue(forKey: key)
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
private func datastore_removeRecords(_ L: LuaState) throws -> CInt {
    let dataStore = wv_toWKWebsiteDataStore(L, 1)!

    var recordNames: [String]
    var recordTypes: [String]
    var fnValue: LuaValue?
    var key: ObjectIdentifier?

    if lua_type(L, 2) == LUA_TSTRING {
        recordNames = [lua_tovalue(L, at: 2) as! String]
    } else {
        guard let arr = lua_tovalue(L, at: 2) as? [String] else {
            throw LuaCallError("bad argument #2 (expected a single string or an array of string values)")
        }
        recordNames = arr
    }

    if lua_type(L, 3) == LUA_TSTRING {
        recordTypes = [lua_tovalue(L, at: 3) as! String]
    } else {
        guard let arr = lua_tovalue(L, at: 3) as? [String] else {
            throw LuaCallError("bad argument #3 (expected a single string or an array of string values)")
        }
        recordTypes = arr
    }

    let typeSet = Set(recordTypes)
    if !typeSet.isSubset(of: WKWebsiteDataStore.allWebsiteDataTypes()) {
        throw LuaCallError("bad argument #3 (invalid datastore data type specified)")
    }

    if lua_type(L, 4) == LUA_TFUNCTION {
        let val = L.ref(index: 4)
        fnValue = val
        key = ObjectIdentifier(val)
        backgroundCallbacks[key!] = val
    }

    dataStore.fetchDataRecords(ofTypes: typeSet) { records in
        let targets = records.filter { recordNames.contains($0.displayName) }
        dataStore.removeData(ofTypes: typeSet, for: targets) {
            DispatchQueue.main.async {
                if let k = key, let cb = fnValue, backgroundCallbacks[k] != nil {
                    cb.push(onto: L)
                    if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
                    backgroundCallbacks.removeValue(forKey: k)
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
private func datastore_removeDataFrom(_ L: LuaState) throws -> CInt {
    let dataStore = wv_toWKWebsiteDataStore(L, 1)!

    var theDate: Date
    var recordTypes: [String]
    var fnValue: LuaValue?
    var key: ObjectIdentifier?

    if lua_type(L, 2) == LUA_TSTRING {
        let rfc3339DateFormatter = DateFormatter()
        let enUSPOSIXLocale = Locale(identifier: "en_US_POSIX")
        rfc3339DateFormatter.locale = enUSPOSIXLocale
        rfc3339DateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
        rfc3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let parsed = rfc3339DateFormatter.date(from: lua_tovalue(L, at: 2) as! String) else {
            throw LuaCallError("bad argument #2 (invalid date format)")
        }
        theDate = parsed
    } else {
        theDate = Date(timeIntervalSince1970: TimeInterval(lua_tointeger(L, 2)))
    }

    if lua_type(L, 3) == LUA_TSTRING {
        recordTypes = [lua_tovalue(L, at: 3) as! String]
    } else {
        guard let arr = lua_tovalue(L, at: 3) as? [String] else {
            throw LuaCallError("bad argument #3 (expected a single string or an array of string values)")
        }
        recordTypes = arr
    }

    let typeSet = Set(recordTypes)
    if !typeSet.isSubset(of: WKWebsiteDataStore.allWebsiteDataTypes()) {
        throw LuaCallError("bad argument #3 (invalid datastore data type specified)")
    }

    if lua_type(L, 4) == LUA_TFUNCTION {
        let val = L.ref(index: 4)
        fnValue = val
        key = ObjectIdentifier(val)
        backgroundCallbacks[key!] = val
    }

    dataStore.removeData(ofTypes: typeSet, modifiedSince: theDate) {
        DispatchQueue.main.async {
            if let k = key, let cb = fnValue, backgroundCallbacks[k] != nil {
                cb.push(onto: L)
                if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
                backgroundCallbacks.removeValue(forKey: k)
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
private func datastore_persistent(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_DS_TAG)
    let dataStore = wv_toWKWebsiteDataStore(L, 1)!
    lua_pushboolean(L, dataStore.isPersistent ? 1 : 0)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushWKWebsiteDataStore(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let value = obj as! WKWebsiteDataStore
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_DS_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func pushWKWebsiteDataRecord(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let value = obj as! WKWebsiteDataRecord

    lua_newtable(L)
    lua_pushany(L, value.displayName as NSString)
    lua_setfield(L, -2, "displayName")
    lua_pushany(L, Array(value.dataTypes) as NSArray)
    lua_setfield(L, -2, "dataTypes")
    return 1
}

private func toWKWebsiteDataStoreFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    if luaL_testudata(L, idx, USERDATA_DS_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_DS_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<WKWebsiteDataStore>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        os_log(.error, "%{public}s", String(format: "expected %s object, found %s",
                             USERDATA_DS_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

func wv_WKWebsiteDataStore_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    return pushWKWebsiteDataStore(L, obj)
}

func wv_WKWebsiteDataRecord_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    return pushWKWebsiteDataRecord(L, obj)
}

func wv_toWKWebsiteDataStore(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> WKWebsiteDataStore? {
    return toWKWebsiteDataStoreFromLua(L, idx) as? WKWebsiteDataStore
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = wv_toWKWebsiteDataStore(L, 1)
    let title: String = (obj?.isPersistent ?? false) ? "persistent" : "non-persistent"
    let ptr = lua_topointer(L, 1)
    let ptrStr = ptr.map { String(describing: $0) } ?? "nil"
    lua_pushstring(L, "\(USERDATA_DS_TAG): \(title) (\(ptrStr))")
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, USERDATA_DS_TAG) != nil && luaL_testudata(L, 2, USERDATA_DS_TAG) != nil {
        let obj1 = wv_toWKWebsiteDataStore(L, 1)
        let obj2 = wv_toWKWebsiteDataStore(L, 2)
        lua_pushboolean(L, (obj1 != nil && obj2 != nil && obj1!.isEqual(obj2!)) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
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

private func meta_gc(_ L: LuaState) throws -> CInt {
    backgroundCallbacks.removeAll()
    return 0
}


@_cdecl("luaopen_hs_libwebviewdatastore")
public func luaopen_hs_libwebviewdatastore(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        luaL_newmetatable(L, USERDATA_DS_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(datastore_fetchRecords)
        lua_setfield(L, -2, "fetchRecords")
        L.push(datastore_removeRecords)
        lua_setfield(L, -2, "removeRecordsFor")
        L.push(datastore_removeDataFrom)
        lua_setfield(L, -2, "removeRecordsAfter")
        L.push(datastore_persistent)
        lua_setfield(L, -2, "persistent")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        lua_createtable(L, 0, 4)
        L.push(datastore_allWebsiteDataTypes)
        lua_setfield(L, -2, "websiteDataTypes")
        L.push(datastore_newDefaultDataStore)
        lua_setfield(L, -2, "default")
        L.push(datastore_newPrivateDataStore)
        lua_setfield(L, -2, "newPrivate")
        L.push(datastore_fromWebview)
        lua_setfield(L, -2, "fromWebview")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        backgroundCallbacks = [:]
    }
}
