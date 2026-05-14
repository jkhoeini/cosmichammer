import Cocoa
import LuaSkin

// Establish a unique context for identifying our observers
private var myKVOContext: Int = 0 // See http://nshipster.com/key-value-observing/
private var refTable: LSRefTable = LUA_NOREF

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
            let skin = LuaSkin.shared(withState: nil)
            _lua_stackguard_entry(skin.l)
            fnCallbacks.enumerateKeysAndObjects { watcherID, refN, _ in
                let ref = (refN as! NSNumber).intValue
                skin.pushLuaRef(refTable, ref: ref)
                skin.pushNSObject(keyPath as NSString)
                skin.protectedCallAndError("hs.settings:watcher \(watcherID) callback", nargs: 1, nresults: 0)
            }
            _lua_stackguard_exit(skin.l)
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
private func target_set(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TANY | LS_TOPTIONAL, LS_TBREAK)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        return luaL_error(L, "key must be a valid UTF8 string")
    }

    // Allow for missing second argument for backwards compatibility
    var val: Any? = nil
    if lua_gettop(L) == 2 {
        val = skin.toNSObject(atIndex: 2, withOptions: LS_NSPreserveLuaStringExactly | LS_NSRawTables)
    }

    do {
        UserDefaults.standard.set(val, forKey: key)
    }
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
private func target_setData(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L).checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        return luaL_error(L, "key must be a valid UTF8 string")
    }

    if lua_type(L, 2) == LUA_TSTRING {
        let dataPtr = lua_tostring(L, 2)!
        let sz = lua_rawlen(L, 2)
        let data = Data(bytes: dataPtr, count: sz)
        UserDefaults.standard.set(data, forKey: key)
    } else {
        luaL_error(L, "second argument not (binary data encapsulated as) a string")
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
private func target_setDate(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L).checkArgs(LS_TSTRING, LS_TSTRING | LS_TNUMBER, LS_TBREAK)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        return luaL_error(L, "key must be a valid UTF8 string")
    }

    let myDate: Date?
    if lua_isnumber(L, 2) != 0 {
        myDate = Date(timeIntervalSince1970: TimeInterval(lua_tonumber(L, 2)))
    } else if lua_isstring(L, 2) != 0 {
        myDate = date_from_string(String(cString: lua_tostring(L, 2)))
    } else {
        myDate = nil
    }

    if let date = myDate {
        UserDefaults.standard.set(date, forKey: key)
    } else {
        luaL_error(L, "Not a date type -- Number: # of seconds since 1970-01-01 00:00:00Z or String: in the format of 'YYYY-MM-DD[T]HH:MM:SS[Z]' (rfc3339)")
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
private func target_get(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        return luaL_error(L, "key must be a valid UTF8 string")
    }

    let val = UserDefaults.standard.object(forKey: key)
    skin.pushNSObject(val as NSObject?)
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
private func target_clear(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L).checkArgs(LS_TSTRING, LS_TBREAK)

    guard let key = String(validatingUTF8: luaL_checkstring(L, 1)) else {
        return luaL_error(L, "key must be a valid UTF8 string")
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
///  * A table containing all of the settings keys in Hammerspoon's settings
///
/// Notes:
///  * Use `ipairs(hs.settings.getKeys())` to iterate over all available settings
///  * Use `hs.settings.getKeys()["someKey"]` to test for the existence of a particular key
private func target_getKeys(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)

    let mainID = Bundle.main.bundleIdentifier ?? ""
    let keys = UserDefaults.standard.persistentDomain(forName: mainID)?.keys.sorted() ?? []

    lua_newtable(L)
    for (i, key) in keys.enumerated() {
        lua_pushinteger(L, lua_Integer(i + 1))
        skin.pushNSObject(key as NSString)
        lua_settable(L, -3)

        skin.pushNSObject(key as NSString)
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
private func target_watchKey(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)

    let watcherID = skin.toNSObject(atIndex: 1) as! NSString
    let keyPath = skin.toNSObject(atIndex: 2) as! NSString

    if watcherManager.watchedKeys[keyPath] == nil {
        watcherManager.watchedKeys[keyPath] = NSMutableDictionary()
        UserDefaults.standard.addObserver(watcherManager, forKeyPath: keyPath as String,
                                          options: .new, context: &myKVOContext)
    }

    let keyWatchers = watcherManager.watchedKeys[keyPath] as! NSMutableDictionary
    let refN = keyWatchers[watcherID] as? NSNumber

    if lua_gettop(L) == 2 {
        if let ref = refN {
            skin.pushLuaRef(refTable, ref: ref.intValue)
        } else {
            lua_pushnil(L)
        }
    } else {
        if let ref = refN {
            skin.luaUnref(refTable, ref: ref.intValue)
        }
        keyWatchers[watcherID] = nil
        if lua_type(L, 3) != LUA_TNIL {
            lua_pushvalue(L, 3)
            keyWatchers[watcherID] = NSNumber(value: skin.luaRef(refTable))
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

// For debugging
private func output_watchers(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L).pushNSObject(watcherManager.watchedKeys)
    return 1
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    watcherManager.watchedKeys.enumerateKeysAndObjects { keyPath, watchers, _ in
        UserDefaults.standard.removeObserver(watcherManager!, forKeyPath: keyPath as! String, context: &myKVOContext)
        (watchers as! NSMutableDictionary).enumerateKeysAndObjects { _, refN, _ in
            skin.luaUnref(refTable, ref: (refN as! NSNumber).intValue)
        }
    }
    watcherManager.watchedKeys = nil
    watcherManager = nil
    return 0
}

// MARK: - luaL_Reg tables

private var settingslib: [luaL_Reg] = [
    luaL_Reg(name: strdup("set"), func: target_set),
    luaL_Reg(name: strdup("setData"), func: target_setData),
    luaL_Reg(name: strdup("setDate"), func: target_setDate),
    luaL_Reg(name: strdup("get"), func: target_get),
    luaL_Reg(name: strdup("clear"), func: target_clear),
    luaL_Reg(name: strdup("getKeys"), func: target_getKeys),
    luaL_Reg(name: strdup("watchKey"), func: target_watchKey),
    luaL_Reg(name: strdup("_watchers"), func: output_watchers),
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libsettings")
public func luaopen_hs_libsettings(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary("hs.settings", functions: &settingslib, metaFunctions: &module_metaLib)

    watcherManager = HSUserDefaultKVOWatcher()

    /// hs.settings.dateFormat
    /// Constant
    /// A string representing the expected format of date and time when presenting the date and time as a string to `hs.setDate()`.  e.g. `os.date(hs.settings.dateFormat)`
    lua_pushstring(L, "!%Y-%m-%dT%H:%M:%SZ")
    lua_setfield(L, -2, "dateFormat")

    /// hs.settings.bundleID
    /// Constant
    /// A string representing the ID of the bundle Hammerspoon's settings are stored in . You can use this with the command line tool `defaults` or other tools which allow access to the `User Defaults` of applications, to access these outside of Hammerspoon
    lua_pushstring(L, Bundle.main.bundleIdentifier ?? "")
    lua_setfield(L, -2, "bundleID")

    return 1
}
