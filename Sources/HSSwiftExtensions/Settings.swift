import Cocoa
import CLua
import Lua

// Establish a unique context for identifying our observers
private var myKVOContext: Int = 0 // See http://nshipster.com/key-value-observing/

// MARK: - HSUserDefaultKVOWatcher

private class HSUserDefaultKVOWatcher: NSObject {
    var watchedKeys = NSMutableDictionary()

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &myKVOContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        guard let keyPath = keyPath, let fnCallbacks = watchedKeys[keyPath] as? NSMutableDictionary else { return }

        DispatchQueue.main.async {
            let L = lua_getCurrentState()!
            fnCallbacks.enumerateKeysAndObjects { _, refN, _ in
                let ref = (refN as! NSNumber).int32Value
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(ref))
                lua_pushany(L, keyPath)
                if lua_pcall(L, 1, 0, 0) != LUA_OK {
                    lua_pop(L, 1)
                }
            }
        }
    }
}

private var watcherManager: HSUserDefaultKVOWatcher!

// MARK: - Lua callbacks

/// hs.settings.set(key[, val])
/// Function
/// Saves a setting with common datatypes
///
/// Parameters:
///  * key - A string containing the name of the setting
///  * val - An optional value for the setting. Valid datatypes are:
///    * string
///    * number
///    * boolean
///    * nil
///    * table (which may contain any of the same valid datatypes)
///
/// Returns:
///  * None
///
/// Notes:
///  * If no val parameter is provided, it is assumed to be nil
///  * This function cannot set dates or raw data types, see `hs.settings.setDate()` and `hs.settings.setData()`
///  * Assigning a nil value is equivalent to clearing the value with `hs.settings.clear`
private func target_set(_ L: LuaState) throws -> CInt {
    guard lua_type(L, 1) == LUA_TSTRING else {
        throw LuaCallError("expected string for argument 1")
    }

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        throw LuaCallError("key must be a valid UTF8 string")
    }

    // Allow for missing second argument for backwards compatibility
    var val: Any? = nil
    if lua_gettop(L) == 2 {
        val = lua_tovalue(L, at: 2)
    }

    UserDefaults.standard.set(val, forKey: key)
    return 0
}

/// hs.settings.setData(key, val)
/// Function
/// Saves a setting with raw binary data
///
/// Parameters:
///  * key - A string containing the name of the setting
///  * val - Some raw binary data
///
/// Returns:
///  * None
private func target_setData(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    luaL_checktype(L, 2, LUA_TSTRING)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        throw LuaCallError("key must be a valid UTF8 string")
    }

    if lua_type(L, 2) == LUA_TSTRING {
        var sz: Int = 0
        let dataPtr = lua_tolstring(L, 2, &sz)!
        let data = Data(bytes: dataPtr, count: sz)
        UserDefaults.standard.set(data, forKey: key)
    } else {
        throw LuaCallError("second argument not (binary data encapsulated as) a string")
    }

    return 0
}

private func date_from_string(_ dateString: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: dateString)
}

/// hs.settings.setDate(key, val)
/// Function
/// Saves a setting with a date
///
/// Parameters:
///  * key - A string containing the name of the setting
///  * val - A number representing seconds since `1970-01-01 00:00:00 +0000` (e.g. `os.time()`), or a string containing a date in RFC3339 format (`YYYY-MM-DD[T]HH:MM:SS[Z]`)
///
/// Returns:
///  * None
///
/// Notes:
///  * See `hs.settings.dateFormat` for a convenient representation of the RFC3339 format, to use with other time/date related functions
private func target_setDate(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        throw LuaCallError("key must be a valid UTF8 string")
    }

    let myDate: Date?
    if lua_isnumber(L, 2) {
        myDate = Date(timeIntervalSince1970: TimeInterval(lua_tonumber(L, 2)))
    } else if lua_isstring(L, 2) {
        myDate = date_from_string(String(cString: lua_tostring(L, 2)!))
    } else {
        myDate = nil
    }

    if let date = myDate {
        UserDefaults.standard.set(date, forKey: key)
    } else {
        throw LuaCallError("Not a date type -- Number: # of seconds since 1970-01-01 00:00:00Z or String: in the format of 'YYYY-MM-DD[T]HH:MM:SS[Z]' (rfc3339)")
    }
    return 0
}

/// hs.settings.get(key) -> string or boolean or number or nil or table or binary data
/// Function
/// Loads a setting
///
/// Parameters:
///  * key - A string containing the name of the setting
///
/// Returns:
///  * The value of the setting
///
/// Notes:
///  * This function can load all of the datatypes supported by `hs.settings.set()`, `hs.settings.setData()` and `hs.settings.setDate()`
private func target_get(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        throw LuaCallError("key must be a valid UTF8 string")
    }

    let val = UserDefaults.standard.object(forKey: key)
    lua_pushany(L, val)
    return 1
}

/// hs.settings.clear(key) -> bool
/// Function
/// Deletes a setting
///
/// Parameters:
///  * key - A string containing the name of a setting
///
/// Returns:
///  * A boolean, true if the setting was deleted, otherwise false
private func target_clear(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        throw LuaCallError("key must be a valid UTF8 string")
    }

    let defaults = UserDefaults.standard
    if defaults.object(forKey: key) != nil && !defaults.objectIsForced(forKey: key) {
        defaults.removeObject(forKey: key)
        lua_pushboolean(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.settings.getKeys() -> table
/// Function
/// Gets all of the previously stored setting names
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing all of the settings keys in Cosmic Hammer's settings
///
/// Notes:
///  * Use `ipairs(hs.settings.getKeys())` to iterate over all available settings
///  * Use `hs.settings.getKeys()["someKey"]` to test for the existence of a particular key
private func target_getKeys(_ L: LuaState) throws -> CInt {
    let mainID = Bundle.main.bundleIdentifier ?? ""
    let keys = UserDefaults.standard.persistentDomain(forName: mainID)?.keys.sorted() ?? []

    lua_newtable(L)
    for (i, key) in keys.enumerated() {
        lua_pushinteger(L, lua_Integer(i + 1))
        lua_pushstring(L, key)
        lua_settable(L, -3)

        lua_pushstring(L, key)
        lua_pushboolean(L, 1)
        lua_settable(L, -3)
    }
    return 1
}

/// hs.settings.watchKey(identifier, key, [fn]) -> identifier | current value
/// Function
/// Get or set a watcher to invoke a callback when the specified settings key changes
///
/// Parameters:
///  * identifier - a required string used as an identifier for this callback
///  * key        - the settings key to watch for changes to
///  * fn         - the callback function to be invoked when the specified key changes.  If this is an explicit nil, removes the existing callback.
///
/// Returns:
///  * if a callback is set or removed, returns the identifier; otherwise returns the current callback function or nil if no callback function is currently defined.
///
/// Notes:
///  * the identifier is required so that multiple callbacks for the same key can be registered by separate modules; it's value doesn't affect what is being watched but does need to be unique between multiple watchers of the same key.
///  * Does not work with keys that include a period (.) in the key name because KVO uses dot notation to specify a sequence of properties.  If you know of a way to escape periods so that they are watchable as NSUSerDefault key names, please file an issue and share!
private func target_watchKey(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    luaL_checktype(L, 2, LUA_TSTRING)

    let watcherID = String(cString: lua_tostring(L, 1)!) as NSString
    let keyPath = String(cString: lua_tostring(L, 2)!) as NSString

    if watcherManager.watchedKeys[keyPath] == nil {
        watcherManager.watchedKeys[keyPath] = NSMutableDictionary()
        _ = catchingObjCException {
            UserDefaults.standard.addObserver(watcherManager, forKeyPath: keyPath as String,
                                              options: .new, context: &myKVOContext)
        }
    }

    let keyWatchers = watcherManager.watchedKeys[keyPath] as! NSMutableDictionary
    let refN = keyWatchers[watcherID] as? NSNumber

    if lua_gettop(L) == 2 {
        if let ref = refN {
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(ref.int32Value))
        } else {
            lua_pushnil(L)
        }
    } else {
        if let ref = refN {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, ref.int32Value)
        }
        keyWatchers[watcherID] = nil
        if lua_type(L, 3) != LUA_TNIL {
            lua_pushvalue(L, 3)
            keyWatchers[watcherID] = NSNumber(value: luaL_ref(L, LUA_REGISTRYINDEX_VALUE))
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

// For debugging
private func output_watchers(_ L: LuaState) throws -> CInt {
    lua_pushany(L, watcherManager.watchedKeys)
    return 1
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    watcherManager.watchedKeys.enumerateKeysAndObjects { keyPath, watchers, _ in
        _ = catchingObjCException {
            UserDefaults.standard.removeObserver(watcherManager!, forKeyPath: keyPath as! String, context: &myKVOContext)
        }
        (watchers as! NSMutableDictionary).enumerateKeysAndObjects { _, refN, _ in
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, (refN as! NSNumber).int32Value)
        }
    }
    watcherManager.watchedKeys.removeAllObjects()
    watcherManager = nil
    return 0
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libsettings")
public func luaopen_hs_libsettings(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 10)
        L.push( target_set)
        lua_setfield(L, -2, "set")
        L.push( target_setData)
        lua_setfield(L, -2, "setData")
        L.push( target_setDate)
        lua_setfield(L, -2, "setDate")
        L.push( target_get)
        lua_setfield(L, -2, "get")
        L.push( target_clear)
        lua_setfield(L, -2, "clear")
        L.push( target_getKeys)
        lua_setfield(L, -2, "getKeys")
        L.push( target_watchKey)
        lua_setfield(L, -2, "watchKey")
        L.push( output_watchers)
        lua_setfield(L, -2, "_watchers")

        // Module metatable for __gc
        lua_createtable(L, 0, 1)
        L.push( meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        watcherManager = HSUserDefaultKVOWatcher()

        /// hs.settings.dateFormat
        /// Constant
        /// A string representing the expected format of date and time when presenting the date and time as a string to `hs.setDate()`.  e.g. `os.date(hs.settings.dateFormat)`
        lua_pushstring(L, "!%Y-%m-%dT%H:%M:%SZ")
        lua_setfield(L, -2, "dateFormat")

        /// hs.settings.bundleID
        /// Constant
        /// A string representing the ID of the bundle Cosmic Hammer's settings are stored in . You can use this with the command line tool `defaults` or other tools which allow access to the `User Defaults` of applications, to access these outside of Cosmic Hammer
        lua_pushstring(L, Bundle.main.bundleIdentifier ?? "")
        lua_setfield(L, -2, "bundleID")
    }
}
