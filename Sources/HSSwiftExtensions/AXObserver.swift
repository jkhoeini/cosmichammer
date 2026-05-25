import Cocoa
import LuaSkin

// MARK: observer.m — AXObserver Wrapper
// MARK: ============================================================

var observerRefTable: LSRefTable = LUA_NOREF

var observerDetails: NSMutableDictionary? = nil

let keySelfRefCount = "selfRefCount" as CFString
let keyCallbackRef  = "callbackRef" as CFString
let keyIsRunning    = "isRunning" as CFString
let keyWatching     = "watching" as CFString

// MARK: - Support Functions (observer)

@_cdecl("pushAXObserver")
@discardableResult
public func pushAXObserver(_ L: UnsafeMutablePointer<lua_State>!, _ observer: AXObserver) -> Int32 {
    if observerDetails == nil {
        observerDetails = NSMutableDictionary()
    }

    let observerKey = observer as AnyObject
    var details = observerDetails![observerKey] as? NSMutableDictionary
    if details == nil {
        details = NSMutableDictionary()
        details![keySelfRefCount as String] = NSNumber(value: 0 as Int32)
        details![keyCallbackRef as String]  = NSNumber(value: LUA_NOREF)
        details![keyIsRunning as String]    = NSNumber(value: false)
        details![keyWatching as String]     = NSMutableDictionary()
        observerDetails![observerKey] = details
    }

    var selfRefCount = (details![keySelfRefCount as String] as! NSNumber).int32Value
    selfRefCount += 1
    details![keySelfRefCount as String] = NSNumber(value: selfRefCount)

    let thePtr = lua_newuserdata(L, MemoryLayout<Unmanaged<AXObserver>>.size)!
        .assumingMemoryBound(to: Unmanaged<AXObserver>.self)
    thePtr.pointee = Unmanaged.passRetained(observer)
    luaL_getmetatable(L, axuielement_OBSERVER_TAG)
    lua_setmetatable(L, -2)
    return 1
}

func purgeWatchers(element: AXUIElement, notifications: NSMutableArray, observer: AXObserver) {
    for notification in notifications {
        guard let what = notification as? String else { continue }
        AXObserverRemoveNotification(observer, element, what as CFString)
    }
    notifications.removeAllObjects()
}

func cleanupAXObserver(_ observer: AXObserver, _ details: NSMutableDictionary) {
    let skin = LuaSkin.skin(with: nil)

    var callbackRef = (details[keyCallbackRef as String] as? NSNumber)?.int32Value ?? LUA_NOREF
    callbackRef = skin.luaUnref(observerRefTable, ref: callbackRef)
    details[keyCallbackRef as String] = NSNumber(value: callbackRef)

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    if isRunning {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        details[keyIsRunning as String] = NSNumber(value: false)
    }

    // clean up the `watching` dictionary
    if let watching = details[keyWatching as String] as? NSMutableDictionary {
        for (key, value) in watching {
            let element = unsafeBitCast(key as AnyObject, to: AXUIElement.self)
            if let notifications = value as? NSMutableArray {
                purgeWatchers(element: element, notifications: notifications, observer: observer)
            }
        }
        watching.removeAllObjects()
        details.removeObject(forKey: keyWatching as String)
    }

    details.removeAllObjects()
}

let observerCallbackPtr: AXObserverCallbackWithInfo = { (observer, element, notification, info, refcon) in
    let skin = LuaSkin.skin(with: nil)
    let L = skin.l!

    let observerKey = observer as AnyObject
    guard let details = observerDetails?[observerKey] as? NSMutableDictionary else {
        skin.logWarn("\(String(cString: axuielement_OBSERVER_TAG)):callback triggered for unregistered observer")
        return
    }

    let callbackRef = (details[keyCallbackRef as String] as? NSNumber)?.int32Value ?? LUA_NOREF
    if callbackRef != LUA_NOREF {
        skin.pushLuaRef(observerRefTable, ref: callbackRef)
        pushAXObserver(L, observer)
        pushAXUIElement(L, element)
        skin.pushNSObject(notification as String)
        pushCFTypeToLua(L, info, observerRefTable)
        if !skin.protectedCallAndTraceback(4, nresults: 0) {
            skin.logError("\(String(cString: axuielement_OBSERVER_TAG)):callback error:\(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions (observer)

/// hs.axuielement.observer.new(pid) -> observerObject
private func axobserver_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let appPid = pid_t(lua_tointeger(L, 1))
    var observer: AXObserver?
    let err = AXObserverCreateWithInfoCallback(appPid, observerCallbackPtr, &observer)

    if err != .success { return luaL_error(L, String(cString: AXErrorAsString(err))) }

    pushAXObserver(L, observer!)
    // ARC manages the extra reference from AXObserverCreateWithInfoCallback;
    // pushAXObserver uses Unmanaged.passRetained, so no manual release needed.
    return 1
}

// MARK: - Module Methods (observer)

/// hs.axuielement.observer:start() -> observerObject
private func axobserver_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    if !isRunning {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        details[keyIsRunning as String] = NSNumber(value: true)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:stop() -> observerObject
private func axobserver_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    if isRunning {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        details[keyIsRunning as String] = NSNumber(value: false)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:isRunning() -> boolean
private func axobserver_isRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    lua_pushboolean(L, isRunning ? 1 : 0)
    return 1
}

/// hs.axuielement.observer:callback([fn]) -> observerObject | fn | nil
private func axobserver_callback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    var callbackRef = (details[keyCallbackRef as String] as? NSNumber)?.int32Value ?? LUA_NOREF
    if lua_gettop(L) == 2 {
        callbackRef = skin.luaUnref(observerRefTable, ref: callbackRef)
        details[keyCallbackRef as String] = NSNumber(value: callbackRef)
        if lua_type(L, 2) != LUA_TNIL {
            lua_pushvalue(L, 2)
            callbackRef = skin.luaRef(observerRefTable)
            details[keyCallbackRef as String] = NSNumber(value: callbackRef)
            lua_pushvalue(L, 1)
        }
    } else {
        if callbackRef != LUA_NOREF {
            skin.pushLuaRef(observerRefTable, ref: callbackRef)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.axuielement.observer:addWatcher(element, notification) -> observerObject
private func axobserver_addWatchedElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TUSERDATA, axuielement_USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary
    let element  = get_axuielementref(L, 2, axuielement_USERDATA_TAG)
    let what     = skin.toNSObject(atIndex: 3) as! String

    let watching = details[keyWatching as String] as! NSMutableDictionary
    let elementKey = element as AnyObject
    var notifications = watching[elementKey] as? NSMutableArray

    var exists = false
    if let notifications = notifications {
        exists = notifications.contains(what)
    } else {
        notifications = NSMutableArray()
        watching[elementKey] = notifications
    }
    if !exists {
        let err = AXObserverAddNotification(observer, element, what as CFString, nil)
        if err != .success { return luaL_error(L, String(cString: AXErrorAsString(err))) }
        notifications!.add(what)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:removeWatcher(element, notification) -> observerObject
private func axobserver_removeWatchedElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TUSERDATA, axuielement_USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary
    let element  = get_axuielementref(L, 2, axuielement_USERDATA_TAG)
    let what     = skin.toNSObject(atIndex: 3) as! String

    let watching = details[keyWatching as String] as! NSMutableDictionary
    let elementKey = element as AnyObject
    let notifications = watching[elementKey] as? NSMutableArray

    if let notifications = notifications, let idx = notifications.index(of: what) as? Int, idx != NSNotFound {
        let err = AXObserverRemoveNotification(observer, element, what as CFString)
        notifications.removeObject(at: idx)
        if err != .success { return luaL_error(L, String(cString: AXErrorAsString(err))) }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:watching([element]) -> table
private func axobserver_watchedElements(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TBREAK | LS_TVARARG)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    var element: AXUIElement? = nil
    if lua_gettop(L) > 1 {
        skin.checkArgs(LS_TUSERDATA, axuielement_OBSERVER_TAG, LS_TUSERDATA, axuielement_USERDATA_TAG, LS_TBREAK)
        element = get_axuielementref(L, 2, axuielement_USERDATA_TAG)
    }

    let watching = details[keyWatching as String] as! NSMutableDictionary
    if let element = element {
        let elementKey = element as AnyObject
        if let notifications = watching[elementKey] as? NSArray {
            pushCFTypeToLua(L, notifications as CFTypeRef, observerRefTable)
        } else {
            lua_newtable(L)
        }
    } else {
        // Build a table of element -> notifications
        lua_newtable(L)
        for (key, value) in watching {
            let elem = unsafeBitCast(key as AnyObject, to: AXUIElement.self)
            if let notifs = value as? NSArray {
                pushAXUIElement(L, elem)
                pushCFTypeToLua(L, notifs as CFTypeRef, observerRefTable)
                lua_settable(L, -3)
            }
        }
    }
    return 1
}

// MARK: - Module Constants (observer)

private func pushNotificationsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    // Focus notifications
    skin.pushNSObject(kAXMainWindowChangedNotification as String);       lua_setfield(L, -2, "mainWindowChanged")
    skin.pushNSObject(kAXFocusedWindowChangedNotification as String);    lua_setfield(L, -2, "focusedWindowChanged")
    skin.pushNSObject(kAXFocusedUIElementChangedNotification as String); lua_setfield(L, -2, "focusedUIElementChanged")
    // Application notifications
    skin.pushNSObject(kAXApplicationActivatedNotification as String);    lua_setfield(L, -2, "applicationActivated")
    skin.pushNSObject(kAXApplicationDeactivatedNotification as String);  lua_setfield(L, -2, "applicationDeactivated")
    skin.pushNSObject(kAXApplicationHiddenNotification as String);       lua_setfield(L, -2, "applicationHidden")
    skin.pushNSObject(kAXApplicationShownNotification as String);        lua_setfield(L, -2, "applicationShown")
    // Window notifications
    skin.pushNSObject(kAXWindowCreatedNotification as String);           lua_setfield(L, -2, "windowCreated")
    skin.pushNSObject(kAXWindowMovedNotification as String);             lua_setfield(L, -2, "windowMoved")
    skin.pushNSObject(kAXWindowResizedNotification as String);           lua_setfield(L, -2, "windowResized")
    skin.pushNSObject(kAXWindowMiniaturizedNotification as String);      lua_setfield(L, -2, "windowMiniaturized")
    skin.pushNSObject(kAXWindowDeminiaturizedNotification as String);    lua_setfield(L, -2, "windowDeminiaturized")
    // New drawer, sheet, and help tag notifications
    skin.pushNSObject(kAXDrawerCreatedNotification as String);           lua_setfield(L, -2, "drawerCreated")
    skin.pushNSObject(kAXSheetCreatedNotification as String);            lua_setfield(L, -2, "sheetCreated")
    skin.pushNSObject(kAXHelpTagCreatedNotification as String);          lua_setfield(L, -2, "helpTagCreated")
    // Element notifications
    skin.pushNSObject(kAXValueChangedNotification as String);            lua_setfield(L, -2, "valueChanged")
    skin.pushNSObject(kAXUIElementDestroyedNotification as String);      lua_setfield(L, -2, "uIElementDestroyed")
    skin.pushNSObject(kAXElementBusyChangedNotification as String);      lua_setfield(L, -2, "elementBusyChanged")
    // Menu notifications
    skin.pushNSObject(kAXMenuOpenedNotification as String);              lua_setfield(L, -2, "menuOpened")
    skin.pushNSObject(kAXMenuClosedNotification as String);              lua_setfield(L, -2, "menuClosed")
    skin.pushNSObject(kAXMenuItemSelectedNotification as String);        lua_setfield(L, -2, "menuItemSelected")
    // Table and outline view notifications
    skin.pushNSObject(kAXRowCountChangedNotification as String);         lua_setfield(L, -2, "rowCountChanged")
    skin.pushNSObject(kAXRowCollapsedNotification as String);            lua_setfield(L, -2, "rowCollapsed")
    skin.pushNSObject(kAXRowExpandedNotification as String);             lua_setfield(L, -2, "rowExpanded")
    // Miscellaneous notifications
    skin.pushNSObject(kAXSelectedChildrenChangedNotification as String); lua_setfield(L, -2, "selectedChildrenChanged")
    skin.pushNSObject(kAXResizedNotification as String);                 lua_setfield(L, -2, "resized")
    skin.pushNSObject(kAXMovedNotification as String);                   lua_setfield(L, -2, "moved")
    skin.pushNSObject(kAXCreatedNotification as String);                 lua_setfield(L, -2, "created")
    skin.pushNSObject(kAXAnnouncementRequestedNotification as String);   lua_setfield(L, -2, "announcementRequested")
    skin.pushNSObject(kAXLayoutChangedNotification as String);           lua_setfield(L, -2, "layoutChanged")
    skin.pushNSObject(kAXSelectedCellsChangedNotification as String);    lua_setfield(L, -2, "selectedCellsChanged")
    skin.pushNSObject(kAXSelectedChildrenMovedNotification as String);   lua_setfield(L, -2, "selectedChildrenMoved")
    skin.pushNSObject(kAXSelectedColumnsChangedNotification as String);  lua_setfield(L, -2, "selectedColumnsChanged")
    skin.pushNSObject(kAXSelectedRowsChangedNotification as String);     lua_setfield(L, -2, "selectedRowsChanged")
    skin.pushNSObject(kAXSelectedTextChangedNotification as String);     lua_setfield(L, -2, "selectedTextChanged")
    skin.pushNSObject(kAXTitleChangedNotification as String);            lua_setfield(L, -2, "titleChanged")
    skin.pushNSObject(kAXUnitsChangedNotification as String);            lua_setfield(L, -2, "unitsChanged")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure (observer)

private func observer_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let tagStr = String(cString: axuielement_OBSERVER_TAG)
    let ptr = Int(bitPattern: lua_topointer(L, 1))
    skin.pushNSObject(NSString(format: "%@: (0x%lx)", tagStr as NSString, ptr))
    return 1
}

private func observer_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject

    guard let details = observerDetails?[observerKey] as? NSMutableDictionary else {
        skin.logWarn("\(String(cString: axuielement_OBSERVER_TAG)):__gc triggered for unregistered observer")
        lua_pushnil(L)
        lua_setmetatable(L, 1)
        return 0
    }

    var selfRefCount = (details[keySelfRefCount as String] as! NSNumber).int32Value
    selfRefCount -= 1
    details[keySelfRefCount as String] = NSNumber(value: selfRefCount)
    if selfRefCount == 0 {
        cleanupAXObserver(observer, details)
        observerDetails?.removeObject(forKey: observerKey)
    }

    // Release the observer reference that pushAXObserver retained
    let ptr = UnsafeMutableRawPointer(lua_touserdata(L, 1))!.assumingMemoryBound(to: Unmanaged<AXObserver>.self)
    ptr.pointee.release()

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func observer_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let observer1 = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observer2 = get_axobserverref(L, 2, axuielement_OBSERVER_TAG)
    lua_pushboolean(L, CFEqual(observer1, observer2) ? 1 : 0)
    return 1
}

private func observer_meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let od = observerDetails {
        for (key, value) in od {
            let observer = unsafeBitCast(key as AnyObject, to: AXObserver.self)
            if let details = value as? NSMutableDictionary {
                cleanupAXObserver(observer, details)
            }
        }
        od.removeAllObjects()
        observerDetails = nil
    }
    return 0
}

// Metatable for observer userdata
private var observer_userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),         func: axobserver_start),
    luaL_Reg(name: strdup("stop"),          func: axobserver_stop),
    luaL_Reg(name: strdup("isRunning"),     func: axobserver_isRunning),
    luaL_Reg(name: strdup("callback"),      func: axobserver_callback),
    luaL_Reg(name: strdup("addWatcher"),    func: axobserver_addWatchedElement),
    luaL_Reg(name: strdup("removeWatcher"), func: axobserver_removeWatchedElement),
    luaL_Reg(name: strdup("watching"),      func: axobserver_watchedElements),
    luaL_Reg(name: strdup("__tostring"),    func: observer_userdata_tostring),
    luaL_Reg(name: strdup("__eq"),          func: observer_userdata_eq),
    luaL_Reg(name: strdup("__gc"),          func: observer_userdata_gc),
    luaL_Reg(name: nil,                     func: nil),
]

// Module functions
private var observer_moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: axobserver_new),
    luaL_Reg(name: nil,           func: nil),
]

// Module metatable
private var observer_module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: observer_meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

@_cdecl("luaopen_hs_libaxuielementobserver")
@discardableResult
public func luaopen_hs_libaxuielementobserver(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    observerRefTable = skin.registerLibrary(withObject: axuielement_OBSERVER_TAG,
                                            functions: &observer_moduleLib,
                                            metaFunctions: &observer_module_metaLib,
                                            objectFunctions: &observer_userdata_metaLib)

    if observerDetails == nil {
        observerDetails = NSMutableDictionary()
    }

    pushNotificationsTable(L); lua_setfield(L, -2, "notifications")

    return 1
}
