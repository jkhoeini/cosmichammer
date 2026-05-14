import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.application"
private var refTable: LSRefTable = LUA_NOREF

private func get_objectFromUserdata<T: AnyObject>(_ type: T.Type, _ L: OpaquePointer, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return Unmanaged<T>.fromOpaque(ptr.load(as: UnsafeMutableRawPointer.self)).takeUnretainedValue()
}

private var backgroundCallbacks = NSMutableSet()

// MARK: - Module functions

private func application_gc(_ L: OpaquePointer!) -> Int32 {
    backgroundCallbacks.enumerateObjects { obj, _ in
        if let ref = obj as? NSNumber {
            luaL_unref(L, LUA_REGISTRYINDEX, ref.int32Value)
        }
    }
    backgroundCallbacks.removeAllObjects()
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
private func application_frontmostapplication(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(HSapplication.frontmostApplication(withState: L))
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
private func application_runningapplications(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)
    let apps = HSapplication.runningApplications(withState: L)
    skin.pushNSObject(apps)
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
private func application_applicationforpid(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TNUMBER, LS_TBREAK)
    let pid = pid_t(lua_tointegerx(L, 1, nil))
    skin.pushNSObject(HSapplication.application(forPID: pid, withState: L))
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
private func application_applicationsForBundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.applications(forBundleID: skin.toNSObject(atIndex: 1) as! String, withState: L))
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
private func application_nameForBundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.name(forBundleID: skin.toNSObject(atIndex: 1) as! String))
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
private func application_pathForBundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.path(forBundleID: skin.toNSObject(atIndex: 1) as! String))
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
private func application_infoForBundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.info(forBundleID: skin.toNSObject(atIndex: 1) as! String))
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
private func application_preferredLocalizationsForBundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.preferredLocalizations(forBundleID: skin.toNSObject(atIndex: 1) as! String))
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
private func application_preferredLocalizationsForBundlePath(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.preferredLocalizations(forBundlePath: skin.toNSObject(atIndex: 1) as! String))
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
private func application_localizationsForBundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.localizations(forBundleID: skin.toNSObject(atIndex: 1) as! String))
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
private func application_localizationsForBundlePath(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.localizations(forBundlePath: skin.toNSObject(atIndex: 1) as! String))
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
private func application_infoForBundlePath(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    skin.pushNSObject(HSapplication.info(forBundlePath: skin.toNSObject(atIndex: 1) as! String))
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
private func application_bundleForUTI(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let uti = skin.toNSObject(atIndex: 1) as! NSString

    var cfhandler: CFString? = LSCopyDefaultRoleHandlerForContentType(uti as CFString, LSRolesMask.all)
    if cfhandler == nil {
        cfhandler = LSCopyDefaultHandlerForURLScheme(uti as CFString)
        if cfhandler == nil {
            lua_pushnil(L)
            return 1
        }
    }

    skin.pushNSObject(cfhandler! as NSString)
    return 1
}

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
private func application_allWindows(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    skin.pushNSObject(app.allWindows())
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
private func application_mainWindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    skin.pushNSObject(app.mainWindow())
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
private func application_focusedWindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    skin.pushNSObject(app.focusedWindow())
    return 1
}

private func application__activate(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushboolean(L, app.activate(lua_toboolean(L, 2) != 0) ? 1 : 0)
    return 1
}

private func application_isunresponsive(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushboolean(L, app.isResponsive ? 0 : 1)
    return 1
}

private func application__bringtofront(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushboolean(L, app.setFrontmost(lua_toboolean(L, 2) != 0) ? 1 : 0)
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
private func application_title(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    skin.pushNSObject(app.title())
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
private func application_bundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    skin.pushNSObject(app.bundleID())
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
private func application_path(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    skin.pushNSObject(app.path())
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
private func application_isRunning(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushboolean(L, app.isRunning(withState: L) ? 1 : 0)
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
private func application_unhide(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    app.isHidden = false
    lua_pushboolean(L, app.isHidden ? 0 : 1)
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
private func application_hide(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    app.isHidden = true
    lua_pushboolean(L, app.isHidden ? 1 : 0)
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
private func application_kill(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
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
private func application_kill9(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
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
private func application_ishidden(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushboolean(L, app.isHidden ? 1 : 0)
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
private func application_isfrontmost(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushboolean(L, app.isFrontmost() ? 1 : 0)
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
private func application_setfrontmost(_ L: OpaquePointer!) -> Int32 {
    var allWindows = false
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication

    if lua_type(L, 2) == LUA_TBOOLEAN {
        allWindows = lua_toboolean(L, 2) != 0
    }

    lua_pushboolean(L, app.setFrontmost(allWindows) ? 1 : 0)
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
private func application_pid(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushinteger(L, lua_Integer(app.pid))
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
private func application_kind(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    lua_pushinteger(L, lua_Integer(app.kind()))
    return 1
}

private func _findmenuitembyname(_ L: OpaquePointer!, _ app: AXUIElement, _ name: String, _ nameIsRegex: Bool) -> AXUIElement? {
    let skin = LuaSkin.shared(withState: L)
    var foundItem: AXUIElement?

    var menuBarRef: CFTypeRef?
    var error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef)
    guard error == .success, let menuBar = menuBarRef else {
        return nil
    }

    var count: CFIndex = -1
    error = AXUIElementGetAttributeValueCount(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &count)
    guard error == .success else {
        return nil
    }

    var cfChildren: CFArray?
    error = AXUIElementCopyAttributeValues(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, 0, count, &cfChildren)
    guard error == .success, let children = cfChildren else {
        return nil
    }

    let toCheck = NSMutableArray()
    toCheck.addObjects(from: children as! [Any])

    var i = 5000
    while i > 0 {
        i -= 1
        if toCheck.count == 0 {
            break
        }

        let firstObject = toCheck[0]
        let element = firstObject as! AXUIElement
        toCheck.remove(firstObject)

        var cfTitle: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &cfTitle)
        let title = cfTitle as? String

        var childcount: CFIndex = -1
        let childError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childcount)
        if childError != .success {
            skin.logBreadcrumb("Got an error (\(childError.rawValue)) checking child count, skipping")
            continue
        }
        if childcount > 0 {
            var cfMenuchildren: CFArray?
            let menuChildError = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, childcount, &cfMenuchildren)
            if menuChildError != .success {
                skin.logBreadcrumb("Got an error (\(menuChildError.rawValue)) fetching menu children, skipping")
                continue
            }
            if let menuchildren = cfMenuchildren {
                toCheck.addObjects(from: menuchildren as! [Any])
            }
        } else if childcount == 0 {
            if !nameIsRegex && name == title {
                foundItem = element
                break
            } else {
                let matchTest = NSPredicate(format: "SELF MATCHES %@", name)
                if matchTest.evaluate(with: title) {
                    NSLog("win")
                    foundItem = element
                    break
                }
            }
        }
    }

    if i == 0 {
        skin.logWarn("_findmenuitembyname() overflowed 5000 iteration guard. This is either a Hammerspoon bug, or your menus are too deep")
        return nil
    }

    return foundItem
}

private func _findmenuitembypath(_ L: OpaquePointer!, _ app: AXUIElement, _ _path: [String]) -> AXUIElement? {
    let skin = LuaSkin.shared(withState: L)
    var foundItem: AXUIElement?
    let path = NSMutableArray(array: _path)

    var menuBarRef: CFTypeRef?
    var error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef)
    guard error == .success, let menuBar = menuBarRef else {
        return nil
    }

    var searchItem: AXUIElement = menuBar as! AXUIElement

    var i = 5000
    while foundItem == nil && i > 0 {
        i -= 1

        var count: CFIndex = -1
        error = AXUIElementGetAttributeValueCount(searchItem, kAXChildrenAttribute as CFString, &count)
        guard error == .success else {
            skin.logBreadcrumb("Failed to get child count")
            break
        }

        var cfChildren: CFArray?
        error = AXUIElementCopyAttributeValues(searchItem, kAXChildrenAttribute as CFString, 0, count, &cfChildren)
        guard error == .success, var children = cfChildren else {
            skin.logBreadcrumb("Failed to get children")
            break
        }

        if count > 0 {
            let aSearchItem = CFArrayGetValueAtIndex(children, 0)
            let aSearchElement = Unmanaged<AXUIElement>.fromOpaque(aSearchItem!).takeUnretainedValue()
            var cfRole: CFTypeRef?
            error = AXUIElementCopyAttributeValue(aSearchElement, kAXRoleAttribute as CFString, &cfRole)
            guard error == .success else {
                skin.logBreadcrumb("Failed to get role")
                break
            }
            let isMenuRole = CFStringCompare(cfRole as! CFString, kAXMenuRole as CFString, [])
            if isMenuRole == .compareEqualTo {
                var axMenuCount: CFIndex = -1
                error = AXUIElementGetAttributeValueCount(aSearchElement, kAXChildrenAttribute as CFString, &axMenuCount)
                guard error == .success else {
                    skin.logBreadcrumb("Failed to get AXMenu child count")
                    break
                }
                var axMenuChildren: CFArray?
                error = AXUIElementCopyAttributeValues(aSearchElement, kAXChildrenAttribute as CFString, 0, axMenuCount, &axMenuChildren)
                guard error == .success, let newChildren = axMenuChildren else {
                    skin.logBreadcrumb("Failed to get AXMenu children")
                    break
                }
                children = newChildren
            }
        }

        let nextMenuItem = path[0] as! String
        path.removeObject(at: 0)

        var found = false
        let childCount = CFArrayGetCount(children)
        for j in 0..<childCount {
            let testMenuItemPtr = CFArrayGetValueAtIndex(children, j)!
            let testMenuItem = Unmanaged<AXUIElement>.fromOpaque(testMenuItemPtr).takeUnretainedValue()
            var cfTitle: CFTypeRef?
            let titleError = AXUIElementCopyAttributeValue(testMenuItem, kAXTitleAttribute as CFString, &cfTitle)
            if titleError != .success {
                skin.logBreadcrumb("Unable to get menu item title")
                continue
            }
            if nextMenuItem == (cfTitle as? String ?? "") {
                found = true
                searchItem = testMenuItem
                break
            }
        }

        if !found {
            skin.logBreadcrumb("Unable to resolve complete search path")
            break
        }

        if path.count == 0 {
            foundItem = searchItem
            break
        }
    }

    return foundItem
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
private func application_findmenuitem(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TTABLE, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication

    var foundItem: AXUIElement?
    var name: String?
    var path: [String]?

    if lua_isstring(L, 2) != 0 {
        var nameIsRegex = false
        if lua_type(L, 3) == LUA_TBOOLEAN {
            nameIsRegex = lua_toboolean(L, 3) != 0
        }
        name = String(cString: luaL_checklstring(L, 2, nil))
        foundItem = _findmenuitembyname(L, app.elementRef, name!, nameIsRegex)
    } else if lua_istable(L, 2) != 0 {
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
        skin.logWarn("hs.application:findMenuItem() Unrecognised type for menuItem argument. Expecting string or table")
        lua_pushnil(L)
        return 1
    }

    guard let foundItem = foundItem else {
        if let name = name {
            skin.logBreadcrumb("Couldn't find menu item \(name)")
        } else if path != nil {
            skin.logBreadcrumb("Couldn't find menu item")
        }
        lua_pushnil(L)
        return 1
    }

    var enabled: CFTypeRef?
    var error = AXUIElementCopyAttributeValue(foundItem, kAXEnabledAttribute as CFString, &enabled)
    if error != .success {
        skin.logBreadcrumb("hs.application:findMenuItem: AXEnabled Error: \(error.rawValue)")
        lua_pushnil(L)
        return 1
    }

    var markchar: CFTypeRef?
    error = AXUIElementCopyAttributeValue(foundItem, kAXMenuItemMarkCharAttribute as CFString, &markchar)
    if error != .success && error != .noValue {
        skin.logBreadcrumb("hs.application:findMenuItem: AXMenuItemMarkChar: \(error.rawValue)")
        lua_pushnil(L)
        return 1
    }

    let marked: Bool
    if error == .noValue {
        marked = false
    } else {
        marked = true
    }

    lua_newtable(L)

    lua_pushstring(L, "enabled")
    lua_pushboolean(L, (enabled as? NSNumber)?.boolValue == true ? 1 : 0)
    lua_settable(L, -3)

    lua_pushstring(L, "ticked")
    lua_pushboolean(L, marked ? 1 : 0)
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
private func application_selectmenuitem(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TTABLE, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication

    var foundItem: AXUIElement?
    var name: String?

    if lua_isstring(L, 2) != 0 {
        var nameIsRegex = false
        if lua_type(L, 3) == LUA_TBOOLEAN {
            nameIsRegex = lua_toboolean(L, 3) != 0
        }
        name = String(cString: luaL_checklstring(L, 2, nil))
        foundItem = _findmenuitembyname(L, app.elementRef, name!, nameIsRegex)
    } else if lua_istable(L, 2) != 0 {
        var path: [String] = []
        lua_pushnil(L)
        while lua_next(L, 2) != 0 {
            let item = String(cString: luaL_checklstring(L, -1, nil))
            path.append(item)
            lua_pop(L, 1)
        }
        foundItem = _findmenuitembypath(L, app.elementRef, path)
    } else {
        skin.logWarn("hs.application:selectMenuItem(): Unrecognised type for menuItem argument, expecting string or table")
        lua_pushnil(L)
        return 1
    }

    guard let foundItem = foundItem else {
        skin.logBreadcrumb("Couldn't find \(name ?? "")")
        lua_pushnil(L)
        return 1
    }

    let error = AXUIElementPerformAction(foundItem, kAXPressAction as CFString)
    if error != .success {
        skin.logBreadcrumb("hs.application:selectMenuItem(): AXPress error: \(error.rawValue)")
        lua_pushnil(L)
        return 1
    }

    lua_pushboolean(L, 1)
    return 1
}

private func _getMenuStructure(_ menuItem: AXUIElement) -> Any {
    var thisMenuItem: Any? = nil

    let attributeNames = NSMutableArray(array: [
        kAXTitleAttribute as String,
        kAXRoleAttribute as String,
        kAXMenuItemMarkCharAttribute as String,
        kAXMenuItemCmdCharAttribute as String,
        kAXMenuItemCmdModifiersAttribute as String,
        kAXEnabledAttribute as String,
        kAXMenuItemCmdGlyphAttribute as String,
    ])

    var cfAttributeValues: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(menuItem, attributeNames as CFArray, 0, &cfAttributeValues)

    if result != .success {
        LuaSkin.logBreadcrumb("Unable to fetch menu structure")
    } else if let cfValues = cfAttributeValues {
        let firstElement = CFArrayGetValueAtIndex(cfValues, 0)
        if let firstElement = firstElement {
            let typeID = CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(firstElement).takeUnretainedValue())
            if typeID == CFStringGetTypeID() {
                let firstStr = Unmanaged<CFString>.fromOpaque(firstElement).takeUnretainedValue()
                if CFStringCompare(firstStr, "Apple" as CFString, []) == .compareEqualTo {
                    return NSNull()
                }
            }
        }
    }

    if let cfValues = cfAttributeValues {
        let attributeValues = NSMutableArray(array: cfValues as! [Any])
        var children: NSMutableArray? = nil

        for j in 0..<attributeValues.count {
            let attributeValue = attributeValues[j]
            if let axValue = attributeValue as? AXValue {
                if AXValueGetType(axValue) == .axError {
                    attributeValues[j] = ""
                }
            } else if CFGetTypeID(attributeValue as CFTypeRef) == AXValueGetTypeID() {
                let rawType = AXValueGetType(attributeValue as! AXValue)
                if rawType == .axError {
                    attributeValues[j] = ""
                }
            }
        }

        let modifiersIndex = attributeNames.index(of: kAXMenuItemCmdModifiersAttribute as String)
        let modsSrc = attributeValues[modifiersIndex]
        var modsDst: Any

        if let modsNum = modsSrc as? NSNumber {
            let modsInt = modsNum.intValue
            let modsArr = NSMutableArray()
            modsDst = modsArr

            if (modsInt & kAXMenuItemModifierNoCommand) == 0 {
                modsArr.add("cmd")
            }
            if (modsInt & kAXMenuItemModifierShift) != 0 {
                modsArr.add("shift")
            }
            if (modsInt & kAXMenuItemModifierOption) != 0 {
                modsArr.add("alt")
            }
            if (modsInt & kAXMenuItemModifierControl) != 0 {
                modsArr.add("ctrl")
            }
        } else {
            modsDst = NSNull()
        }

        attributeValues[modifiersIndex] = modsDst

        var cfChildren: CFArray?
        if AXUIElementCopyAttributeValues(menuItem, kAXChildrenAttribute as CFString, 0, CFIndex(INT32_MAX), &cfChildren) == .success {
            children = NSMutableArray()
            if let cfChildren = cfChildren {
                let numChildren = CFArrayGetCount(cfChildren)
                for i in 0..<numChildren {
                    let childPtr = CFArrayGetValueAtIndex(cfChildren, i)!
                    let child = Unmanaged<AXUIElement>.fromOpaque(childPtr).takeUnretainedValue()
                    let childValues = _getMenuStructure(child)

                    if !(childValues is NSNull) {
                        children!.add(childValues)
                    }
                }
            }

            if let children = children, children.count > 0 {
                attributeNames.add(kAXChildrenAttribute as String)
                attributeValues.add(children)
            }
        }

        let roleValue = attributeValues[1] as? String ?? ""
        if roleValue == "AXMenuItem" || roleValue == "AXMenuBarItem" {
            thisMenuItem = NSMutableDictionary(objects: attributeValues as! [Any], forKeys: attributeNames as! [NSCopying])
        } else {
            thisMenuItem = children
        }
    }

    if let thisMenuItem = thisMenuItem as? NSObject, thisMenuItem.responds(to: Selector(("count"))) {
        let count = (thisMenuItem as AnyObject).count ?? 0
        if count > 0 {
            return thisMenuItem
        }
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
///  * In some applications, this can take a little while to complete, because quite a large number of round trips are required to the source application, to get the information. When this method is invoked without a callback function, Hammerspoon will block while creating the menu structure table.  When invoked with a callback function, the menu structure is built in a background thread.
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
private func application_getMenus(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication

    if lua_gettop(L) == 1 {
        var menus: NSMutableDictionary? = nil
        var menuBarRef: CFTypeRef?

        if AXUIElementCopyAttributeValue(app.elementRef, kAXMenuBarAttribute as CFString, &menuBarRef) == .success {
            let menuBar = menuBarRef as! AXUIElement
            let result = _getMenuStructure(menuBar)
            menus = result as? NSMutableDictionary
        }

        skin.pushNSObject(menus)
    } else {
        lua_pushvalue(L, 2)
        let fnRef = luaL_ref(L, LUA_REGISTRYINDEX)
        backgroundCallbacks.add(NSNumber(value: fnRef))

        let elementRef = app.elementRef!

        DispatchQueue.main.async {
            if backgroundCallbacks.contains(NSNumber(value: fnRef)) {
                var menus: NSMutableDictionary? = nil
                var menuBarRef: CFTypeRef?

                let result = AXUIElementCopyAttributeValue(elementRef, kAXMenuBarAttribute as CFString, &menuBarRef)
                if result == .success {
                    let menuBar = menuBarRef as! AXUIElement
                    let menuResult = _getMenuStructure(menuBar)
                    menus = menuResult as? NSMutableDictionary
                }

                let _skin = LuaSkin.shared(withState: nil)
                lua_rawgeti(_skin.l, LUA_REGISTRYINDEX, lua_Integer(fnRef))
                _skin.pushNSObject(menus)
                _skin.protectedCallAndError("hs.application:getMenus()", nargs: 1, nresults: 0)
                luaL_unref(_skin.l, LUA_REGISTRYINDEX, fnRef)
                backgroundCallbacks.remove(NSNumber(value: fnRef))
            }
        }
        lua_pushvalue(L, 1)
    }

    return 1
}

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
private func application_launchorfocus(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    lua_pushboolean(L, HSapplication.launch(byName: skin.toNSObject(atIndex: 1) as! String) ? 1 : 0)
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
private func application_launchorfocusbybundleID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    lua_pushboolean(L, HSapplication.launch(byBundleID: skin.toNSObject(atIndex: 1) as! String) ? 1 : 0)
    return 1
}

// MARK: - hs.uielement methods

private func application_uielement_isApplication(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement
    lua_pushboolean(L, uiElement.role == "AXApplication" ? 1 : 0)
    return 1
}

private func application_uielement_isWindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement
    lua_pushboolean(L, uiElement.isWindow ? 1 : 0)
    return 1
}

private func application_uielement_role(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement
    skin.pushNSObject(uiElement.role)
    return 1
}

private func application_uielement_selectedText(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement
    skin.pushNSObject(uiElement.selectedText)
    return 1
}

private func application_uielement_newWatcher(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION, LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let uiElement = app.uiElement
    let watcher = uiElement.newWatcher(atIndex: 2, withUserdataAt: 3, withLuaState: L)
    skin.pushNSObject(watcher)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSapplication(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    guard let value = obj as? HSapplication else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    let retained = Unmanaged.passRetained(value).toOpaque()
    valuePtr.storeBytes(of: retained, as: UnsafeMutableRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSapplicationFromLua(_ L: OpaquePointer!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.shared(withState: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return get_objectFromUserdata(HSapplication.self, L, idx, USERDATA_TAG)
    } else {
        skin.logError("expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let app: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
    let str = "\(USERDATA_TAG): \(app.title() ?? "?") (\(lua_topointer(L, 1)!))"
    lua_pushstring(L, str)
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    var isEqual = false
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)
        let app1: HSapplication = skin.toNSObject(atIndex: 1) as! HSapplication
        let app2: HSapplication = skin.toNSObject(atIndex: 2) as! HSapplication
        isEqual = app1.runningApp.isEqual(app2.runningApp)
    }
    lua_pushboolean(L, isEqual ? 1 : 0)
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let rawPtr = ptr.load(as: UnsafeMutableRawPointer.self)
    let app = Unmanaged<HSapplication>.fromOpaque(rawPtr).takeRetainedValue()
    app.selfRefCount -= 1
    if app.selfRefCount == 0 {
        _ = app
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("runningApplications"), func: application_runningapplications),
    luaL_Reg(name: strdup("frontmostApplication"), func: application_frontmostapplication),
    luaL_Reg(name: strdup("applicationForPID"), func: application_applicationforpid),
    luaL_Reg(name: strdup("applicationsForBundleID"), func: application_applicationsForBundleID),
    luaL_Reg(name: strdup("nameForBundleID"), func: application_nameForBundleID),
    luaL_Reg(name: strdup("pathForBundleID"), func: application_pathForBundleID),
    luaL_Reg(name: strdup("infoForBundleID"), func: application_infoForBundleID),
    luaL_Reg(name: strdup("infoForBundlePath"), func: application_infoForBundlePath),
    luaL_Reg(name: strdup("preferredLocalizationsForBundleID"), func: application_preferredLocalizationsForBundleID),
    luaL_Reg(name: strdup("preferredLocalizationsForBundlePath"), func: application_preferredLocalizationsForBundlePath),
    luaL_Reg(name: strdup("localizationsForBundleID"), func: application_localizationsForBundleID),
    luaL_Reg(name: strdup("localizationsForBundlePath"), func: application_localizationsForBundlePath),
    luaL_Reg(name: strdup("defaultAppForUTI"), func: application_bundleForUTI),
    luaL_Reg(name: strdup("launchOrFocus"), func: application_launchorfocus),
    luaL_Reg(name: strdup("launchOrFocusByBundleID"), func: application_launchorfocusbybundleID),
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: application_gc),
    luaL_Reg(name: nil, func: nil),
]

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("allWindows"), func: application_allWindows),
    luaL_Reg(name: strdup("mainWindow"), func: application_mainWindow),
    luaL_Reg(name: strdup("focusedWindow"), func: application_focusedWindow),
    luaL_Reg(name: strdup("_activate"), func: application__activate),
    luaL_Reg(name: strdup("_bringtofront"), func: application__bringtofront),
    luaL_Reg(name: strdup("title"), func: application_title),
    luaL_Reg(name: strdup("name"), func: application_title),
    luaL_Reg(name: strdup("bundleID"), func: application_bundleID),
    luaL_Reg(name: strdup("path"), func: application_path),
    luaL_Reg(name: strdup("isRunning"), func: application_isRunning),
    luaL_Reg(name: strdup("unhide"), func: application_unhide),
    luaL_Reg(name: strdup("hide"), func: application_hide),
    luaL_Reg(name: strdup("kill"), func: application_kill),
    luaL_Reg(name: strdup("kill9"), func: application_kill9),
    luaL_Reg(name: strdup("isHidden"), func: application_ishidden),
    luaL_Reg(name: strdup("isFrontmost"), func: application_isfrontmost),
    luaL_Reg(name: strdup("setFrontmost"), func: application_setfrontmost),
    luaL_Reg(name: strdup("pid"), func: application_pid),
    luaL_Reg(name: strdup("isUnresponsive"), func: application_isunresponsive),
    luaL_Reg(name: strdup("kind"), func: application_kind),
    luaL_Reg(name: strdup("findMenuItem"), func: application_findmenuitem),
    luaL_Reg(name: strdup("selectMenuItem"), func: application_selectmenuitem),
    luaL_Reg(name: strdup("getMenuItems"), func: application_getMenus),
    luaL_Reg(name: strdup("isApplication"), func: application_uielement_isApplication),
    luaL_Reg(name: strdup("isWindow"), func: application_uielement_isWindow),
    luaL_Reg(name: strdup("role"), func: application_uielement_role),
    luaL_Reg(name: strdup("selectedText"), func: application_uielement_selectedText),
    luaL_Reg(name: strdup("newWatcher"), func: application_uielement_newWatcher),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libapplication")
func luaopen_hs_libapplication(_ L: OpaquePointer!) -> Int32 {
    backgroundCallbacks = NSMutableSet()

    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &module_metaLib)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushHSapplication, forClass: "HSapplication")
    skin.registerLuaObjectHelper(toHSapplicationFromLua, forClass: "HSapplication", withUserdataMapping: USERDATA_TAG)
    return 1
}
