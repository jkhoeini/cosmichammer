import Cocoa
import CLua
import Lua
import os.log

// MARK: observer.m — AXObserver Wrapper
// MARK: ============================================================

var observerRefTable: Int32 = LUA_NOREF

var observerDetails: NSMutableDictionary? = nil

let keySelfRefCount = "selfRefCount" as CFString
let keyCallbackRef  = "callbackRef" as CFString  // value is LuaValue? (not NSNumber)
let keyIsRunning    = "isRunning" as CFString
let keyWatching     = "watching" as CFString
let keyGeneration   = "generation" as CFString    // value is NSNumber (UInt64)

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
        // callbackRef is stored as LuaValue? — nil means no callback
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
        _ = catchingObjCException { AXObserverRemoveNotification(observer, element, what as CFString) }
    }
    notifications.removeAllObjects()
}

func cleanupAXObserver(_ observer: AXObserver, _ details: NSMutableDictionary) {
    // Drop the LuaValue callback ref (releases while L is still open)
    details.removeObject(forKey: keyCallbackRef as String)

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
    let observerKey = observer as AnyObject
    guard let details = observerDetails?[observerKey] as? NSMutableDictionary else {
        os_log(.info, "%{public}s", "\(String(cString: axuielement_OBSERVER_TAG)):callback triggered for unregistered observer")
        return
    }

    let generation = (details[keyGeneration as String] as? NSNumber)?.uint64Value ?? 0
    guard lua_isStateGenerationValid(generation) else { return }

    let L = lua_getCurrentState()!

    if let cb = details[keyCallbackRef as String] as? LuaValue {
        cb.push(onto: L)
        pushAXObserver(L, observer)
        pushAXUIElement(L, element)
        lua_pushany(L, notification as String)
        pushCFTypeToLua(L, info, observerRefTable)
        if lua_pcall(L, 4, 0, 0) != LUA_OK {
            os_log(.error, "%{public}s", "\(String(cString: axuielement_OBSERVER_TAG)):callback error:\(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions (observer)

/// hs.axuielement.observer.new(pid) -> observerObject
private func axobserver_new(_ L: LuaState) throws -> CInt {
    let appPid = pid_t(lua_tointeger(L, 1))
    var observer: AXObserver?
    let err = AXObserverCreateWithInfoCallback(appPid, observerCallbackPtr, &observer)

    if err != .success { throw LuaCallError(String(cString: AXErrorAsString(err))) }

    pushAXObserver(L, observer!)
    // ARC manages the extra reference from AXObserverCreateWithInfoCallback;
    // pushAXObserver uses Unmanaged.passRetained, so no manual release needed.
    return 1
}

// MARK: - Module Methods (observer)

/// hs.axuielement.observer:start() -> observerObject
private func axobserver_start(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_OBSERVER_TAG)
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
private func axobserver_stop(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_OBSERVER_TAG)
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
private func axobserver_isRunning(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_OBSERVER_TAG)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    let isRunning = (details[keyIsRunning as String] as? NSNumber)?.boolValue ?? false
    lua_pushboolean(L, isRunning ? 1 : 0)
    return 1
}

/// hs.axuielement.observer:callback([fn]) -> observerObject | fn | nil
private func axobserver_callback(_ L: LuaState) throws -> CInt {
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    if lua_gettop(L) == 2 {
        // Drop existing callback (LuaValue? released automatically)
        details.removeObject(forKey: keyCallbackRef as String)

        if lua_type(L, 2) != LUA_TNIL {
            let cb = L.ref(index: 2)
            details[keyCallbackRef as String] = cb
            details[keyGeneration as String] = NSNumber(value: lua_currentStateGeneration())
            lua_pushvalue(L, 1)
        }
    } else {
        if let cb = details[keyCallbackRef as String] as? LuaValue {
            cb.push(onto: L)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.axuielement.observer:addWatcher(element, notification) -> observerObject
private func axobserver_addWatchedElement(_ L: LuaState) throws -> CInt {
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary
    let element  = get_axuielementref(L, 2, axuielement_USERDATA_TAG)
    let what     = lua_tovalue(L, at: 3) as! String

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
        var err: AXError = .success
        if let exMsg = catchingObjCException({
            err = AXObserverAddNotification(observer, element, what as CFString, nil)
        }) {
            throw LuaCallError("ObjC exception in AXObserverAddNotification: \(exMsg)")
        }
        if err != .success { throw LuaCallError(String(cString: AXErrorAsString(err))) }
        notifications!.add(what)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:removeWatcher(element, notification) -> observerObject
private func axobserver_removeWatchedElement(_ L: LuaState) throws -> CInt {
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary
    let element  = get_axuielementref(L, 2, axuielement_USERDATA_TAG)
    let what     = lua_tovalue(L, at: 3) as! String

    let watching = details[keyWatching as String] as! NSMutableDictionary
    let elementKey = element as AnyObject
    let notifications = watching[elementKey] as? NSMutableArray

    if let notifications = notifications, let idx = notifications.index(of: what) as? Int, idx != NSNotFound {
        var err: AXError = .success
        if let exMsg = catchingObjCException({
            err = AXObserverRemoveNotification(observer, element, what as CFString)
        }) {
            throw LuaCallError("ObjC exception in AXObserverRemoveNotification: \(exMsg)")
        }
        notifications.removeObject(at: idx)
        if err != .success { throw LuaCallError(String(cString: AXErrorAsString(err))) }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:watching([element]) -> table
private func axobserver_watchedElements(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, axuielement_OBSERVER_TAG)
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject
    let details = observerDetails![observerKey] as! NSMutableDictionary

    var element: AXUIElement? = nil
    if lua_gettop(L) > 1 {
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

private func pushNotificationsTable(_ L: LuaState) throws -> CInt {
    lua_newtable(L)
    // Focus notifications
    lua_pushany(L, kAXMainWindowChangedNotification as String);       lua_setfield(L, -2, "mainWindowChanged")
    lua_pushany(L, kAXFocusedWindowChangedNotification as String);    lua_setfield(L, -2, "focusedWindowChanged")
    lua_pushany(L, kAXFocusedUIElementChangedNotification as String); lua_setfield(L, -2, "focusedUIElementChanged")
    // Application notifications
    lua_pushany(L, kAXApplicationActivatedNotification as String);    lua_setfield(L, -2, "applicationActivated")
    lua_pushany(L, kAXApplicationDeactivatedNotification as String);  lua_setfield(L, -2, "applicationDeactivated")
    lua_pushany(L, kAXApplicationHiddenNotification as String);       lua_setfield(L, -2, "applicationHidden")
    lua_pushany(L, kAXApplicationShownNotification as String);        lua_setfield(L, -2, "applicationShown")
    // Window notifications
    lua_pushany(L, kAXWindowCreatedNotification as String);           lua_setfield(L, -2, "windowCreated")
    lua_pushany(L, kAXWindowMovedNotification as String);             lua_setfield(L, -2, "windowMoved")
    lua_pushany(L, kAXWindowResizedNotification as String);           lua_setfield(L, -2, "windowResized")
    lua_pushany(L, kAXWindowMiniaturizedNotification as String);      lua_setfield(L, -2, "windowMiniaturized")
    lua_pushany(L, kAXWindowDeminiaturizedNotification as String);    lua_setfield(L, -2, "windowDeminiaturized")
    // New drawer, sheet, and help tag notifications
    lua_pushany(L, kAXDrawerCreatedNotification as String);           lua_setfield(L, -2, "drawerCreated")
    lua_pushany(L, kAXSheetCreatedNotification as String);            lua_setfield(L, -2, "sheetCreated")
    lua_pushany(L, kAXHelpTagCreatedNotification as String);          lua_setfield(L, -2, "helpTagCreated")
    // Element notifications
    lua_pushany(L, kAXValueChangedNotification as String);            lua_setfield(L, -2, "valueChanged")
    lua_pushany(L, kAXUIElementDestroyedNotification as String);      lua_setfield(L, -2, "uIElementDestroyed")
    lua_pushany(L, kAXElementBusyChangedNotification as String);      lua_setfield(L, -2, "elementBusyChanged")
    // Menu notifications
    lua_pushany(L, kAXMenuOpenedNotification as String);              lua_setfield(L, -2, "menuOpened")
    lua_pushany(L, kAXMenuClosedNotification as String);              lua_setfield(L, -2, "menuClosed")
    lua_pushany(L, kAXMenuItemSelectedNotification as String);        lua_setfield(L, -2, "menuItemSelected")
    // Table and outline view notifications
    lua_pushany(L, kAXRowCountChangedNotification as String);         lua_setfield(L, -2, "rowCountChanged")
    lua_pushany(L, kAXRowCollapsedNotification as String);            lua_setfield(L, -2, "rowCollapsed")
    lua_pushany(L, kAXRowExpandedNotification as String);             lua_setfield(L, -2, "rowExpanded")
    // Miscellaneous notifications
    lua_pushany(L, kAXSelectedChildrenChangedNotification as String); lua_setfield(L, -2, "selectedChildrenChanged")
    lua_pushany(L, kAXResizedNotification as String);                 lua_setfield(L, -2, "resized")
    lua_pushany(L, kAXMovedNotification as String);                   lua_setfield(L, -2, "moved")
    lua_pushany(L, kAXCreatedNotification as String);                 lua_setfield(L, -2, "created")
    lua_pushany(L, kAXAnnouncementRequestedNotification as String);   lua_setfield(L, -2, "announcementRequested")
    lua_pushany(L, kAXLayoutChangedNotification as String);           lua_setfield(L, -2, "layoutChanged")
    lua_pushany(L, kAXSelectedCellsChangedNotification as String);    lua_setfield(L, -2, "selectedCellsChanged")
    lua_pushany(L, kAXSelectedChildrenMovedNotification as String);   lua_setfield(L, -2, "selectedChildrenMoved")
    lua_pushany(L, kAXSelectedColumnsChangedNotification as String);  lua_setfield(L, -2, "selectedColumnsChanged")
    lua_pushany(L, kAXSelectedRowsChangedNotification as String);     lua_setfield(L, -2, "selectedRowsChanged")
    lua_pushany(L, kAXSelectedTextChangedNotification as String);     lua_setfield(L, -2, "selectedTextChanged")
    lua_pushany(L, kAXTitleChangedNotification as String);            lua_setfield(L, -2, "titleChanged")
    lua_pushany(L, kAXUnitsChangedNotification as String);            lua_setfield(L, -2, "unitsChanged")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure (observer)

private func observer_userdata_tostring(_ L: LuaState) throws -> CInt {
    let tagStr = String(cString: axuielement_OBSERVER_TAG)
    let ptr = Int(bitPattern: lua_topointer(L, 1))
    lua_pushany(L, NSString(format: "%@: (0x%lx)", tagStr as NSString, ptr))
    return 1
}

private func observer_userdata_gc(_ L: LuaState) throws -> CInt {
    let observer = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observerKey = observer as AnyObject

    guard let details = observerDetails?[observerKey] as? NSMutableDictionary else {
        os_log(.info, "%{public}s", "\(String(cString: axuielement_OBSERVER_TAG)):__gc triggered for unregistered observer")
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

private func observer_userdata_eq(_ L: LuaState) throws -> CInt {
    let observer1 = get_axobserverref(L, 1, axuielement_OBSERVER_TAG)
    let observer2 = get_axobserverref(L, 2, axuielement_OBSERVER_TAG)
    lua_pushboolean(L, CFEqual(observer1, observer2) ? 1 : 0)
    return 1
}

private func observer_meta_gc(_ L: LuaState) throws -> CInt {
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

@_cdecl("luaopen_hs_libaxuielementobserver")
@discardableResult
public func luaopen_hs_libaxuielementobserver(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_newtable(L)
        observerRefTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        luaL_newmetatable(L, axuielement_OBSERVER_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(axobserver_start)
        lua_setfield(L, -2, "start")
        L.push(axobserver_stop)
        lua_setfield(L, -2, "stop")
        L.push(axobserver_isRunning)
        lua_setfield(L, -2, "isRunning")
        L.push(axobserver_callback)
        lua_setfield(L, -2, "callback")
        L.push(axobserver_addWatchedElement)
        lua_setfield(L, -2, "addWatcher")
        L.push(axobserver_removeWatchedElement)
        lua_setfield(L, -2, "removeWatcher")
        L.push(axobserver_watchedElements)
        lua_setfield(L, -2, "watching")
        L.push(observer_userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(observer_userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(observer_userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        lua_createtable(L, 0, 1)
        L.push(axobserver_new)
        lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(observer_meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        if observerDetails == nil {
            observerDetails = NSMutableDictionary()
        }

        _ = try pushNotificationsTable(L); lua_setfield(L, -2, "notifications")
    }
}
