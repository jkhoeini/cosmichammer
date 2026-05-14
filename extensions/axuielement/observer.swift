/// === hs.axuielement.observer ===
///
/// This submodule allows you to create observers for accessibility elements and be notified when they trigger notifications. Not all notifications are supported by all elements and not all elements support notifications, so some trial and error will be necessary, but for compliant applications, this can allow your code to be notified when an application's user interface changes in some way.

import Cocoa
import LuaSkin

private var refTable: LSRefTable = LUA_NOREF

private var observerDetails: CFMutableDictionary!

private let keySelfRefCount = "selfRefCount" as CFString
private let keyCallbackRef  = "callbackRef" as CFString
private let keyIsRunning    = "isRunning" as CFString
private let keyWatching     = "watching" as CFString

// MARK: - Support Functions

@_cdecl("pushAXObserver")
@discardableResult
public func pushAXObserver(_ L: OpaquePointer!, _ observer: AXObserver) -> Int32 {
    var details = CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())
        .map { Unmanaged<CFMutableDictionary>.fromOpaque($0).takeUnretainedValue() }

    if details == nil {
        let newDetails = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)!
        CFDictionarySetValue(newDetails, Unmanaged.passUnretained(keySelfRefCount).toOpaque(), Unmanaged.passUnretained(NSNumber(value: 0)).toOpaque())
        CFDictionarySetValue(newDetails, Unmanaged.passUnretained(keyCallbackRef).toOpaque(), Unmanaged.passUnretained(NSNumber(value: LUA_NOREF)).toOpaque())
        CFDictionarySetValue(newDetails, Unmanaged.passUnretained(keyIsRunning).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
        let watching = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)!
        CFDictionarySetValue(newDetails, Unmanaged.passUnretained(keyWatching).toOpaque(), Unmanaged.passRetained(watching).toOpaque())

        CFDictionarySetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque(), Unmanaged.passRetained(newDetails).toOpaque())
        details = newDetails
    }

    let selfRefCount = (CFDictionaryGetValue(details, Unmanaged.passUnretained(keySelfRefCount).toOpaque())
        .map { Unmanaged<NSNumber>.fromOpaque($0).takeUnretainedValue().intValue } ?? 0) + 1
    CFDictionarySetValue(details, Unmanaged.passUnretained(keySelfRefCount).toOpaque(), Unmanaged.passUnretained(NSNumber(value: selfRefCount)).toOpaque())

    let thePtr = lua_newuserdata(L, MemoryLayout<AXObserver>.size)!
        .assumingMemoryBound(to: Unmanaged<AXObserver>.self)
    thePtr.pointee = Unmanaged.passRetained(observer)
    luaL_getmetatable(L, OBSERVER_TAG)
    lua_setmetatable(L, -2)
    return 1
}

// reduce duplication in meta_gc and userdata_gc

private func purgeWatchers(_ key: UnsafeRawPointer?, _ value: UnsafeRawPointer?, _ context: UnsafeMutableRawPointer?) {
    guard let key = key, let value = value, let context = context else { return }
    let element = Unmanaged<AXUIElement>.fromOpaque(key).takeUnretainedValue()
    let notifications = Unmanaged<CFMutableArray>.fromOpaque(value).takeUnretainedValue()
    let observer = Unmanaged<AXObserver>.fromOpaque(context).takeUnretainedValue()

    for i in 0..<CFArrayGetCount(notifications) {
        let what = Unmanaged<CFString>.fromOpaque(CFArrayGetValueAtIndex(notifications, i)!).takeUnretainedValue()
        AXObserverRemoveNotification(observer, element, what)
    }
    CFArrayRemoveAllValues(notifications)
    CFRelease(notifications)
}

private func cleanupAXObserver(_ observer: AXObserver, _ details: CFMutableDictionary) {
    let skin = LuaSkin.shared(withState: nil)!
    let L = skin.l

    var callbackRef = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyCallbackRef).toOpaque())
        .map { Unmanaged<NSNumber>.fromOpaque($0).takeUnretainedValue().int32Value } ?? Int32(LUA_NOREF)
    callbackRef = skin.luaUnref(refTable, ref: callbackRef)
    CFDictionarySetValue(details, Unmanaged.passUnretained(keyCallbackRef).toOpaque(), Unmanaged.passUnretained(NSNumber(value: callbackRef)).toOpaque())

    let isRunning = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque())
        .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    if isRunning {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        CFDictionarySetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
    }

    // clean up the `watching` dictionary and release it.
    if let watchingPtr = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyWatching).toOpaque()) {
        let watching = Unmanaged<CFMutableDictionary>.fromOpaque(watchingPtr).takeUnretainedValue()
        CFDictionaryApplyFunction(watching, purgeWatchers, UnsafeMutableRawPointer(Unmanaged.passUnretained(observer).toOpaque()))
        CFDictionaryRemoveAllValues(watching)
        CFDictionaryRemoveValue(details, Unmanaged.passUnretained(keyWatching).toOpaque())
        CFRelease(watching)
    }

    // release the details dictionary.
    CFDictionaryRemoveAllValues(details)
    CFRelease(details)
}

private let observerCallbackImpl: AXObserverCallbackWithInfo = { observer, element, notification, info, _ in
    let skin = LuaSkin.shared(withState: nil)!
    let L = skin.l!

    guard let detailsPtr = CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque()) else {
        skin.logWarn(String(format: "%s:callback triggered for unregistered observer", OBSERVER_TAG))
        return
    }

    let details = Unmanaged<CFMutableDictionary>.fromOpaque(detailsPtr).takeUnretainedValue()
    let callbackRef = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyCallbackRef).toOpaque())
        .map { Unmanaged<NSNumber>.fromOpaque($0).takeUnretainedValue().int32Value } ?? Int32(LUA_NOREF)

    if callbackRef != LUA_NOREF {
        skin.pushLuaRef(refTable, ref: callbackRef)
        pushAXObserver(L, observer)
        pushAXUIElement(L, element)
        skin.pushNSObject(notification as NSString)
        if let info = info {
            pushCFTypeToLua(L, info, refTable)
        } else {
            lua_newtable(L)
        }
        if !skin.protectedCallAndTraceback(4, nresults: 0) {
            skin.logError(String(format: "%s:callback error:%s", OBSERVER_TAG, lua_tostring(L, -1)!))
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions

/// hs.axuielement.observer.new(pid) -> observerObject
/// Constructor
/// Creates a new observer object for the application with the specified process ID.
///
/// Parameters:
///  * `pid` - the process ID of the application.
///
/// Returns:
///  * a new observerObject; generates an error if the pid does not exist or if the object cannot be created.
///
/// Notes:
///  * If you already have the `hs.application` object for an application, you can get its process ID with `hs.application:pid()`
///  * If you already have an `hs.axuielement` from the application you wish to observe (it doesn't have to be the application axuielement object, just one belonging to the application), you can get the process ID with `hs.axuielement:pid()`.
private func axobserver_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
    let appPid = pid_t(lua_tointeger(L, 1))
    var observer: AXObserver?
    let err = AXObserverCreateWithInfoCallback(appPid, observerCallbackImpl, &observer)

    if err != .success { return luaL_error(L, AXErrorAsString(err.rawValue)) }

    pushAXObserver(L, observer!)

    // release here because pushAXObserver is retaining as well.
    CFRelease(observer!)
    return 1
}

// MARK: - Module Methods

/// hs.axuielement.observer:start() -> observerObject
/// Method
/// Start observing the application and trigger callbacks for the elements and notifications assigned.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the observerObject
///
/// Notes:
///  * This method does nothing if the observer is already running
private func axobserver_start(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()

    let isRunning = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque())
        .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    if !isRunning {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        CFDictionarySetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:stop() -> observerObject
/// Method
/// Stop observing the application; no further callbacks will be generated.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the observerObject
///
/// Notes:
///  * This method does nothing if the observer is not currently running
private func axobserver_stop(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()

    let isRunning = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque())
        .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    if isRunning {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        CFDictionarySetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:isRunning() -> boolean
/// Method
/// Returns true or false indicating whether the observer is currently watching for notifications and generating callbacks.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not the observer is currently active.
private func axobserver_isRunning(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()

    let isRunning = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyIsRunning).toOpaque())
        .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    lua_pushboolean(L, isRunning ? 1 : 0)
    return 1
}

/// hs.axuielement.observer:callback([fn]) -> observerObject | fn | nil
/// Method
/// Get or set the callback for the observer.
///
/// Parameters:
///  * `fn` - a function, or an explicit nil to remove, specifying the callback function the observer will invoke when the assigned elements generate notifications.
///
/// Returns:
///  * If an argument is provided, the observerObject; otherwise the current value.
///
/// Notes:
///  * the callback should expect 4 arguments and return none. The arguments passed to the callback will be as follows:
///    * the observerObject itself
///    * the `hs.axuielement` object for the accessibility element which generated the notification
///    * a string specifying the specific notification which was received
///    * a table containing key-value pairs with more information about the notification, if the element and notification type provide it. Commonly this will be an empty table indicating that no additional detail was provided.
private func axobserver_callback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()

    var callbackRef = CFDictionaryGetValue(details, Unmanaged.passUnretained(keyCallbackRef).toOpaque())
        .map { Unmanaged<NSNumber>.fromOpaque($0).takeUnretainedValue().int32Value } ?? Int32(LUA_NOREF)

    if lua_gettop(L) == 2 {
        callbackRef = skin.luaUnref(refTable, ref: callbackRef)
        CFDictionarySetValue(details, Unmanaged.passUnretained(keyCallbackRef).toOpaque(), Unmanaged.passUnretained(NSNumber(value: callbackRef)).toOpaque())
        if lua_type(L, 2) != LUA_TNIL {
            lua_pushvalue(L, 2)
            callbackRef = skin.luaRef(refTable)
            CFDictionarySetValue(details, Unmanaged.passUnretained(keyCallbackRef).toOpaque(), Unmanaged.passUnretained(NSNumber(value: callbackRef)).toOpaque())
            lua_pushvalue(L, 1)
        }
    } else {
        if callbackRef != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: callbackRef)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.axuielement.observer:addWatcher(element, notification) -> observerObject
/// Method
/// Registers the specified notification for the specified accessibility element with the observer.
///
/// Parameters:
///  * `element`      - the `hs.axuielement` representing an accessibility element of the application the observer was created for.
///  * `notification` - a string specifying the notification.
///
/// Returns:
///  * the observerObject; generates an error if watcher cannot be registered
///
/// Notes:
///  * multiple notifications for the same accessibility element can be registered by invoking this method multiple times with the same element but different notification strings.
///  * if the specified element and notification string are already registered, this method does nothing.
///  * the notification string is application dependent and can be any string that the application developers choose; some common ones are found in `hs.axuielement.observer.notifications`, but the list is not exhaustive nor is an application or element required to provide them.
private func axobserver_addWatchedElement(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG,
                   LS_TUSERDATA, USERDATA_TAG,
                   LS_TSTRING,
                   LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()
    let element = get_axuielementref(L, 2, USERDATA_TAG)
    let what = skin.toNSObject(atIndex: 3) as! NSString

    let watching = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(details, Unmanaged.passUnretained(keyWatching).toOpaque())!
    ).takeUnretainedValue()

    var notifications: CFMutableArray?
    if let existingPtr = CFDictionaryGetValue(watching, Unmanaged.passUnretained(element).toOpaque()) {
        notifications = Unmanaged<CFMutableArray>.fromOpaque(existingPtr).takeUnretainedValue()
    }

    var exists = false
    if let notifications = notifications {
        exists = CFArrayContainsValue(notifications, CFRangeMake(0, CFArrayGetCount(notifications)), Unmanaged.passUnretained(what).toOpaque())
    } else {
        notifications = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks)
        CFDictionarySetValue(watching, Unmanaged.passUnretained(element).toOpaque(), Unmanaged.passRetained(notifications!).toOpaque())
    }
    if !exists {
        let err = AXObserverAddNotification(observer, element, what as CFString, nil)
        if err != .success { return luaL_error(L, AXErrorAsString(err.rawValue)) }
        CFArrayAppendValue(notifications!, Unmanaged.passUnretained(what).toOpaque())
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:removeWatcher(element, notification) -> observerObject
/// Method
/// Unregisters the specified notification for the specified accessibility element from the observer.
///
/// Parameters:
///  * `element`      - the `hs.axuielement` representing an accessibility element of the application the observer was created for.
///  * `notification` - a string specifying the notification.
///
/// Returns:
///  * the observerObject; generates an error if watcher cannot be unregistered
///
/// Notes:
///  * if the specified element and notification string are not currently registered with the observer, this method does nothing.
private func axobserver_removeWatchedElement(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG,
                   LS_TUSERDATA, USERDATA_TAG,
                   LS_TSTRING,
                   LS_TBREAK)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()
    let element = get_axuielementref(L, 2, USERDATA_TAG)
    let what = skin.toNSObject(atIndex: 3) as! NSString

    let watching = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(details, Unmanaged.passUnretained(keyWatching).toOpaque())!
    ).takeUnretainedValue()

    var existsIndex: CFIndex = -1
    if let notifPtr = CFDictionaryGetValue(watching, Unmanaged.passUnretained(element).toOpaque()) {
        let notifications = Unmanaged<CFMutableArray>.fromOpaque(notifPtr).takeUnretainedValue()
        existsIndex = CFArrayGetFirstIndexOfValue(notifications, CFRangeMake(0, CFArrayGetCount(notifications)), Unmanaged.passUnretained(what).toOpaque())

        if existsIndex > -1 {
            let err = AXObserverRemoveNotification(observer, element, what as CFString)
            CFArrayRemoveValueAtIndex(notifications, existsIndex)
            if err != .success { return luaL_error(L, AXErrorAsString(err.rawValue)) }
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.axuielement.observer:watching([element]) -> table
/// Method
/// Returns a table of the notifications currently registered with the observer.
///
/// Parameters:
///  * `element` - an optional `hs.axuielement` to return a list of registered notifications for.
///
/// Returns:
///  * a table containing the currently registered notifications
///
/// Notes:
///  * If an element is specified, then the table returned will contain a list of strings specifying the specific notifications that the observer is watching that element for.
///  * If no argument is specified, then the table will contain key-value pairs in which each key will be an `hs.axuielement` that is being observed and the corresponding value will be a table containing a list of strings specifying the specific notifications that the observer is watching for from that element.
private func axobserver_watchedElements(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TBREAK | LS_TVARARG)
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())!
    ).takeUnretainedValue()
    var element: AXUIElement?
    if lua_gettop(L) > 1 {
        skin.checkArgs(LS_TUSERDATA, OBSERVER_TAG, LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
        element = get_axuielementref(L, 2, USERDATA_TAG)
    }

    let watching = Unmanaged<CFMutableDictionary>.fromOpaque(
        CFDictionaryGetValue(details, Unmanaged.passUnretained(keyWatching).toOpaque())!
    ).takeUnretainedValue()

    if let element = element {
        if let notifPtr = CFDictionaryGetValue(watching, Unmanaged.passUnretained(element).toOpaque()) {
            let notifications = Unmanaged<CFMutableArray>.fromOpaque(notifPtr).takeUnretainedValue()
            pushCFTypeToLua(L, notifications, refTable)
        } else {
            lua_newtable(L)
        }
    } else {
        pushCFTypeToLua(L, watching, refTable)
    }
    return 1
}

// MARK: - Module Constants

/// hs.axuielement.observer.notifications[]
/// Constant
/// A table of common accessibility object notification names, provided for reference.
///
/// Notes:
///  * Notifications are application dependent and can be any string that the application developers choose; this list provides the suggested notification names found within the macOS Framework headers, but the list is not exhaustive nor is an application or element required to provide them.
private func pushNotificationsTable(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    lua_newtable(L)
    // Focus notifications
    skin.pushNSObject(NSAccessibility.Notification.mainWindowChanged.rawValue as NSString);       lua_setfield(L, -2, "mainWindowChanged")
    skin.pushNSObject(NSAccessibility.Notification.focusedWindowChanged.rawValue as NSString);    lua_setfield(L, -2, "focusedWindowChanged")
    skin.pushNSObject(NSAccessibility.Notification.focusedUIElementChanged.rawValue as NSString); lua_setfield(L, -2, "focusedUIElementChanged")
    // Application notifications
    skin.pushNSObject(NSAccessibility.Notification.applicationActivated.rawValue as NSString);    lua_setfield(L, -2, "applicationActivated")
    skin.pushNSObject(NSAccessibility.Notification.applicationDeactivated.rawValue as NSString);  lua_setfield(L, -2, "applicationDeactivated")
    skin.pushNSObject(NSAccessibility.Notification.applicationHidden.rawValue as NSString);       lua_setfield(L, -2, "applicationHidden")
    skin.pushNSObject(NSAccessibility.Notification.applicationShown.rawValue as NSString);        lua_setfield(L, -2, "applicationShown")
    // Window notifications
    skin.pushNSObject(NSAccessibility.Notification.windowCreated.rawValue as NSString);           lua_setfield(L, -2, "windowCreated")
    skin.pushNSObject(NSAccessibility.Notification.windowMoved.rawValue as NSString);             lua_setfield(L, -2, "windowMoved")
    skin.pushNSObject(NSAccessibility.Notification.windowResized.rawValue as NSString);           lua_setfield(L, -2, "windowResized")
    skin.pushNSObject(NSAccessibility.Notification.windowMiniaturized.rawValue as NSString);      lua_setfield(L, -2, "windowMiniaturized")
    skin.pushNSObject(NSAccessibility.Notification.windowDeminiaturized.rawValue as NSString);    lua_setfield(L, -2, "windowDeminiaturized")
    // New drawer, sheet, and help tag notifications
    skin.pushNSObject(NSAccessibility.Notification.drawerCreated.rawValue as NSString);           lua_setfield(L, -2, "drawerCreated")
    skin.pushNSObject(NSAccessibility.Notification.sheetCreated.rawValue as NSString);            lua_setfield(L, -2, "sheetCreated")
    skin.pushNSObject(NSAccessibility.Notification.helpTagCreated.rawValue as NSString);          lua_setfield(L, -2, "helpTagCreated")
    // Element notifications
    skin.pushNSObject(NSAccessibility.Notification.valueChanged.rawValue as NSString);            lua_setfield(L, -2, "valueChanged")
    skin.pushNSObject(NSAccessibility.Notification.uiElementDestroyed.rawValue as NSString);      lua_setfield(L, -2, "uIElementDestroyed")
    skin.pushNSObject(NSAccessibility.Notification.elementBusyChanged.rawValue as NSString);      lua_setfield(L, -2, "elementBusyChanged")
    // Menu notifications
    skin.pushNSObject(NSAccessibility.Notification.menuOpened.rawValue as NSString);              lua_setfield(L, -2, "menuOpened")
    skin.pushNSObject(NSAccessibility.Notification.menuClosed.rawValue as NSString);              lua_setfield(L, -2, "menuClosed")
    skin.pushNSObject(NSAccessibility.Notification.menuItemSelected.rawValue as NSString);        lua_setfield(L, -2, "menuItemSelected")
    // Table and outline view notifications
    skin.pushNSObject(NSAccessibility.Notification.rowCountChanged.rawValue as NSString);         lua_setfield(L, -2, "rowCountChanged")
    skin.pushNSObject(NSAccessibility.Notification.rowCollapsed.rawValue as NSString);            lua_setfield(L, -2, "rowCollapsed")
    skin.pushNSObject(NSAccessibility.Notification.rowExpanded.rawValue as NSString);             lua_setfield(L, -2, "rowExpanded")
    // Miscellaneous notifications
    skin.pushNSObject(NSAccessibility.Notification.selectedChildrenChanged.rawValue as NSString); lua_setfield(L, -2, "selectedChildrenChanged")
    skin.pushNSObject(NSAccessibility.Notification.resized.rawValue as NSString);                 lua_setfield(L, -2, "resized")
    skin.pushNSObject(NSAccessibility.Notification.moved.rawValue as NSString);                   lua_setfield(L, -2, "moved")
    skin.pushNSObject(NSAccessibility.Notification.created.rawValue as NSString);                 lua_setfield(L, -2, "created")
    skin.pushNSObject(NSAccessibility.Notification.announcementRequested.rawValue as NSString);   lua_setfield(L, -2, "announcementRequested")
    skin.pushNSObject(NSAccessibility.Notification.layoutChanged.rawValue as NSString);           lua_setfield(L, -2, "layoutChanged")
    skin.pushNSObject(NSAccessibility.Notification.selectedCellsChanged.rawValue as NSString);    lua_setfield(L, -2, "selectedCellsChanged")
    skin.pushNSObject(NSAccessibility.Notification.selectedChildrenMoved.rawValue as NSString);   lua_setfield(L, -2, "selectedChildrenMoved")
    skin.pushNSObject(NSAccessibility.Notification.selectedColumnsChanged.rawValue as NSString);  lua_setfield(L, -2, "selectedColumnsChanged")
    skin.pushNSObject(NSAccessibility.Notification.selectedRowsChanged.rawValue as NSString);     lua_setfield(L, -2, "selectedRowsChanged")
    skin.pushNSObject(NSAccessibility.Notification.selectedTextChanged.rawValue as NSString);     lua_setfield(L, -2, "selectedTextChanged")
    skin.pushNSObject(NSAccessibility.Notification.titleChanged.rawValue as NSString);            lua_setfield(L, -2, "titleChanged")
    skin.pushNSObject(NSAccessibility.Notification.unitsChanged.rawValue as NSString);            lua_setfield(L, -2, "unitsChanged")

    return 1
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.pushNSObject(NSString(format: "%s: (%p)", OBSERVER_TAG, lua_topointer(L, 1)))
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let observer = get_axobserverref(L, 1, OBSERVER_TAG)

    guard let detailsPtr = CFDictionaryGetValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque()) else {
        skin.logWarn(String(format: "%s:__gc triggered for unregistered observer", OBSERVER_TAG))
        lua_pushnil(L)
        lua_setmetatable(L, 1)
        return 0
    }

    let details = Unmanaged<CFMutableDictionary>.fromOpaque(detailsPtr).takeUnretainedValue()
    var selfRefCount = CFDictionaryGetValue(details, Unmanaged.passUnretained(keySelfRefCount).toOpaque())
        .map { Unmanaged<NSNumber>.fromOpaque($0).takeUnretainedValue().intValue } ?? 0
    selfRefCount -= 1
    CFDictionarySetValue(details, Unmanaged.passUnretained(keySelfRefCount).toOpaque(), Unmanaged.passUnretained(NSNumber(value: selfRefCount)).toOpaque())
    if selfRefCount == 0 {
        cleanupAXObserver(observer, details)
        CFDictionaryRemoveValue(observerDetails, Unmanaged.passUnretained(observer).toOpaque())
        CFRelease(observer)
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    let observer1 = get_axobserverref(L, 1, OBSERVER_TAG)
    let observer2 = get_axobserverref(L, 2, OBSERVER_TAG)
    lua_pushboolean(L, CFEqual(observer1, observer2) ? 1 : 0)
    return 1
}

private func purgeObserver(_ key: UnsafeRawPointer?, _ value: UnsafeRawPointer?, _ context: UnsafeMutableRawPointer?) {
    guard let key = key, let value = value else { return }
    let observer = Unmanaged<AXObserver>.fromOpaque(key).takeUnretainedValue()
    let details = Unmanaged<CFMutableDictionary>.fromOpaque(value).takeUnretainedValue()
    cleanupAXObserver(observer, details)
    CFRelease(observer)
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    if observerDetails != nil {
        CFDictionaryApplyFunction(observerDetails, purgeObserver, nil)
        CFDictionaryRemoveAllValues(observerDetails)
        CFRelease(observerDetails)
        observerDetails = nil
    }
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),         func: axobserver_start),
    luaL_Reg(name: strdup("stop"),          func: axobserver_stop),
    luaL_Reg(name: strdup("isRunning"),     func: axobserver_isRunning),
    luaL_Reg(name: strdup("callback"),      func: axobserver_callback),
    luaL_Reg(name: strdup("addWatcher"),    func: axobserver_addWatchedElement),
    luaL_Reg(name: strdup("removeWatcher"), func: axobserver_removeWatchedElement),
    luaL_Reg(name: strdup("watching"),      func: axobserver_watchedElements),

    luaL_Reg(name: strdup("__tostring"),    func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),          func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),          func: userdata_gc),
    luaL_Reg(name: nil,                     func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: axobserver_new),
    luaL_Reg(name: nil,           func: nil),
]

// Metatable for module, if needed
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

@_cdecl("luaopen_hs_libaxuielementobserver")
public func luaopen_hs_libaxuielementobserver(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary(withObject: OBSERVER_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    observerDetails = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)

    pushNotificationsTable(L); lua_setfield(L, -2, "notifications")

    return 1
}
