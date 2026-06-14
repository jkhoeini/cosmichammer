import Cocoa
import CLua
import Lua
import Carbon
import Carbon.HIToolbox
import os.log

private let USERDATA_TAG = "hs.application"

// Carbon enum constants not bridged to Swift
private let kAXMenuItemModifierNone: Int      = 0
private let kAXMenuItemModifierShift: Int     = 1 << 0
private let kAXMenuItemModifierOption: Int    = 1 << 1
private let kAXMenuItemModifierControl: Int   = 1 << 2
private let kAXMenuItemModifierNoCommand: Int = 1 << 3

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
    let result = HSapplication.frontmostApplication(withState: L)
    pushHSapplicationOrNil(L, result)
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
    let result = HSapplication.runningApplications(withState: L)
    pushHSapplications(L, result)
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
    let result = HSapplication.application(forPID: pid, withState: L)
    pushHSapplicationOrNil(L, result)
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
    let result = HSapplication.applications(forBundleID: bundleID, withState: L)
    pushHSapplications(L, result)
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
    let result = appClassMethod("nameForBundleID:", with: bundleID as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("pathForBundleID:", with: bundleID as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("infoForBundleID:", with: bundleID as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("preferredLocalizationsForBundleID:", with: bundleID as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("preferredLocalizationsForBundlePath:", with: bundlePath as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("localizationsForBundleID:", with: bundleID as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("localizationsForBundlePath:", with: bundlePath as NSString)
    lua_pushany(L, result)
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
    let result = appClassMethod("infoForBundlePath:", with: bundlePath as NSString)
    lua_pushany(L, result)
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

    let uti = lua_tovalue(L, at: 1) as! NSString

    var cfhandler: Unmanaged<CFString>? = LSCopyDefaultRoleHandlerForContentType(uti as CFString, LSRolesMask.all)
    if cfhandler == nil {
        cfhandler = LSCopyDefaultHandlerForURLScheme(uti as CFString)
        if cfhandler == nil {
            lua_pushnil(L)
            return 1
        }
    }

    let handler = cfhandler!.takeRetainedValue()
    lua_pushany(L, handler as NSString)
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    pushHSwindows(L, app.allWindows())
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    pushHSwindowOrNil(L, app.mainWindow())
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    pushHSwindowOrNil(L, app.focusedWindow())
    return 1
}

private func application__activate(_ L: LuaState) throws -> CInt {
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    L.push(app.activate(lua_toboolean(L, 2) != 0))
    return 1
}

private func application_isunresponsive(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    L.push(!app.isResponsive())
    return 1
}

private func application__bringtofront(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    L.push(app.setFrontmost(lua_toboolean(L, 2) != 0))
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, app.title())
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, app.bundleID())
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    lua_pushany(L, app.path())
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
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    L.push(app.isRunning(withState: L))
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
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    app.hidden = false
    L.push(!app.hidden)
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
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    app.hidden = true
    L.push(app.hidden)
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
    guard let app = getApp(L, at: 1) else { return 0 }
    app.kill()
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
    guard let app = getApp(L, at: 1) else { return 0 }
    app.kill9()
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
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    L.push(app.hidden)
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
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    L.push(app.isFrontmost())
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
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }

    if lua_type(L, 2) == LUA_TBOOLEAN {
        allWindows = lua_toboolean(L, 2) != 0
    }

    L.push(app.setFrontmost(allWindows))
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
    guard let app = getApp(L, at: 1) else { L.push(0); return 1 }
    L.push(Int(app.pid))
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
    guard let app = getApp(L, at: 1) else { L.push(-1); return 1 }
    L.push(Int(app.kind()))
    return 1
}

// MARK: - Menu helpers

private func _findmenuitembyname(_ L: UnsafeMutablePointer<lua_State>!, _ app: AXUIElement, _ name: String, _ nameIsRegex: Bool) -> AXUIElement? {
    precondition(L != nil, "_findmenuitembyname: L must not be nil")
    precondition(!name.isEmpty, "_findmenuitembyname: name must not be empty")

    var menuBarRef: CFTypeRef?
    var error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef)
    guard error == .success, let menuBar = menuBarRef else { return nil }

    var count: CFIndex = -1
    error = AXUIElementGetAttributeValueCount(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &count)
    guard error == .success else { return nil }

    var cfChildren: CFArray?
    error = AXUIElementCopyAttributeValues(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, 0, count, &cfChildren)
    guard error == .success, let children = cfChildren else { return nil }

    let toCheck = NSMutableArray()
    toCheck.addObjects(from: (children as? [Any]) ?? [])

    var i = 5000
    while i > 0 {
        i -= 1
        if toCheck.count == 0 { break }

        let firstObject = toCheck[0]
        let element = firstObject as! AXUIElement
        toCheck.remove(firstObject)

        var cfTitle: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &cfTitle)
        let title = cfTitle as? String

        var childcount: CFIndex = -1
        let childError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childcount)
        if childError != .success {
            os_log(.debug, "%{public}s", "Got an error (\(childError.rawValue)) checking child count, skipping")
            continue
        }
        if childcount > 0 {
            var cfMenuchildren: CFArray?
            let menuChildError = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, childcount, &cfMenuchildren)
            if menuChildError != .success {
                os_log(.debug, "%{public}s", "Got an error (\(menuChildError.rawValue)) fetching menu children, skipping")
                continue
            }
            if let menuchildren = cfMenuchildren {
                toCheck.addObjects(from: (menuchildren as? [Any]) ?? [])
            }
        } else if childcount == 0 {
            if !nameIsRegex && name == title {
                return element
            } else {
                let matchTest = NSPredicate(format: "SELF MATCHES %@", name)
                if matchTest.evaluate(with: title) {
                    return element
                }
            }
        }
    }

    if i == 0 {
        os_log(.info, "%{public}s", "_findmenuitembyname() overflowed 5000 iteration guard. This is either a Cosmic Hammer bug, or your menus are too deep")
    }
    return nil
}

private func _findmenuitembypath(_ L: UnsafeMutablePointer<lua_State>!, _ app: AXUIElement, _ _path: [String]) -> AXUIElement? {
    precondition(L != nil, "_findmenuitembypath: L must not be nil")
    precondition(!_path.isEmpty, "_findmenuitembypath: path must not be empty")

    let path = NSMutableArray(array: _path)

    var menuBarRef: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef)
    guard error == .success, let menuBar = menuBarRef else { return nil }

    var searchItem: AXUIElement = menuBar as! AXUIElement

    var i = 5000
    while i > 0 {
        i -= 1

        guard let children = fetchChildrenUnwrappingMenu(searchItem) else { break }

        let nextMenuItem = path[0] as! String
        path.removeObject(at: 0)

        guard let matched = findChildByTitle(children, nextMenuItem) else {
            os_log(.debug, "%{public}s", "Unable to resolve complete search path")
            break
        }
        searchItem = matched

        if path.count == 0 { return searchItem }
    }

    return nil
}

/// Fetches the children of `element`. If the first child has AXMenu role,
/// unwraps one level to return the menu's children instead.
private func fetchChildrenUnwrappingMenu(_ element: AXUIElement) -> CFArray? {
    var count: CFIndex = -1
    var axError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
    guard axError == .success else {
        os_log(.debug, "%{public}s", "Failed to get child count")
        return nil
    }

    var cfChildren: CFArray?
    axError = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &cfChildren)
    guard axError == .success, var children = cfChildren else {
        os_log(.debug, "%{public}s", "Failed to get children")
        return nil
    }

    if count > 0, let unwrapped = unwrapAXMenuChildren(children) {
        children = unwrapped
    }
    return children
}

/// If the first element in `children` has the AXMenu role, returns that menu's
/// children (one level deeper). Otherwise returns nil.
private func unwrapAXMenuChildren(_ children: CFArray) -> CFArray? {
    guard let firstPtr = CFArrayGetValueAtIndex(children, 0) else { return nil }
    let firstElement = Unmanaged<AXUIElement>.fromOpaque(firstPtr).takeUnretainedValue()

    var cfRole: CFTypeRef?
    guard AXUIElementCopyAttributeValue(firstElement, kAXRoleAttribute as CFString, &cfRole) == .success else {
        os_log(.debug, "%{public}s", "Failed to get role")
        return nil
    }
    guard CFStringCompare(cfRole as! CFString, kAXMenuRole as CFString, []) == .compareEqualTo else {
        return nil
    }

    var axMenuCount: CFIndex = -1
    guard AXUIElementGetAttributeValueCount(firstElement, kAXChildrenAttribute as CFString, &axMenuCount) == .success else {
        os_log(.debug, "%{public}s", "Failed to get AXMenu child count")
        return nil
    }
    var axMenuChildren: CFArray?
    guard AXUIElementCopyAttributeValues(firstElement, kAXChildrenAttribute as CFString, 0, axMenuCount, &axMenuChildren) == .success,
          let result = axMenuChildren else {
        os_log(.debug, "%{public}s", "Failed to get AXMenu children")
        return nil
    }
    return result
}

/// Searches `children` for the first element whose AXTitle matches `title`.
private func findChildByTitle(_ children: CFArray, _ title: String) -> AXUIElement? {
    let childCount = CFArrayGetCount(children)
    for j in 0..<childCount {
        let ptr = CFArrayGetValueAtIndex(children, j)!
        let element = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
        var cfTitle: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &cfTitle)
        if err != .success {
            os_log(.debug, "%{public}s", "Unable to get menu item title")
            continue
        }
        if title == (cfTitle as? String ?? "") { return element }
    }
    return nil
}

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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }

    var foundItem: AXUIElement?
    var name: String?
    var path: [String]?

    if lua_isstring(L, 2) {
        var nameIsRegex = false
        if lua_type(L, 3) == LUA_TBOOLEAN {
            nameIsRegex = lua_toboolean(L, 3) != 0
        }
        name = String(cString: luaL_checklstring(L, 2, nil))
        foundItem = _findmenuitembyname(L, app.elementRef, name!, nameIsRegex)
    } else if lua_istable(L, 2) {
        var pathArray: [String] = []
        lua_pushnil(L)
        while lua_next(L, 2) != 0 {
            let item = String(cString: luaL_checklstring(L, -1, nil))
            pathArray.append(item)
            lua_pop(L, 1)
        }
        path = pathArray
        foundItem = _findmenuitembypath(L, app.elementRef, pathArray)
    } else {
        os_log(.info, "%{public}s", "hs.application:findMenuItem() Unrecognised type for menuItem argument. Expecting string or table")
        lua_pushnil(L)
        return 1
    }

    guard let foundItem = foundItem else {
        if let name = name {
            os_log(.debug, "%{public}s", "Couldn't find menu item \(name)")
        } else if path != nil {
            os_log(.debug, "%{public}s", "Couldn't find menu item")
        }
        lua_pushnil(L)
        return 1
    }

    var enabled: CFTypeRef?
    var error = AXUIElementCopyAttributeValue(foundItem, kAXEnabledAttribute as CFString, &enabled)
    if error != .success {
        os_log(.debug, "%{public}s", "hs.application:findMenuItem: AXEnabled Error: \(error.rawValue)")
        lua_pushnil(L)
        return 1
    }

    var markchar: CFTypeRef?
    error = AXUIElementCopyAttributeValue(foundItem, kAXMenuItemMarkCharAttribute as CFString, &markchar)
    if error != .success && error != .noValue {
        os_log(.debug, "%{public}s", "hs.application:findMenuItem: AXMenuItemMarkChar: \(error.rawValue)")
        lua_pushnil(L)
        return 1
    }

    let marked = (error != .noValue)

    lua_newtable(L)
    L.push("enabled")
    L.push((enabled as? NSNumber)?.boolValue == true)
    lua_settable(L, -3)
    L.push("ticked")
    L.push(marked)
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }

    var foundItem: AXUIElement?
    var name: String?

    if lua_isstring(L, 2) {
        var nameIsRegex = false
        if lua_type(L, 3) == LUA_TBOOLEAN {
            nameIsRegex = lua_toboolean(L, 3) != 0
        }
        name = String(cString: luaL_checklstring(L, 2, nil))
        foundItem = _findmenuitembyname(L, app.elementRef, name!, nameIsRegex)
    } else if lua_istable(L, 2) {
        var path: [String] = []
        lua_pushnil(L)
        while lua_next(L, 2) != 0 {
            let item = String(cString: luaL_checklstring(L, -1, nil))
            path.append(item)
            lua_pop(L, 1)
        }
        foundItem = _findmenuitembypath(L, app.elementRef, path)
    } else {
        os_log(.info, "%{public}s", "hs.application:selectMenuItem(): Unrecognised type for menuItem argument, expecting string or table")
        lua_pushnil(L)
        return 1
    }

    guard let foundItem = foundItem else {
        os_log(.debug, "%{public}s", "Couldn't find \(name ?? "")")
        lua_pushnil(L)
        return 1
    }

    var axError: AXError = .success
    if let exMsg = catchingObjCException({
        axError = AXUIElementPerformAction(foundItem, kAXPressAction as CFString)
    }) {
        os_log(.error, "caught ObjC exception in AXUIElementPerformAction: %{public}s", exMsg)
        lua_pushnil(L)
        return 1
    }
    if axError != .success {
        os_log(.debug, "%{public}s", "hs.application:selectMenuItem(): AXPress error: \(axError.rawValue)")
        lua_pushnil(L)
        return 1
    }

    L.push(true)
    return 1
}

// MARK: - Menu structure

private func _getMenuStructure(_ menuItem: AXUIElement) -> Any {
    let initialAttributeCount = 7
    let attributeNames = NSMutableArray(array: [
        kAXTitleAttribute as String,
        kAXRoleAttribute as String,
        kAXMenuItemMarkCharAttribute as String,
        kAXMenuItemCmdCharAttribute as String,
        kAXMenuItemCmdModifiersAttribute as String,
        kAXEnabledAttribute as String,
        kAXMenuItemCmdGlyphAttribute as String,
    ])
    assert(attributeNames.count == initialAttributeCount, "_getMenuStructure: expected \(initialAttributeCount) attribute names, got \(attributeNames.count)")

    var cfAttributeValues: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(menuItem, attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &cfAttributeValues)

    if result != AXError.success {
        os_log(.default, "%{public}s","Unable to fetch menu structure")
    } else if isAppleMenuItem(cfAttributeValues) {
        return NSNull()
    }

    guard let cfValues = cfAttributeValues else { return NSNull() }

    let attributeValues = NSMutableArray(array: (cfValues as? [Any]) ?? [])
    replaceAXErrorValues(attributeValues)
    replaceModifiersWithArray(attributeValues, attributeNames)

    let children = collectMenuChildren(menuItem)
    if let children = children, children.count > 0 {
        attributeNames.add(kAXChildrenAttribute as String)
        attributeValues.add(children)
    }

    return buildMenuResult(attributeValues, attributeNames, children)
}

/// Returns true if the first attribute value is the string "Apple" (the Apple menu).
private func isAppleMenuItem(_ cfValues: CFArray?) -> Bool {
    guard let cfValues = cfValues,
          let firstElement = CFArrayGetValueAtIndex(cfValues, 0) else { return false }
    let typeID = CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(firstElement).takeUnretainedValue())
    guard typeID == CFStringGetTypeID() else { return false }
    let firstStr = Unmanaged<CFString>.fromOpaque(firstElement).takeUnretainedValue()
    return CFStringCompare(firstStr, "Apple" as CFString, []) == .compareEqualTo
}

/// Replaces any AXValue entries of type .axError with empty strings.
private func replaceAXErrorValues(_ attributeValues: NSMutableArray) {
    for j in 0..<attributeValues.count {
        let val = attributeValues[j]
        if CFGetTypeID(val as CFTypeRef) == AXValueGetTypeID() {
            if AXValueGetType(val as! AXValue) == .axError {
                attributeValues[j] = ""
            }
        }
    }
}

/// Converts the raw modifier integer into an array of modifier name strings.
private func replaceModifiersWithArray(_ attributeValues: NSMutableArray, _ attributeNames: NSMutableArray) {
    let modifiersIndex = attributeNames.index(of: kAXMenuItemCmdModifiersAttribute as String)
    guard let modsNum = attributeValues[modifiersIndex] as? NSNumber else {
        attributeValues[modifiersIndex] = NSNull()
        return
    }
    let modsInt = modsNum.intValue
    let modsArr = NSMutableArray()
    if (modsInt & kAXMenuItemModifierNoCommand) == 0 { modsArr.add("cmd") }
    if (modsInt & kAXMenuItemModifierShift) != 0     { modsArr.add("shift") }
    if (modsInt & kAXMenuItemModifierOption) != 0    { modsArr.add("alt") }
    if (modsInt & kAXMenuItemModifierControl) != 0   { modsArr.add("ctrl") }
    attributeValues[modifiersIndex] = modsArr
}

/// Recursively collects non-null child menu structures.
private func collectMenuChildren(_ menuItem: AXUIElement) -> NSMutableArray? {
    var cfChildren: CFArray?
    guard AXUIElementCopyAttributeValues(menuItem, kAXChildrenAttribute as CFString, 0, CFIndex(INT32_MAX), &cfChildren) == .success else {
        return nil
    }
    let result = NSMutableArray()
    if let cfChildren = cfChildren {
        let numChildren = CFArrayGetCount(cfChildren)
        for i in 0..<numChildren {
            let childPtr = CFArrayGetValueAtIndex(cfChildren, i)!
            let child = Unmanaged<AXUIElement>.fromOpaque(childPtr).takeUnretainedValue()
            let childValues = _getMenuStructure(child)
            if !(childValues is NSNull) { result.add(childValues) }
        }
    }
    return result
}

/// Builds the final menu item dictionary or returns the children array.
private func buildMenuResult(_ attributeValues: NSMutableArray, _ attributeNames: NSMutableArray,
                             _ children: NSMutableArray?) -> Any {
    let roleValue = attributeValues[1] as? String ?? ""
    if roleValue == "AXMenuItem" || roleValue == "AXMenuBarItem" {
        let thisMenuItem = NSMutableDictionary(objects: attributeValues as! [Any], forKeys: attributeNames as! [NSCopying])
        if thisMenuItem.count > 0 { return thisMenuItem }
    } else {
        if let children = children, children.count > 0 { return children }
    }
    return NSNull()
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
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }

    if lua_gettop(L) == 1 {
        var menus: NSMutableDictionary? = nil
        var menuBarRef: CFTypeRef?

        if AXUIElementCopyAttributeValue(app.elementRef, kAXMenuBarAttribute as CFString, &menuBarRef) == .success {
            let menuBar = menuBarRef as! AXUIElement
            menus = _getMenuStructure(menuBar) as? NSMutableDictionary
        }

        lua_pushany(L, menus)
    } else {
        let fnRef = L.ref(index: 2)
        let fnKey = nextBackgroundKey()
        backgroundCallbacks[fnKey] = fnRef

        let elementRef = app.elementRef
        let generation = lua_currentStateGeneration()

        DispatchQueue.main.async {
            guard lua_isStateGenerationValid(generation) else {
                backgroundCallbacks.removeValue(forKey: fnKey)
                return
            }
            if backgroundCallbacks[fnKey] != nil {
                var menus: NSMutableDictionary? = nil
                var menuBarRef: CFTypeRef?

                if AXUIElementCopyAttributeValue(elementRef, kAXMenuBarAttribute as CFString, &menuBarRef) == .success {
                    let menuBar = menuBarRef as! AXUIElement
                    menus = _getMenuStructure(menuBar) as? NSMutableDictionary
                }

                let L = lua_getCurrentState()!
                backgroundCallbacks[fnKey]!.push(onto: L)
                lua_pushany(L, menus)
                if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
                backgroundCallbacks.removeValue(forKey: fnKey)
            }
        }
        lua_pushvalue(L, 1)
    }

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
    guard let appClass = HSuicore.applicationClass else { L.push(false); return 1 }
    let name = lua_tovalue(L, at: 1) as! NSString
    let result = catchingObjCException {
        (appClass as AnyObject).perform(Selector(("launchByName:")), with: name)
    }
    L.push(result != nil)
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
    guard let appClass = HSuicore.applicationClass else { L.push(false); return 1 }
    let bundleID = lua_tovalue(L, at: 1) as! NSString
    let result = catchingObjCException {
        (appClass as AnyObject).perform(Selector(("launchByBundleID:")), with: bundleID)
    }
    L.push(result != nil)
    return 1
}

// MARK: - hs.uielement methods

private func application_uielement_isApplication(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    if let uiElement = app.uiElement as? HSuielementProtocol {
        L.push(uiElement.role == "AXApplication")
    } else {
        L.push(false)
    }
    return 1
}

private func application_uielement_isWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1) else { L.push(false); return 1 }
    if let uiElement = app.uiElement as? HSuielementProtocol {
        L.push(uiElement.isWindow)
    } else {
        L.push(false)
    }
    return 1
}

private func application_uielement_role(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    if let uiElement = app.uiElement as? HSuielementProtocol {
        lua_pushany(L, uiElement.role as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func application_uielement_selectedText(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    if let uiElement = app.uiElement as? HSuielementProtocol {
        lua_pushany(L, uiElement.selectedText as NSString?)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func application_uielement_newWatcher(_ L: LuaState) throws -> CInt {
    guard let app = getApp(L, at: 1) else { lua_pushnil(L); return 1 }
    if let uiElement = app.uiElement as? HSuielementProtocol {
        let watcher = uiElement.newWatcher(atIndex: 2, withUserdataAtIndex: 3, withLuaState: L)
        pushHSuielementWatcherOrNil(L, watcher)
    } else {
        lua_pushnil(L)
    }
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
    let app = getApp(L, at: 1)
    let title = app?.title() ?? "?"
    L.push("\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        if let app1 = toHSapplicationFromLua(L, 1) as? HSapplicationProtocol,
           let app2 = toHSapplicationFromLua(L, 2) as? HSapplicationProtocol {
            isEqual = app1.runningApp.isEqual(app2.runningApp)
        }
    }
    L.push(isEqual)
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
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
