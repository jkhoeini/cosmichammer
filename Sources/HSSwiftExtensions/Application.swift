import Cocoa
import CLua
import Lua
import Carbon
import Carbon.HIToolbox
import HSDSTCore
import os.log

private let USERDATA_TAG = "hs.application"

private var backgroundCallbacks = [Int32: LuaValue]()
/// Monotonic key generator for backgroundCallbacks dictionary.
private var backgroundCallbackNextKey: Int32 = 0
private func nextBackgroundKey() -> Int32 {
    backgroundCallbackNextKey += 1
    return backgroundCallbackNextKey
}

// MARK: - Helper

private func getApp(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSapplicationProtocol? {
    return toHSapplicationFromLua(L, idx) as? HSapplicationProtocol
}

/// Extract the PID from an hs.application userdata.
/// Works with both legacy HSapplication objects and lightweight PID-only userdata.
private func getAppPID(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> Int32? {
    guard luaL_testudata(L, idx, USERDATA_TAG) != nil else { return nil }
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }

    // Check if this is an HSapplication (NSObject) or a lightweight PID box
    if let tag = lua_getAssociatedTag(L, idx), tag == APPLICATION_TAG_PID_ONLY {
        // Lightweight: raw pointer is actually an integer (PID)
        return Int32(Int(bitPattern: rawPtr))
    }

    // Legacy HSapplication
    let obj = Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
    if let app = obj as? HSapplicationProtocol {
        return app.pid
    }
    return nil
}

/// Tag value stored in Lua registry to distinguish lightweight PID-only userdata.
private let APPLICATION_TAG_PID_ONLY = "hs.application.pidonly"

/// Helper to check for a lightweight tag on userdata (stored in the user value slot).
private func lua_getAssociatedTag(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> String? {
    guard lua_getiuservalue(L, idx, 1) == LUA_TSTRING else {
        lua_pop(L, 1)
        return nil
    }
    let tag = String(cString: lua_tostring(L, -1))
    lua_pop(L, 1)
    return tag
}

/// Push an ApplicationInfo as an hs.application userdata.
/// In production (when HSapplication is available), creates a real HSapplication wrapper.
/// In test/simulator mode, creates a lightweight PID-only userdata.
func pushApplicationInfo(_ L: UnsafeMutablePointer<lua_State>!, _ info: ApplicationInfo) {
    if let app = HSapplication(pid: info.pid, withState: L) {
        pushHSapplication(L, app)
        return
    }
    pushLightweightAppUserdata(L, pid: info.pid)
}

/// Push multiple ApplicationInfo values as a Lua table.
private func pushApplicationInfos(_ L: UnsafeMutablePointer<lua_State>!, _ infos: [ApplicationInfo]) {
    lua_createtable(L, Int32(infos.count), 0)
    var index: lua_Integer = 1
    for info in infos {
        let top = lua_gettop(L)
        pushApplicationInfo(L, info)
        if lua_gettop(L) > top {
            lua_rawseti(L, -2, index)
            index += 1
        }
    }
}

/// Create a lightweight hs.application userdata that stores only a PID.
private func pushLightweightAppUserdata(_ L: UnsafeMutablePointer<lua_State>!, pid: Int32) {
    let valuePtr = lua_newuserdatauv(L, MemoryLayout<UnsafeMutableRawPointer>.size, 1)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = UnsafeMutableRawPointer(bitPattern: Int(pid))
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    // Tag this as PID-only so getAppPID can distinguish it
    L.push(APPLICATION_TAG_PID_ONLY)
    lua_setiuservalue(L, -2, 1)
}


private func appClassMethod(_ sel: String, with arg1: Any? = nil) -> Any? {
    guard let appClass = HSuicore.applicationClass else { return nil }
    return catchingObjCException {
        if let arg1 = arg1 {
            return (appClass as AnyObject).perform(Selector((sel)), with: arg1)?.takeUnretainedValue()
        } else {
            return (appClass as AnyObject).perform(Selector((sel)))?.takeUnretainedValue()
        }
    }
}

// MARK: - Module functions

private func application_gc(_ L: LuaState) throws -> CInt {
    backgroundCallbacks.removeAll()
    return 0
}

/// hs.application.frontmostApplication() -> hs.application object
/// Function
/// Returns the application object for the frontmost (active) application.  This is the application which currently receives input events.
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.application object
private func application_frontmostapplication(_ L: LuaState) throws -> CInt {
    let appProto = environmentGet(L).application
    guard let info = appProto.frontmostApplication() else { lua_pushnil(L); return 1 }
    pushApplicationInfo(L, info)
    return 1
}

/// hs.application.runningApplications() -> list of hs.application objects
/// Function
/// Returns all running apps.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing zero or more hs.application objects currently running on the system
private func application_runningapplications(_ L: LuaState) throws -> CInt {
    let appProto = environmentGet(L).application
    let infos = appProto.runningApplications()
    pushApplicationInfos(L, infos)
    return 1
}

/// hs.application.applicationForPID(pid) -> hs.application object or nil
/// Function
/// Returns the running app for the given pid, if it exists.
///
/// Parameters:
///  * pid - a UNIX process id (i.e. a number)
///
/// Returns:
///  * An hs.application object if one can be found, otherwise nil
private func application_applicationforpid(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TNUMBER)
    let pid = pid_t(lua_tointegerx(L, 1, nil))
    let appProto = environmentGet(L).application
    guard let info = appProto.applicationForPID(pid) else { lua_pushnil(L); return 1 }
    pushApplicationInfo(L, info)
    return 1
}

/// hs.application.applicationsForBundleID(bundleID) -> list of hs.application objects
/// Function
/// Returns any running apps that have the given bundleID.
///
/// Parameters:
///  * bundleID - An OSX application bundle identifier
///
/// Returns:
///  * A table of zero or more hs.application objects that match the given identifier
private func application_applicationsForBundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    let infos = appProto.applicationsForBundleID(bundleID)
    pushApplicationInfos(L, infos)
    return 1
}

/// hs.application.nameForBundleID(bundleID) -> string or nil
/// Function
/// Gets the name of an application from its bundle identifier
///
/// Parameters:
///  * bundleID - A string containing an application bundle identifier (e.g. "com.apple.Safari")
///
/// Returns:
///  * A string containing the application name, or nil if the bundle identifier could not be located
private func application_nameForBundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.nameForBundleID(bundleID) as NSString?)
    return 1
}

/// hs.application.pathForBundleID(bundleID) -> string or nil
/// Function
/// Gets the filesystem path of an application from its bundle identifier
///
/// Parameters:
///  * bundleID - A string containing an application bundle identifier (e.g. "com.apple.Safari")
///
/// Returns:
///  * A string containing the app bundle's filesystem path, or nil if the bundle identifier could not be located
private func application_pathForBundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.pathForBundleID(bundleID) as NSString?)
    return 1
}

/// hs.application.infoForBundleID(bundleID) -> table or nil
/// Function
/// Gets the metadata of an application from its bundle identifier
///
/// Parameters:
///  * bundleID - A string containing an application bundle identifier (e.g. "com.apple.Safari")
///
/// Returns:
///  * A table containing information about the application, or nil if the bundle identifier could not be located
private func application_infoForBundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.infoForBundleID(bundleID) as NSDictionary?)
    return 1
}

/// hs.application.preferredLocalizationsForBundleID(bundleID) -> table or nil
/// Function
/// Gets an ordered list of preferred localizations contained in a bundle
///
/// Parameters:
///  * bundleID - A string containing an application bundle identifier (e.g. "com.apple.Safari")
///
/// Returns:
///  * A table containing language IDs for localizations in the bundle. The strings are ordered according to the user's language preferences and available localizations.
private func application_preferredLocalizationsForBundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.preferredLocalizationsForBundleID(bundleID) as NSArray?)
    return 1
}

/// hs.application.preferredLocalizationsForBundlePath(bundlePath) -> table or nil
/// Function
/// Gets an ordered list of preferred localizations contained in a bundle
///
/// Parameters:
///  * bundlePath - A string containing the path to an application bundle (e.g. "/Applications/Safari.app")
///
/// Returns:
///  * A table containing language IDs for localizations in the bundle. The strings are ordered according to the user's language preferences and available localizations.
private func application_preferredLocalizationsForBundlePath(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundlePath = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.preferredLocalizationsForBundlePath(bundlePath) as NSArray?)
    return 1
}

/// hs.application.localizationsForBundleID(bundleID) -> table or nil
/// Function
/// Gets a list of all the localizations contained in the bundle.
///
/// Parameters:
///  * bundleID - A string containing an application bundle identifier (e.g. "com.apple.Safari")
///
/// Returns:
///  * A table containing language IDs for all the localizations contained in the bundle.
private func application_localizationsForBundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.localizationsForBundleID(bundleID) as NSArray?)
    return 1
}

/// hs.application.localizationsForBundlePath(bundlePath) -> table or nil
/// Function
/// Gets a list of all the localizations contained in the bundle.
///
/// Parameters:
///  * bundlePath - A string containing the path to an application bundle (e.g. "/Applications/Safari.app")
///
/// Returns:
///  * A table containing language IDs for all the localizations contained in the bundle.
private func application_localizationsForBundlePath(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundlePath = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.localizationsForBundlePath(bundlePath) as NSArray?)
    return 1
}

/// hs.application.infoForBundlePath(bundlePath) -> table or nil
/// Function
/// Gets the metadata of an application from its path on disk
///
/// Parameters:
///  * bundlePath - A string containing the path to an application bundle (e.g. "/Applications/Safari.app")
///
/// Returns:
///  * A table containing information about the application, or nil if the bundle could not be located
private func application_infoForBundlePath(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundlePath = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.infoForBundlePath(bundlePath) as NSDictionary?)
    return 1
}

/// hs.application.defaultAppForUTI(uti) -> string or nil
/// Function
/// Returns the bundle ID of the default application for a given UTI
///
/// Parameters:
///  * uti - A string containing a UTI
///
/// Returns:
///  * A string containing a bundle ID, or nil if none could be found
private func application_bundleForUTI(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let uti = lua_tovalue(L, at: 1) as! String
    let appProto = environmentGet(L).application
    if let handler = appProto.defaultAppForUTI(uti) {
        lua_pushany(L, handler as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Instance methods

/// hs.application:allWindows() -> list of hs.window objects
/// Method
/// Returns all open windows owned by the given app.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table of zero or more hs.window objects owned by the application
///
/// Notes:
///  * This function can only return windows in the current Mission Control Space; if you need to address windows across
///    different Spaces you can use the `hs.window.filter` module
///    - if `Displays have separate Spaces` is *on* (in System Preferences>Mission Control) the current Space is defined
///      as the union of all currently visible Spaces
///    - minimized windows and hidden windows (i.e. belonging to hidden apps, e.g. via cmd-h) are always considered
///      to be in the current Space
private func application_allWindows(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let winProto = environmentGet(L).window
    let elements = winProto.windowElements(forAppPID: pid)
    lua_createtable(L, Int32(elements.count), 0)
    for (i, handle) in elements.enumerated() {
        pushWindowElement(L, handle)
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    return 1
}

/// hs.application:mainWindow() -> hs.window object or nil
/// Method
/// Returns the main window of the given app, or nil.
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.window object representing the main window of the application, or nil if it has no windows
private func application_mainWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application
    if let win = appProto.mainWindow(pid: pid),
       let handle = environmentGet(L).window.windowElement(forID: win.id) {
        pushWindowElement(L, handle)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.application:focusedWindow() -> hs.window object or nil
/// Method
/// Returns the currently focused window of the application, or nil
///
/// Parameters:
///  * None
///
/// Returns:
///  * An hs.window object representing the window of the application that currently has focus, or nil if there are none
private func application_focusedWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application
    if let win = appProto.focusedWindow(pid: pid),
       let handle = environmentGet(L).window.windowElement(forID: win.id) {
        pushWindowElement(L, handle)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func application__activate(_ L: LuaState) throws -> CInt {
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    let appProto = environmentGet(L).application
    L.push(appProto.activate(pid: pid, allWindows: lua_toboolean(L, 2) != 0))
    return 1
}

private func application_isunresponsive(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    let appProto = environmentGet(L).application
    L.push(!appProto.isResponsive(pid: pid))
    return 1
}

private func application__bringtofront(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    let appProto = environmentGet(L).application
    L.push(appProto.setFrontmost(pid: pid, allWindows: lua_toboolean(L, 2) != 0))
    return 1
}

/// hs.application:title() -> string
/// Method
/// Returns the localized name of the app (in UTF8).
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the application
private func application_title(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.title(pid: pid) as NSString?)
    return 1
}

/// hs.application:bundleID() -> string
/// Method
/// Returns the bundle identifier of the app.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the bundle identifier of the application
private func application_bundleID(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.bundleID(pid: pid) as NSString?)
    return 1
}

/// hs.application:path() -> string
/// Method
/// Returns the filesystem path of the app.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the filesystem path of the application or nil if the path could not be determined (e.g. if the application has terminated).
private func application_path(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application
    lua_pushany(L, appProto.path(pid: pid) as NSString?)
    return 1
}

/// hs.application:isRunning() -> boolean
/// Method
/// Checks if the application is still running
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the application is running, false if not
///
/// Notes:
///  * If an application is terminated and re-launched, this method will still return false, as `hs.application` objects are tied to a specific instance of an application (i.e. its PID)
private func application_isRunning(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    let appProto = environmentGet(L).application
    L.push(appProto.isRunning(pid: pid))
    return 1
}

/// hs.application:unhide() -> boolean
/// Method
/// Unhides the app (and all its windows) if it's hidden.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean indicating whether the application was successfully unhidden
private func application_unhide(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    let appProto = environmentGet(L).application
    L.push(appProto.unhide(pid: pid))
    return 1
}

/// hs.application:hide() -> boolean
/// Method
/// Hides the app (and all its windows).
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean indicating whether the application was successfully hidden
private func application_hide(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    let appProto = environmentGet(L).application
    L.push(appProto.hide(pid: pid))
    return 1
}

/// hs.application:kill()
/// Method
/// Tries to terminate the app gracefully.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func application_kill(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { return 0 }
    environmentGet(L).application.kill(pid: pid)
    return 0
}

/// hs.application:kill9()
/// Method
/// Tries to terminate the app forcefully.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func application_kill9(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { return 0 }
    environmentGet(L).application.kill9(pid: pid)
    return 0
}

/// hs.application:isHidden() -> boolean
/// Method
/// Returns whether the app is currently hidden.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean indicating whether the application is hidden or not
private func application_ishidden(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    L.push(environmentGet(L).application.isHidden(pid: pid))
    return 1
}

/// hs.application:isFrontmost() -> boolean
/// Method
/// Returns whether the app is the frontmost (i.e. is the currently active application)
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the application is the frontmost application, otherwise false
private func application_isfrontmost(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }
    L.push(environmentGet(L).application.isFrontmost(pid: pid))
    return 1
}

/// hs.application:setFrontmost([allWindows]) -> boolean
/// Method
/// Sets the app to the frontmost (i.e. currently active) application
///
/// Parameters:
///  * allWindows - An optional boolean, true to bring all windows of the application to the front. Defaults to false
///
/// Returns:
///  * A boolean, true if the operation was successful, otherwise false
private func application_setfrontmost(_ L: LuaState) throws -> CInt {
    var allWindows = false
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(false); return 1 }

    if lua_type(L, 2) == LUA_TBOOLEAN {
        allWindows = lua_toboolean(L, 2) != 0
    }

    L.push(environmentGet(L).application.setFrontmost(pid: pid, allWindows: allWindows))
    return 1
}

/// hs.application:pid() -> number
/// Method
/// Returns the app's process identifier.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The UNIX process identifier of the application (i.e. a number)
private func application_pid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(0); return 1 }
    L.push(Int(pid))
    return 1
}

/// hs.application:kind() -> number
/// Method
/// Identify the application's GUI state
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number that is either 1 if the app is in the dock, 0 if it is not, or -1 if the application is prohibited from having GUI elements
private func application_kind(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let pid = getAppPID(L, at: 1) else { L.push(-1); return 1 }
    L.push(Int(environmentGet(L).application.kind(pid: pid)))
    return 1
}

// MARK: - Menu queries

/// hs.application:findMenuItem(menuItem[, isRegex]) -> table or nil
/// Method
/// Searches the application for a menu item
///
/// Parameters:
///  * menuItem - This can either be a string containing the text of a menu item (e.g. `"Messages"`) or a table representing the hierarchical path of a menu item (e.g. `{"File", "Share", "Messages"}`). In the string case, all of the application's menus will be searched until a match is found (with no specified behaviour if multiple menu items exist with the same name). In the table case, the whole menu structure will not be searched, because a precise path has been specified.
///  * isRegex - An optional boolean, defaulting to false, which is only used if `menuItem` is a string. If set to true, `menuItem` will be treated as a regular expression rather than a strict string to match against
///
/// Returns:
///  * Returns nil if the menu item cannot be found. If it does exist, returns a table with two keys:
///   * enabled - whether the menu item can be selected/ticked. This will always be false if the application is not currently focussed
///   * ticked - whether the menu item is ticked or not (obviously this value is meaningless for menu items that can't be ticked)
///
/// Notes:
///  * This can only search for menu items that don't have children - i.e. you can't search for the name of a submenu
private func application_findmenuitem(_ L: LuaState) throws -> CInt {
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application

    var result: (enabled: Bool, marked: Bool)?

    if lua_isstring(L, 2) {
        var nameIsRegex = false
        if lua_type(L, 3) == LUA_TBOOLEAN {
            nameIsRegex = lua_toboolean(L, 3) != 0
        }
        let name = String(cString: luaL_checklstring(L, 2, nil))
        result = appProto.findMenuItemByName(pid: pid, name: name, isRegex: nameIsRegex)
    } else if lua_istable(L, 2) {
        var pathArray: [String] = []
        lua_pushnil(L)
        while lua_next(L, 2) != 0 {
            let item = String(cString: luaL_checklstring(L, -1, nil))
            pathArray.append(item)
            lua_pop(L, 1)
        }
        result = appProto.findMenuItemByPath(pid: pid, path: pathArray)
    } else {
        os_log(.info, "%{public}s", "hs.application:findMenuItem() Unrecognised type for menuItem argument. Expecting string or table")
        lua_pushnil(L)
        return 1
    }

    guard let result = result else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    L.push("enabled")
    L.push(result.enabled)
    lua_settable(L, -3)
    L.push("ticked")
    L.push(result.marked)
    lua_settable(L, -3)

    return 1
}

/// hs.application:selectMenuItem(menuitem[, isRegex]) -> true or nil
/// Method
/// Selects a menu item (i.e. simulates clicking on the menu item)
///
/// Parameters:
///  * menuitem - The menu item to select, specified as either a string or a table. See the `menuitem` parameter of `hs.application:findMenuItem()` for more information.
///  * isRegex - An optional boolean, defaulting to false, which is only used if `menuItem` is a string. If set to true, `menuItem` will be treated as a regular expression rather than a strict string to match against
///
/// Returns:
///  * True if the menu item was found and selected, or nil if it wasn't (e.g. because the menu item couldn't be found)
///
/// Notes:
///  * Depending on the type of menu item involved, this will either activate or tick/untick the menu item
private func application_selectmenuitem(_ L: LuaState) throws -> CInt {
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application

    var success = false

    if lua_isstring(L, 2) {
        var nameIsRegex = false
        if lua_type(L, 3) == LUA_TBOOLEAN {
            nameIsRegex = lua_toboolean(L, 3) != 0
        }
        let name = String(cString: luaL_checklstring(L, 2, nil))
        success = appProto.selectMenuItemByName(pid: pid, name: name, isRegex: nameIsRegex)
    } else if lua_istable(L, 2) {
        var path: [String] = []
        lua_pushnil(L)
        while lua_next(L, 2) != 0 {
            let item = String(cString: luaL_checklstring(L, -1, nil))
            path.append(item)
            lua_pop(L, 1)
        }
        success = appProto.selectMenuItemByPath(pid: pid, path: path)
    } else {
        os_log(.info, "%{public}s", "hs.application:selectMenuItem(): Unrecognised type for menuItem argument, expecting string or table")
        lua_pushnil(L)
        return 1
    }

    if success {
        L.push(true)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.application:getMenuItems([fn]) -> table or nil | hs.application object
/// Method
/// Gets the menu structure of the application
///
/// Parameters:
///  * fn - an optional callback function.  If provided, the function will receive a single argument and return none.
///
/// Returns:
///  * If no argument is provided, returns a table containing the menu structure of the application, or nil if an error occurred. If a callback function is provided, the callback function will receive this table (or nil) and this method will return the application object this method was invoked on.
///
/// Notes:
///  * In some applications, this can take a little while to complete, because quite a large number of round trips are required to the source application, to get the information. When this method is invoked without a callback function, Cosmic Hammer will block while creating the menu structure table.  When invoked with a callback function, the menu structure is built in a background thread.
///
///  * The table is nested with the same structure as the menus of the application. Each item has several keys containing information about the menu item. Not all keys will appear for all items. The possible keys are:
///   * AXTitle - A string containing the text of the menu item (entries which have no title are menu separators)
///   * AXEnabled - A boolean, 1 if the menu item is clickable, 0 if not
///   * AXRole - A string containing the role of the menu item - this will be either AXMenuBarItem for a top level menu, or AXMenuItem for an item in a menu
///   * AXMenuItemMarkChar - A string containing the "mark" character for a menu item. This is for toggleable menu items and will usually be an empty string or a Unicode tick character (✓)
///   * AXMenuItemCmdModifiers - A table containing string representations of the keyboard modifiers for the menu item's keyboard shortcut, or nil if no modifiers are present
///   * AXMenuItemCmdChar - A string containing the key for the menu item's keyboard shortcut, or an empty string if no shortcut is present
///   * AXMenuItemCmdGlyph - An integer, corresponding to one of the defined glyphs in `hs.application.menuGlyphs` if the keyboard shortcut is a special character usually represented by a pictorial representation (think arrow keys, return, etc), or an empty string if no glyph is used in presenting the keyboard shortcut.
///  * Using `hs.inspect()` on these tables, while useful for exploration, can be extremely slow, taking several minutes to correctly render very complex menus
private func application_getMenus(_ L: LuaState) throws -> CInt {
    guard let pid = getAppPID(L, at: 1) else { lua_pushnil(L); return 1 }
    let appProto = environmentGet(L).application

    if lua_gettop(L) == 1 {
        let menus = appProto.getMenuItems(pid: pid)
        lua_pushany(L, menus as NSArray?)
        return 1
    }

    // Async path with callback
    let fnRef = L.ref(index: 2)
    let fnKey = nextBackgroundKey()
    backgroundCallbacks[fnKey] = fnRef
    let generation = lua_currentStateGeneration()

    // Use RunLoop.main.perform so the callback fires during RunLoop.main.run(until:)
    // in tests.  DispatchQueue.main.async blocks are not drained by RunLoop spinning.
    RunLoop.main.perform {
        guard lua_isStateGenerationValid(generation) else {
            backgroundCallbacks.removeValue(forKey: fnKey)
            return
        }
        if backgroundCallbacks[fnKey] != nil {
            let menus = appProto.getMenuItems(pid: pid)
            let L = lua_getCurrentState()!
            backgroundCallbacks[fnKey]!.push(onto: L)
            lua_pushany(L, menus as NSArray?)
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
            backgroundCallbacks.removeValue(forKey: fnKey)
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Launch functions

/// hs.application.launchOrFocus(name) -> boolean
/// Function
/// Launches the app with the given name, or activates it if it's already running
///
/// Parameters:
///  * name - A string containing the name of the application to either launch or focus. This can also be the full path to an application (including the `.app` suffix) if you need to uniquely distinguish between applications in different locations that share the same name
///
/// Returns:
///  * True if the application was either launched or focused, otherwise false (e.g. if the application doesn't exist)
///
/// Notes:
///  * The name parameter should match the name of the application on disk, e.g. "IntelliJ IDEA", rather than "IntelliJ"
private func application_launchorfocus(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let name = lua_tovalue(L, at: 1) as! String
    L.push(environmentGet(L).application.launchOrFocus(name))
    return 1
}

/// hs.application.launchOrFocusByBundleID(bundleID) -> boolean
/// Function
/// Launches the app with the given bundle ID, or activates it if it's already running
///
/// Parameters:
///  * bundleID - A string containing the bundle ID of the application to either launch or focus.
///
/// Returns:
///  * True if the application was either launched or focused, otherwise false (e.g. if the application doesn't exist)
///
/// Notes:
///  * Bundle identifiers typically take the form of `com.company.ApplicationName`
private func application_launchorfocusbybundleID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let bundleID = lua_tovalue(L, at: 1) as! String
    L.push(environmentGet(L).application.launchOrFocusByBundleID(bundleID))
    return 1
}

// MARK: - hs.uielement methods

private func application_uielement_isApplication(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    // uiElement methods require legacy HSapplication (not available in test mode)
    guard let app = getApp(L, at: 1),
          let uiElement = app.uiElement as? HSuielementProtocol else {
        // For lightweight/test userdata, applications are always "AXApplication"
        L.push(true)
        return 1
    }
    L.push(uiElement.role == "AXApplication")
    return 1
}

private func application_uielement_isWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1),
          let uiElement = app.uiElement as? HSuielementProtocol else {
        L.push(false)
        return 1
    }
    L.push(uiElement.isWindow)
    return 1
}

private func application_uielement_role(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1),
          let uiElement = app.uiElement as? HSuielementProtocol else {
        // For lightweight userdata, return "AXApplication"
        lua_pushany(L, "AXApplication" as NSString)
        return 1
    }
    lua_pushany(L, uiElement.role as NSString)
    return 1
}

private func application_uielement_selectedText(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1),
          let uiElement = app.uiElement as? HSuielementProtocol else {
        lua_pushnil(L)
        return 1
    }
    lua_pushany(L, uiElement.selectedText as NSString?)
    return 1
}

private func application_uielement_newWatcher(_ L: LuaState) throws -> CInt {
    guard let app = getApp(L, at: 1),
          let uiElement = app.uiElement as? HSuielementProtocol else {
        lua_pushnil(L)
        return 1
    }
    let watcher = uiElement.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)
    pushHSuielementWatcherOrNil(L, watcher)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

@discardableResult
func pushHSapplication(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    precondition(L != nil, "pushHSapplication: L must not be nil")
    guard let value = obj as? (NSObject & HSapplicationProtocol) else { return 0 }
    let previousTop = lua_gettop(L)
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value as NSObject).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    assert(lua_gettop(L) == previousTop + 1, "pushHSapplication: stack should grow by exactly 1")
    return 1
}

func pushHSapplicationOrNil(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) {
    if pushHSapplication(L, obj) == 0 {
        lua_pushnil(L)
    }
}

private func pushHSapplications(_ L: UnsafeMutablePointer<lua_State>!, _ apps: [HSapplication]?) {
    precondition(L != nil, "pushHSapplications: L must not be nil")
    guard let apps = apps else {
        lua_pushnil(L)
        return
    }

    let previousTop = lua_gettop(L)
    lua_createtable(L, Int32(apps.count), 0)
    var index: lua_Integer = 1
    for app in apps {
        if pushHSapplication(L, app) != 0 {
            lua_rawseti(L, -2, index)
            index += 1
        }
    }
    assert(lua_gettop(L) == previousTop + 1, "pushHSapplications: stack should grow by exactly 1 (table)")
}

private func toHSapplicationFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    precondition(L != nil, "toHSapplicationFromLua: L must not be nil")
    precondition(idx != 0, "toHSapplicationFromLua: idx must not be 0")
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        if let tag = lua_getAssociatedTag(L, idx), tag == APPLICATION_TAG_PID_ONLY {
            return nil
        }
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let rawPtr = ptr.pointee else { return nil }
        return Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue()
    } else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let pid = getAppPID(L, at: 1)
    let title = pid.flatMap { environmentGet(L).application.title(pid: $0) } ?? "?"
    L.push("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let pid1 = getAppPID(L, at: 1)
        let pid2 = getAppPID(L, at: 2)
        isEqual = (pid1 != nil && pid1 == pid2)
    }
    L.push(isEqual)
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    // Check if this is a lightweight PID-only userdata
    if let tag = lua_getAssociatedTag(L, 1), tag == APPLICATION_TAG_PID_ONLY {
        // No retained object to release -- just clear the pointer
        let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        ptr.pointee = nil
        lua_pushnil(L)
        lua_setmetatable(L, 1)
        return 0
    }

    // Legacy HSapplication path
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<NSObject>.fromOpaque(rawPtr).takeRetainedValue()
        if let app = obj as? HSapplicationProtocol {
            app.selfRefCount -= 1
        }
        ptr.pointee = nil
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}


// MARK: - Module entry point

@_cdecl("luaopen_hs_libapplication")
public func luaopen_hs_libapplication_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "luaopen_hs_libapplication: L must not be nil")
    return runEntryPoint(L) { L in
        backgroundCallbacks = [Int32: LuaValue]()
        backgroundCallbackNextKey = 0

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(application_allWindows); lua_setfield(L, -2, "allWindows")
        L.push(application_mainWindow); lua_setfield(L, -2, "mainWindow")
        L.push(application_focusedWindow); lua_setfield(L, -2, "focusedWindow")
        L.push(application__activate); lua_setfield(L, -2, "_activate")
        L.push(application__bringtofront); lua_setfield(L, -2, "_bringtofront")
        L.push(application_title); lua_setfield(L, -2, "title")
        L.push(application_title); lua_setfield(L, -2, "name")
        L.push(application_bundleID); lua_setfield(L, -2, "bundleID")
        L.push(application_path); lua_setfield(L, -2, "path")
        L.push(application_isRunning); lua_setfield(L, -2, "isRunning")
        L.push(application_unhide); lua_setfield(L, -2, "unhide")
        L.push(application_hide); lua_setfield(L, -2, "hide")
        L.push(application_kill); lua_setfield(L, -2, "kill")
        L.push(application_kill9); lua_setfield(L, -2, "kill9")
        L.push(application_ishidden); lua_setfield(L, -2, "isHidden")
        L.push(application_isfrontmost); lua_setfield(L, -2, "isFrontmost")
        L.push(application_setfrontmost); lua_setfield(L, -2, "setFrontmost")
        L.push(application_pid); lua_setfield(L, -2, "pid")
        L.push(application_isunresponsive); lua_setfield(L, -2, "isUnresponsive")
        L.push(application_kind); lua_setfield(L, -2, "kind")
        L.push(application_findmenuitem); lua_setfield(L, -2, "findMenuItem")
        L.push(application_selectmenuitem); lua_setfield(L, -2, "selectMenuItem")
        L.push(application_getMenus); lua_setfield(L, -2, "getMenuItems")
        L.push(application_uielement_isApplication); lua_setfield(L, -2, "isApplication")
        L.push(application_uielement_isWindow); lua_setfield(L, -2, "isWindow")
        L.push(application_uielement_role); lua_setfield(L, -2, "role")
        L.push(application_uielement_selectedText); lua_setfield(L, -2, "selectedText")
        L.push(application_uielement_newWatcher); lua_setfield(L, -2, "newWatcher")
        L.push(userdata_tostring); lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq); lua_setfield(L, -2, "__eq")
        L.push(userdata_gc); lua_setfield(L, -2, "__gc")

        // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 15)
        L.push(application_runningapplications); lua_setfield(L, -2, "runningApplications")
        L.push(application_frontmostapplication); lua_setfield(L, -2, "frontmostApplication")
        L.push(application_applicationforpid); lua_setfield(L, -2, "applicationForPID")
        L.push(application_applicationsForBundleID); lua_setfield(L, -2, "applicationsForBundleID")
        L.push(application_nameForBundleID); lua_setfield(L, -2, "nameForBundleID")
        L.push(application_pathForBundleID); lua_setfield(L, -2, "pathForBundleID")
        L.push(application_infoForBundleID); lua_setfield(L, -2, "infoForBundleID")
        L.push(application_infoForBundlePath); lua_setfield(L, -2, "infoForBundlePath")
        L.push(application_preferredLocalizationsForBundleID); lua_setfield(L, -2, "preferredLocalizationsForBundleID")
        L.push(application_preferredLocalizationsForBundlePath); lua_setfield(L, -2, "preferredLocalizationsForBundlePath")
        L.push(application_localizationsForBundleID); lua_setfield(L, -2, "localizationsForBundleID")
        L.push(application_localizationsForBundlePath); lua_setfield(L, -2, "localizationsForBundlePath")
        L.push(application_bundleForUTI); lua_setfield(L, -2, "defaultAppForUTI")
        L.push(application_launchorfocus); lua_setfield(L, -2, "launchOrFocus")
        L.push(application_launchorfocusbybundleID); lua_setfield(L, -2, "launchOrFocusByBundleID")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(application_gc); lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
