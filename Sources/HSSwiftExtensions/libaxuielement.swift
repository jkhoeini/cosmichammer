import Cocoa
import LuaSkin

private let USERDATA_TAG = axuielement_USERDATA_TAG
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions

@_cdecl("pushAXUIElement")
@discardableResult
public func pushAXUIElement(_ L: UnsafeMutablePointer<lua_State>!, _ theElement: AXUIElement) -> Int32 {
    let thePtr = lua_newuserdata(L, MemoryLayout<AXUIElement>.size)!
        .assumingMemoryBound(to: Unmanaged<AXUIElement>.self)
    thePtr.pointee = Unmanaged.passRetained(theElement)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

@_cdecl("AXErrorAsString")
public func AXErrorAsString(_ theError: AXError) -> UnsafePointer<CChar> {
    let ans: StaticString
    switch theError {
    case .success:                           ans = "No error occurred"
    case .failure:                           ans = "A system error occurred"
    case .illegalArgument:                   ans = "Illegal argument"
    case .invalidUIElement:                  ans = "AXUIElementRef is invalid"
    case .invalidUIElementObserver:          ans = "Not a valid observer"
    case .cannotComplete:                    ans = "Messaging failed"
    case .attributeUnsupported:             ans = "Attribute is not supported by target"
    case .actionUnsupported:                ans = "Action is not supported by target"
    case .notificationUnsupported:          ans = "Notification is not supported by target"
    case .notImplemented:                   ans = "Function or method not implemented"
    case .notificationAlreadyRegistered:    ans = "Notification has already been registered"
    case .notificationNotRegistered:        ans = "Notification is not registered yet"
    case .apiDisabled:                      ans = "The accessibility API is disabled"
    case .noValue:                          ans = "Requested value does not exist"
    case .parameterizedAttributeUnsupported: ans = "Parameterized attribute is not supported"
    case .notEnoughPrecision:               ans = "Not enough precision"
    default:                                ans = "Unrecognized error occurred"
    }
    return UnsafeRawPointer(ans.utf8Start).assumingMemoryBound(to: CChar.self)
}

private func isApplicationOrSystem(_ theRef: AXUIElement) -> Bool {
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    let result = (errorState == .success) &&
        (value != nil) &&
        (CFGetTypeID(value!) == CFStringGetTypeID()) &&
        ((value as! String) == (kAXApplicationRole as String) || (value as! String) == (kAXSystemWideRole as String))
    return result
}

private func errorWrapper(_ L: UnsafeMutablePointer<lua_State>!, _ where_: NSString, _ what: NSString?, _ err: AXError) -> Int32 {
    let axErrMsg = AXErrorAsString(err)
    let skin = LuaSkin.skin(with: L)

    if let what = what {
        skin.logVerbose(String(format: "%s:%@ AXError %d for %@: %s", USERDATA_TAG, where_, err.rawValue, what, String(cString: axErrMsg)))
    } else {
        skin.logVerbose(String(format: "%s:%@ AXError %d: %s", USERDATA_TAG, where_, err.rawValue, String(cString: axErrMsg)))
    }

    lua_pushnil(L)
    lua_pushstring(L, axErrMsg)
    return 2
}

// MARK: - Module Functions

/// hs.axuielement.windowElement(windowObject) -> axuielementObject
/// Constructor
/// Returns the accessibility object for the window specified by the `hs.window` object.
///
/// Parameters:
///  * `windowObject` - the `hs.window` object for the window or a string or number which will be passed to `hs.window.find` to get an `hs.window` object.
///
/// Returns:
///  * an axuielementObject for the window specified
///
/// Notes:
///  * if `windowObject` is a string or number, only the first item found with `hs.window.find` will be used by this function to create an axuielementObject.
private func axuielement_getWindowElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    // vararg here to mimic original behavior and allow constructs to use `hs.window(...)` as arg as this may
    // return more than one result
    skin.checkArgs(LS_TUSERDATA, "hs.window", LS_TBREAK | LS_TVARARG)
    let object = skin.toNSObject(atIndex: 1) as! NSObject
    if let ref = getElementRefPropertyFromClassObject(object) {
        pushAXUIElement(L, ref)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.axuielement.applicationElement(applicationObject) -> axuielementObject
/// Constructor
/// Returns the top-level accessibility object for the application specified by the `hs.application` object.
///
/// Parameters:
///  * `applicationObject` - the `hs.application` object for the Application or a string or number which will be passed to `hs.application.find` to get an `hs.application` object.
///
/// Returns:
///  * an axuielementObject for the application specified
///
/// Notes:
///  * if `applicationObject` is a string or number, only the first item found with `hs.application.find` will be used by this function to create an axuielementObject.
private func axuielement_getApplicationElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    // vararg here to mimic original behavior and allow constructs to use `hs.application(...)` as arg as this may
    // return more than one result
    skin.checkArgs(LS_TUSERDATA, "hs.application", LS_TBREAK | LS_TVARARG)
    let object = skin.toNSObject(atIndex: 1) as! NSObject
    if let ref = getElementRefPropertyFromClassObject(object) {
        pushAXUIElement(L, ref)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.axuielement.systemWideElement() -> axuielementObject
/// Constructor
/// Returns an accessibility object that provides access to system attributes.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the axuielementObject for the system attributes
private func axuielement_getSystemWideElement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    let value = AXUIElementCreateSystemWide()
    pushAXUIElement(L, value)
    return 1
}

/// hs.axuielement.applicationElementForPID(pid) -> axuielementObject
/// Constructor
/// Returns the top-level accessibility object for the application with the specified process ID.
///
/// Parameters:
///  * `pid` - the process ID of the application.
///
/// Returns:
///  * an axuielementObject for the application specified, or nil if it cannot be determined
private func axuielement_getApplicationElementForPID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TNUMBER, LS_TBREAK)
    let thePid = pid_t(luaL_checkinteger(L, 1))
    let value = AXUIElementCreateApplication(thePid)
    if isApplicationOrSystem(value) {
        pushAXUIElement(L, value)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Module Methods

/// hs.axuielement:copy() -> axuielementObject
/// Method
/// Return a duplicate userdata reference to the Accessibility object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a new userdata object representing a new reference to the Accessibility object.
private func axuielement_duplicateReference(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    pushAXUIElement(L, theRef)
    return 1
}

/// hs.axuielement:attributeNames() -> table | nil, errString
/// Method
/// Returns a list of all the attributes supported by the specified accessibility object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array of the names of all attributes supported by the axuielementObject or nil and an error string if an accessibility error occurred
///
/// Notes:
///  * Common attribute names can be found in the [hs.axuielement.attributes](#attributes) tables; however, this method will list only those names which are supported by this object, and is not limited to just those in the referenced table.
private func axuielement_getAttributeNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var attributeNames: CFArray?
    let errorState = AXUIElementCopyAttributeNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_newtable(L)
        for value in attributeNames! as [AnyObject] {
            skin.pushNSObject(value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        errorWrapper(L, "attributeNames", nil, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:actionNames() -> table | nil, errString
/// Method
/// Returns a list of all the actions the specified accessibility object can perform.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array of the names of all actions supported by the axuielementObject or nil and an error string if an accessibility error occurred
///
/// Notes:
///  * Common action names can be found in the [hs.axuielement.actions](#actions) table; however, this method will list only those names which are supported by this object, and is not limited to just those in the referenced table.
private func axuielement_getActionNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var attributeNames: CFArray?
    let errorState = AXUIElementCopyActionNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_newtable(L)
        for value in attributeNames! as [AnyObject] {
            skin.pushNSObject(value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        errorWrapper(L, "actionNames", nil, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:actionDescription(action) -> string | nil, errString
/// Method
/// Returns a localized description of the specified accessibility object's action.
///
/// Parameters:
///  * `action` - the name of the action, as specified by [hs.axuielement:actionNames](#actionNames).
///
/// Returns:
///  * a string containing a description of the object's action, nil if no description is available, or nil and an error string if an accessibility error occurred
///
/// Notes:
///  * The action descriptions are provided by the target application; as such their accuracy and usefulness rely on the target application's developers.
private func axuielement_getActionDescription(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let action = skin.toNSObject(atIndex: 2) as! NSString
    var description: CFString?
    let errorState = AXUIElementCopyActionDescription(theRef, action as CFString, &description)
    var returnCount: Int32 = 1
    if errorState == .success {
        skin.pushNSObject(description! as NSString)
    } else if errorState == .noValue {
        lua_pushnil(L)
    } else {
        errorWrapper(L, "actionDescription", action, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:attributeValue(attribute) -> value | nil, errString
/// Method
/// Returns the value of an accessibility object's attribute.
///
/// Parameters:
///  * `attribute` - the name of the attribute, as specified by [hs.axuielement:attributeNames](#attributeNames).
///
/// Returns:
///  * the current value of the attribute, nil if the attribute has no value, or nil and an error string if an accessibility error occurred
private func axuielement_getAttributeValue(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = skin.toNSObject(atIndex: 2) as! NSString
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, attribute as CFString, &value)
    var returnCount: Int32 = 1
    if errorState == .success {
        pushCFTypeToLua(L, value, refTable)
    } else if errorState == .noValue {
        lua_pushnil(L)
    } else {
        errorWrapper(L, "attributeValue", attribute, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:allAttributeValues([includeErrors]) -> table | nil, errString
/// Method
/// Returns a table containing key-value pairs for all attributes of the accessibility object.
///
/// Parameters:
///  * `includeErrors` - an optional boolean, default false, that specifies whether attribute names which generate an error when retrieved are included in the returned results.
///
/// Returns:
///  * a table with key-value pairs corresponding to the attributes of the accessibility object or nil and an error string if an accessibility error occurred
///
/// Notes:
///  * if `includeErrors` is not specified or is false, then attributes which exist for the element, but currently have no value assigned, will not appear in the table. This is because Lua treats a nil value for a table's key-value pair as an instruction to remove the key from the table, if it currently exists.
///  * To include attributes which exist but are currently unset, you need to specify `includeErrors` as true.
///    * attributes for which no value is currently assigned will be given a table value with the following key-value pairs:
///      * `_code` = -25212
///      * `error` = "Requested value does not exist"
private func axuielement_getAllAttributeValues(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let includeErrors = lua_gettop(L) == 2 ? (lua_toboolean(L, 2) != 0) : false
    var attributeNames: CFArray?
    var errorState = AXUIElementCopyAttributeNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        var values: CFArray?
        errorState = AXUIElementCopyMultipleAttributeValues(theRef, attributeNames!, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if errorState == .success {
            lua_newtable(L)
            for idx in 0..<CFArrayGetCount(attributeNames!) {
                let item = CFArrayGetValueAtIndex(values!, idx)!
                let itemRef = Unmanaged<CFTypeRef>.fromOpaque(item).takeUnretainedValue()
                if CFGetTypeID(itemRef) == AXValueGetTypeID() && AXValueGetType(itemRef as! AXValue) == .axError {
                    if !includeErrors { continue }
                }
                pushCFTypeToLua(L, itemRef, refTable)
                let namePtr = CFArrayGetValueAtIndex(attributeNames!, idx)!
                let name = Unmanaged<NSString>.fromOpaque(namePtr).takeUnretainedValue()
                lua_setfield(L, -2, name.utf8String)
            }
        } else {
            errorWrapper(L, "allAttributeValues", "retrieving attribute values", errorState)
            returnCount += 1
        }
    } else {
        errorWrapper(L, "allAttributeValues", "retrieving attribute names", errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:attributeValueCount(attribute) -> integer | nil, errString
/// Method
/// Returns the count of the array of an accessibility object's attribute value.
///
/// Parameters:
///  * `attribute` - the name of the attribute, as specified by [hs.axuielement:attributeNames](#attributeNames).
///
/// Returns:
///  * the number of items in the value for the attribute, if it is an array, or nil and an error string if an accessibility error occurred
private func axuielement_getAttributeValueCount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = skin.toNSObject(atIndex: 2) as! NSString
    var count: CFIndex = 0
    let errorState = AXUIElementGetAttributeValueCount(theRef, attribute as CFString, &count)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushinteger(L, lua_Integer(count))
    } else {
        errorWrapper(L, "attributeValueCount", attribute, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:parameterizedAttributeNames() -> table | nil, errString
/// Method
/// Returns a list of all the parameterized attributes supported by the specified accessibility object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array of the names of all parameterized attributes supported by the axuielementObject or nil and an error string if an accessibility error occurred
private func axuielement_getParameterizedAttributeNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var attributeNames: CFArray?
    let errorState = AXUIElementCopyParameterizedAttributeNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_newtable(L)
        for value in attributeNames! as [AnyObject] {
            skin.pushNSObject(value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        errorWrapper(L, "parameterizedAttributeNames", nil, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:isAttributeSettable(attribute) -> boolean | nil, errString
/// Method
/// Returns whether the specified accessibility object's attribute can be modified.
///
/// Parameters:
///  * `attribute` - the name of the attribute, as specified by [hs.axuielement:attributeNames](#attributeNames).
///
/// Returns:
///  * a boolean value indicating whether or not the value of the parameter can be modified or nil and an error string if an accessibility error occurred
private func axuielement_isAttributeSettable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = skin.toNSObject(atIndex: 2) as! NSString
    var settable: DarwinBoolean = false
    let errorState = AXUIElementIsAttributeSettable(theRef, attribute as CFString, &settable)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushboolean(L, settable.boolValue ? 1 : 0)
    } else {
        errorWrapper(L, "isAttributeSettable", attribute, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:isValid() -> boolean | nil, errString
/// Method
/// Returns whether the specified accessibility object is still valid.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not the accessibility object is still valid or nil and an error string if any other accessibility error occurred
///
/// Notes:
///  * an accessibilityObject can become invalid for a variety of reasons, including but not limited to the element referred to no longer being available (e.g. an element referring to a window or one of its descendants that has been closed) or the application terminating.
private func axuielement_isValid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushboolean(L, 1)
    } else if errorState == .invalidUIElement {
        lua_pushboolean(L, 0)
    } else {
        errorWrapper(L, "pid", nil, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:pid() -> integer | nil, errString
/// Method
/// Returns the process ID associated with the specified accessibility object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the process ID for the application to which the accessibility object ultimately belongs or nil and an error string if an accessibility error occurred
private func axuielement_getPid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var thePid: pid_t = 0
    let errorState = AXUIElementGetPid(theRef, &thePid)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushinteger(L, lua_Integer(thePid))
    } else {
        errorWrapper(L, "pid", nil, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:performAction(action) -> axuielement | false | nil, errString
/// Method
/// Requests that the specified accessibility object perform the specified action.
///
/// Parameters:
///  * `action` - the name of the action, as specified by [hs.axuielement:actionNames](#actionNames).
///
/// Returns:
///  * if the requested action was accepted by the target, returns the axuielementObject; if the requested action was rejected, returns false; otherwise returns nil and an error string if an accessibility error occurred
///
/// Notes:
///  * The return value only suggests success or failure, but is not a guarantee.  The receiving application may have internal logic which prevents the action from occurring at this time for some reason, even though this method returns success (the axuielementObject).  Contrawise, the requested action may trigger a requirement for a response from the user and thus appear to time out, causing this method to return false or nil.
private func axuielement_performAction(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let action = skin.toNSObject(atIndex: 2) as! NSString
    let errorState = AXUIElementPerformAction(theRef, action as CFString)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushvalue(L, 1)
    } else if errorState == .cannotComplete {
        lua_pushboolean(L, 0)
    } else {
        errorWrapper(L, "performAction", action, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:elementAtPosition(x, y | pointTable) -> axuielementObject | nil, errString
/// Method
/// Returns the accessibility object at the specified position on the screen. The top-left corner of the primary screen is 0, 0.
///
/// Parameters:
///  * `x` - the x coordinate of the screen location to test. If this parameter is provided, then the `y` parameter must also be provided and the `pointTable` parameter must not be provided.
///  * `y` - the y coordinate of the screen location to test. This parameter is required if the `x` parameter is provided.
///  * `pointTable` - the x and y coordinates of the screen location to test provided as a point-table, like the one returned by `hs.mouse.getAbsolutePosition` (a point-table is a table with key-value pairs for keys `x` and `y`). If this parameter is provided, then separate `x` and `y` parameters must not also be present.
///
/// Returns:
///  * an axuielementObject for the object at the specified coordinates, or nil and an error string if no object could be identified or an accessibility error occurred
///
/// Notes:
///  * This method can only be called on an axuielementObject that represents an application or the system-wide element (see [hs.axuielement.systemWideElement](#systemWideElement)).
///  * This function does hit-testing based on window z-order (that is, layering). If one window is on top of another window, the returned accessibility object comes from whichever window is topmost at the specified location.
///  * If this method is called on an axuielementObject representing an application, the search is restricted to the application.
///  * If this method is called on an axuielementObject representing the system-wide element, the search is not restricted to any particular application.  See [hs.axuielement.systemElementAtPosition](#systemElementAtPosition).
private func axuielement_getElementAtPosition(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TTABLE, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var returnCount: Int32 = 1
    if isApplicationOrSystem(theRef) {
        var x: Float
        var y: Float
        if lua_type(L, 2) == LUA_TTABLE && lua_gettop(L) == 2 {
            let thePoint = skin.tableToPoint(at: 2)
            x = Float(thePoint.x)
            y = Float(thePoint.y)
        } else if lua_gettop(L) == 3 {
            x = Float(lua_tonumber(L, 2))
            y = Float(lua_tonumber(L, 3))
        } else {
            return luaL_error(L, "point table or x and y as numbers expected")
        }
        var value: AXUIElement?
        let errorState = AXUIElementCopyElementAtPosition(theRef, x, y, &value)
        if errorState == .success {
            pushAXUIElement(L, value!)
        } else {
            errorWrapper(L, "elementAtPosition", nil, errorState)
            returnCount += 1
        }
    } else {
        return luaL_error(L, "must be application or systemWide element")
    }
    return returnCount
}

/// hs.axuielement:parameterizedAttributeValue(attribute, parameter) -> value | nil, errString
/// Method
/// Returns the value of an accessibility object's parameterized attribute.
///
/// Parameters:
///  * `attribute` - the name of the attribute, as specified by [hs.axuielement:parameterizedAttributeNames](#parameterizedAttributeNames).
///  * `parameter` - the parameter required by the parameterized attribute.
///
/// Returns:
///  * the current value of the parameterized attribute, nil if the parameterized attribute has no value, or nil and an error string if an accessibility error occurred
///
/// Notes:
///  * The specific parameter required for a each parameterized attribute is different and is often application specific thus requiring some experimentation. Notes regarding identified parameter types and thoughts on some still being investigated will be provided in the Cosmic Hammer Wiki, hopefully shortly after this module becomes part of a Cosmic Hammer release.
private func axuielement_getParameterizedAttributeValue(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TANY, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = skin.toNSObject(atIndex: 2) as! NSString
    let parameter = lua_toCFType(L, 3)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyParameterizedAttributeValue(theRef, attribute as CFString, parameter, &value)
    var returnCount: Int32 = 1
    if errorState == .success {
        pushCFTypeToLua(L, value, refTable)
    } else if errorState == .noValue {
        lua_pushnil(L)
    } else {
        errorWrapper(L, "parameterizedAttributeValue", attribute, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:setAttributeValue(attribute, value) -> axuielementObject  | nil, errString
/// Method
/// Sets the accessibility object's attribute to the specified value.
///
/// Parameters:
///  * `attribute` - the name of the attribute, as specified by [hs.axuielement:attributeNames](#attributeNames).
///  * `value`     - the value to assign to the attribute
///
/// Returns:
///  * the axuielementObject on success; nil and an error string if the attribute could not be set or an accessibility error occurred.
private func axuielement_setAttributeValue(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TANY, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = skin.toNSObject(atIndex: 2) as! NSString
    let value = lua_toCFType(L, 3)
    let errorState = AXUIElementSetAttributeValue(theRef, attribute as CFString, value)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushvalue(L, 1)
    } else {
        errorWrapper(L, "setAttributeValue", attribute, errorState)
        returnCount += 1
    }
    return returnCount
}

/// hs.axuielement:asHSApplication() -> hs.application object | nil
/// Method
/// If the element refers to an application, return an `hs.application` object for the element.
///
/// Parameters:
///  * None
///
/// Returns:
///  * if the element refers to an application, return an `hs.application` object for the element ; otherwise return nil
///
/// Notes:
///  * An element is considered an application by this method if it has an AXRole of AXApplication and has a process identifier (pid).
private func axuielement_toHSApplication(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    if errorState == .success,
       let value = value,
       CFGetTypeID(value) == CFStringGetTypeID(),
       (value as! String) == (kAXApplicationRole as String) {
        var thePid: pid_t = 0
        let errorState2 = AXUIElementGetPid(theRef, &thePid)
        if errorState2 == .success {
            new_application(L, thePid)
        } else {
            lua_pushnil(L)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.axuielement:asHSWindow() -> hs.window object | nil
/// Method
/// If the element refers to a window, return an `hs.window` object for the element.
///
/// Parameters:
///  * None
///
/// Returns:
///  * if the element refers to a window, return an `hs.window` object for the element ; otherwise return nil
///
/// Notes:
///  * An element is considered a window by this method if it has an AXRole of AXWindow.
private func axuielement_toHSWindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    if errorState == .success,
       let value = value,
       CFGetTypeID(value) == CFStringGetTypeID(),
       (value as! String) == (kAXWindowRole as String) {
        new_window(L, theRef)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.axuielement:setTimeout(value) -> axuielementObject | nil, errString
/// Method
/// Sets the timeout value used accessibility queries performed from this element.
///
/// Parameters:
///  * `value` - the number of seconds for the new timeout value. Must be 0 or positive.
///
/// Returns:
///  * the axuielementObject or nil and an error string if an accessibility error occurred
///
/// Notes:
///  * To change the global timeout affecting all queries on elements which do not have a specific timeout set, use this method on the systemwide element (see [hs.axuielement.systemWideElement](#systemWideElement).
///  * Changing the timeout value for an axuielement object only changes the value for that specific element -- other axuieleement objects that may refer to the identical accessibility item are not affected.
///  * Setting the value to 0.0 resets the timeout -- if applied to the `systemWideElement`, the global default will be reset to its default value; if applied to another axuielement object, the timeout will be reset to the current global value as applied to the systemWideElement.
private func axuielement_setTimeout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var returnCount: Int32 = 1
    var timeout = Float(lua_tonumber(L, 2))
    if timeout < 0 { timeout = 0 }
    let errorState = AXUIElementSetMessagingTimeout(theRef, timeout)
    if errorState == .success {
        lua_pushvalue(L, 1)
    } else {
        errorWrapper(L, "setTimeout", nil, errorState)
        returnCount += 1
    }
    return returnCount
}

// MARK: - Module Constants

/// hs.axuielement.attributes[]
/// Constant
/// A table of common accessibility object attribute names which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as keys in the match criteria argument.
///
/// Notes:
///  * This table is provided for reference only and is not intended to be comprehensive.
///  * You can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.attributes`
private func axuielement_pushAttributesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(NSAccessibility.Attribute.activationPoint.rawValue as NSString);                     lua_setfield(L, -2, "activationPoint")
    skin.pushNSObject(kAXAllowedValuesAttribute as NSString);              lua_setfield(L, -2, "allowedValues")
    skin.pushNSObject(kAXAlternateUIVisibleAttribute as NSString);         lua_setfield(L, -2, "alternateUIVisible")
    skin.pushNSObject(kAXAMPMFieldAttribute as NSString);                  lua_setfield(L, -2, "AMPMField")
    skin.pushNSObject(kAXAttachmentTextAttribute.takeUnretainedValue() as String as NSString);             lua_setfield(L, -2, "attachment")
    skin.pushNSObject(kAXAutocorrectedTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "autocorrected")
    skin.pushNSObject(kAXBackgroundColorTextAttribute.takeUnretainedValue() as String as NSString);        lua_setfield(L, -2, "backgroundColor")
    skin.pushNSObject(kAXCancelButtonAttribute as NSString);               lua_setfield(L, -2, "cancelButton")
    skin.pushNSObject(kAXChildrenAttribute as NSString);                   lua_setfield(L, -2, "children")
    skin.pushNSObject(kAXClearButtonAttribute as NSString);                lua_setfield(L, -2, "clearButton")
    skin.pushNSObject(kAXCloseButtonAttribute as NSString);                lua_setfield(L, -2, "closeButton")
    skin.pushNSObject(kAXColumnCountAttribute as NSString);                lua_setfield(L, -2, "columnCount")
    skin.pushNSObject(kAXColumnHeaderUIElementsAttribute as NSString);     lua_setfield(L, -2, "columnHeaderUIElements")
    skin.pushNSObject(kAXColumnIndexRangeAttribute as NSString);           lua_setfield(L, -2, "columnIndexRange")
    skin.pushNSObject(kAXColumnsAttribute as NSString);                    lua_setfield(L, -2, "columns")
    skin.pushNSObject(kAXColumnTitlesAttribute as NSString);               lua_setfield(L, -2, "columnTitles")
    skin.pushNSObject(NSAccessibility.Attribute.containsProtectedContent.rawValue as NSString);            lua_setfield(L, -2, "containsProtectedContent")
    skin.pushNSObject(kAXContentsAttribute as NSString);                   lua_setfield(L, -2, "contents")
    skin.pushNSObject(kAXCriticalValueAttribute as NSString);              lua_setfield(L, -2, "criticalValue")
    skin.pushNSObject(kAXDayFieldAttribute as NSString);                   lua_setfield(L, -2, "dayField")
    skin.pushNSObject(kAXDecrementButtonAttribute as NSString);            lua_setfield(L, -2, "decrementButton")
    skin.pushNSObject(kAXDefaultButtonAttribute as NSString);              lua_setfield(L, -2, "defaultButton")
    skin.pushNSObject(kAXDescriptionAttribute as NSString);                lua_setfield(L, -2, "description")
    skin.pushNSObject(kAXDisclosedByRowAttribute as NSString);             lua_setfield(L, -2, "disclosedByRow")
    skin.pushNSObject(kAXDisclosedRowsAttribute as NSString);              lua_setfield(L, -2, "disclosedRows")
    skin.pushNSObject(kAXDisclosingAttribute as NSString);                 lua_setfield(L, -2, "disclosing")
    skin.pushNSObject(kAXDisclosureLevelAttribute as NSString);            lua_setfield(L, -2, "disclosureLevel")
    skin.pushNSObject(kAXDocumentAttribute as NSString);                   lua_setfield(L, -2, "document")
    skin.pushNSObject(kAXEditedAttribute as NSString);                     lua_setfield(L, -2, "edited")
    skin.pushNSObject(kAXElementBusyAttribute as NSString);                lua_setfield(L, -2, "elementBusy")
    skin.pushNSObject(kAXEnabledAttribute as NSString);                    lua_setfield(L, -2, "enabled")
    skin.pushNSObject(kAXExpandedAttribute as NSString);                   lua_setfield(L, -2, "expanded")
    skin.pushNSObject(kAXExtrasMenuBarAttribute as NSString);              lua_setfield(L, -2, "extrasMenuBar")
    skin.pushNSObject(kAXFilenameAttribute as NSString);                   lua_setfield(L, -2, "filename")
    skin.pushNSObject(kAXFocusedAttribute as NSString);                    lua_setfield(L, -2, "focused")
    skin.pushNSObject(kAXFocusedApplicationAttribute as NSString);         lua_setfield(L, -2, "focusedApplication")
    skin.pushNSObject(kAXFocusedUIElementAttribute as NSString);           lua_setfield(L, -2, "focusedUIElement")
    skin.pushNSObject(kAXFocusedWindowAttribute as NSString);              lua_setfield(L, -2, "focusedWindow")
    skin.pushNSObject(kAXFontTextAttribute.takeUnretainedValue() as String as NSString);                   lua_setfield(L, -2, "font")
    skin.pushNSObject(kAXForegroundColorTextAttribute.takeUnretainedValue() as String as NSString);        lua_setfield(L, -2, "foregroundColor")
    skin.pushNSObject(kAXFrontmostAttribute as NSString);                  lua_setfield(L, -2, "frontmost")
    skin.pushNSObject(kAXFullScreenButtonAttribute as NSString);           lua_setfield(L, -2, "fullScreenButton")
    skin.pushNSObject(kAXGrowAreaAttribute as NSString);                   lua_setfield(L, -2, "growArea")
    skin.pushNSObject(kAXHandlesAttribute as NSString);                    lua_setfield(L, -2, "handles")
    skin.pushNSObject(kAXHeaderAttribute as NSString);                     lua_setfield(L, -2, "header")
    skin.pushNSObject(kAXHelpAttribute as NSString);                       lua_setfield(L, -2, "help")
    skin.pushNSObject(kAXHiddenAttribute as NSString);                     lua_setfield(L, -2, "hidden")
    skin.pushNSObject(kAXHorizontalScrollBarAttribute as NSString);        lua_setfield(L, -2, "horizontalScrollBar")
    skin.pushNSObject(kAXHorizontalUnitDescriptionAttribute as NSString);  lua_setfield(L, -2, "horizontalUnitDescription")
    skin.pushNSObject(kAXHorizontalUnitsAttribute as NSString);            lua_setfield(L, -2, "horizontalUnits")
    skin.pushNSObject(kAXHourFieldAttribute as NSString);                  lua_setfield(L, -2, "hourField")
    skin.pushNSObject(kAXIdentifierAttribute as NSString);                 lua_setfield(L, -2, "identifier")
    skin.pushNSObject(kAXIncrementButtonAttribute as NSString);            lua_setfield(L, -2, "incrementButton")
    skin.pushNSObject(kAXIncrementorAttribute as NSString);                lua_setfield(L, -2, "incrementor")
    skin.pushNSObject(kAXIndexAttribute as NSString);                      lua_setfield(L, -2, "index")
    skin.pushNSObject(kAXInsertionPointLineNumberAttribute as NSString);   lua_setfield(L, -2, "insertionPointLineNumber")
    skin.pushNSObject(kAXIsApplicationRunningAttribute as NSString);       lua_setfield(L, -2, "isApplicationRunning")
    skin.pushNSObject(kAXIsEditableAttribute as NSString);                 lua_setfield(L, -2, "isEditable")
    skin.pushNSObject(kAXLabelUIElementsAttribute as NSString);            lua_setfield(L, -2, "labelUIElements")
    skin.pushNSObject(kAXLabelValueAttribute as NSString);                 lua_setfield(L, -2, "labelValue")
    skin.pushNSObject(kAXLinkTextAttribute.takeUnretainedValue() as String as NSString);                   lua_setfield(L, -2, "link")
    skin.pushNSObject(kAXLinkedUIElementsAttribute as NSString);           lua_setfield(L, -2, "linkedUIElements")
    skin.pushNSObject(kAXListItemIndexTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "listItemIndex")
    skin.pushNSObject(kAXListItemLevelTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "listItemLevel")
    skin.pushNSObject(kAXListItemPrefixTextAttribute.takeUnretainedValue() as String as NSString);         lua_setfield(L, -2, "listItemPrefix")
    skin.pushNSObject(kAXMainAttribute as NSString);                       lua_setfield(L, -2, "main")
    skin.pushNSObject(kAXMainWindowAttribute as NSString);                 lua_setfield(L, -2, "mainWindow")
    skin.pushNSObject(kAXMarkedMisspelledTextAttribute.takeUnretainedValue() as String as NSString);       lua_setfield(L, -2, "markedMisspelled")
    skin.pushNSObject(NSAccessibility.Attribute.markerGroupUIElement.rawValue as NSString);                lua_setfield(L, -2, "markerGroupUIElement")
    skin.pushNSObject(kAXMarkerTypeAttribute as NSString);                 lua_setfield(L, -2, "markerType")
    skin.pushNSObject(kAXMarkerTypeDescriptionAttribute as NSString);      lua_setfield(L, -2, "markerTypeDescription")
    skin.pushNSObject(kAXMarkerUIElementsAttribute as NSString);           lua_setfield(L, -2, "markerUIElements")
    skin.pushNSObject(NSAccessibility.Attribute.markerValues.rawValue as NSString);                        lua_setfield(L, -2, "markerValues")
    skin.pushNSObject(kAXMatteContentUIElementAttribute as NSString);      lua_setfield(L, -2, "matteContentUIElement")
    skin.pushNSObject(kAXMatteHoleAttribute as NSString);                  lua_setfield(L, -2, "matteHole")
    skin.pushNSObject(kAXMaxValueAttribute as NSString);                   lua_setfield(L, -2, "maxValue")
    skin.pushNSObject(kAXMenuBarAttribute as NSString);                    lua_setfield(L, -2, "menuBar")
    skin.pushNSObject(kAXMenuItemCmdCharAttribute as NSString);            lua_setfield(L, -2, "menuItemCmdChar")
    skin.pushNSObject(kAXMenuItemCmdGlyphAttribute as NSString);           lua_setfield(L, -2, "menuItemCmdGlyph")
    skin.pushNSObject(kAXMenuItemCmdModifiersAttribute as NSString);       lua_setfield(L, -2, "menuItemCmdModifiers")
    skin.pushNSObject(kAXMenuItemCmdVirtualKeyAttribute as NSString);      lua_setfield(L, -2, "menuItemCmdVirtualKey")
    skin.pushNSObject(kAXMenuItemMarkCharAttribute as NSString);           lua_setfield(L, -2, "menuItemMarkChar")
    skin.pushNSObject(kAXMenuItemPrimaryUIElementAttribute as NSString);   lua_setfield(L, -2, "menuItemPrimaryUIElement")
    skin.pushNSObject(kAXMinimizeButtonAttribute as NSString);             lua_setfield(L, -2, "minimizeButton")
    skin.pushNSObject(kAXMinimizedAttribute as NSString);                  lua_setfield(L, -2, "minimized")
    skin.pushNSObject(kAXMinuteFieldAttribute as NSString);                lua_setfield(L, -2, "minuteField")
    skin.pushNSObject(kAXMinValueAttribute as NSString);                   lua_setfield(L, -2, "minValue")
    skin.pushNSObject(kAXMisspelledTextAttribute.takeUnretainedValue() as String as NSString);             lua_setfield(L, -2, "misspelled")
    skin.pushNSObject(kAXModalAttribute as NSString);                      lua_setfield(L, -2, "modal")
    skin.pushNSObject(kAXMonthFieldAttribute as NSString);                 lua_setfield(L, -2, "monthField")
    skin.pushNSObject(kAXNaturalLanguageTextAttribute.takeUnretainedValue() as String as NSString);        lua_setfield(L, -2, "naturalLanguage")
    skin.pushNSObject(kAXNextContentsAttribute as NSString);               lua_setfield(L, -2, "nextContents")
    skin.pushNSObject(kAXNumberOfCharactersAttribute as NSString);         lua_setfield(L, -2, "numberOfCharacters")
    skin.pushNSObject(kAXOrderedByRowAttribute as NSString);               lua_setfield(L, -2, "orderedByRow")
    skin.pushNSObject(kAXOrientationAttribute as NSString);                lua_setfield(L, -2, "orientation")
    skin.pushNSObject(kAXOverflowButtonAttribute as NSString);             lua_setfield(L, -2, "overflowButton")
    skin.pushNSObject(kAXParentAttribute as NSString);                     lua_setfield(L, -2, "parent")
    skin.pushNSObject(kAXPlaceholderValueAttribute as NSString);           lua_setfield(L, -2, "placeholderValue")
    skin.pushNSObject(kAXPositionAttribute as NSString);                   lua_setfield(L, -2, "position")
    skin.pushNSObject(kAXPreviousContentsAttribute as NSString);           lua_setfield(L, -2, "previousContents")
    skin.pushNSObject(kAXProxyAttribute as NSString);                      lua_setfield(L, -2, "proxy")
    skin.pushNSObject(kAXReplacementStringTextAttribute.takeUnretainedValue() as String as NSString);      lua_setfield(L, -2, "replacementString")
    skin.pushNSObject(NSAccessibility.Attribute.required.rawValue as NSString);                            lua_setfield(L, -2, "required")
    skin.pushNSObject(kAXRoleAttribute as NSString);                       lua_setfield(L, -2, "role")
    skin.pushNSObject(kAXRoleDescriptionAttribute as NSString);            lua_setfield(L, -2, "roleDescription")
    skin.pushNSObject(kAXRowCountAttribute as NSString);                   lua_setfield(L, -2, "rowCount")
    skin.pushNSObject(kAXRowHeaderUIElementsAttribute as NSString);        lua_setfield(L, -2, "rowHeaderUIElements")
    skin.pushNSObject(kAXRowIndexRangeAttribute as NSString);              lua_setfield(L, -2, "rowIndexRange")
    skin.pushNSObject(kAXRowsAttribute as NSString);                       lua_setfield(L, -2, "rows")
    skin.pushNSObject(kAXSearchButtonAttribute as NSString);               lua_setfield(L, -2, "searchButton")
    skin.pushNSObject(NSAccessibility.Attribute.searchMenu.rawValue as NSString);                          lua_setfield(L, -2, "searchMenu")
    skin.pushNSObject(kAXSecondFieldAttribute as NSString);                lua_setfield(L, -2, "secondField")
    skin.pushNSObject(kAXSelectedAttribute as NSString);                   lua_setfield(L, -2, "selected")
    skin.pushNSObject(kAXSelectedCellsAttribute as NSString);              lua_setfield(L, -2, "selectedCells")
    skin.pushNSObject(kAXSelectedChildrenAttribute as NSString);           lua_setfield(L, -2, "selectedChildren")
    skin.pushNSObject(kAXSelectedColumnsAttribute as NSString);            lua_setfield(L, -2, "selectedColumns")
    skin.pushNSObject(kAXSelectedRowsAttribute as NSString);               lua_setfield(L, -2, "selectedRows")
    skin.pushNSObject(kAXSelectedTextAttribute as NSString);               lua_setfield(L, -2, "selectedText")
    skin.pushNSObject(kAXSelectedTextRangeAttribute as NSString);          lua_setfield(L, -2, "selectedTextRange")
    skin.pushNSObject(kAXSelectedTextRangesAttribute as NSString);         lua_setfield(L, -2, "selectedTextRanges")
    skin.pushNSObject(kAXServesAsTitleForUIElementsAttribute as NSString); lua_setfield(L, -2, "servesAsTitleForUIElements")
    skin.pushNSObject(kAXShadowTextAttribute.takeUnretainedValue() as String as NSString);                 lua_setfield(L, -2, "shadow")
    skin.pushNSObject(kAXSharedCharacterRangeAttribute as NSString);       lua_setfield(L, -2, "sharedCharacterRange")
    skin.pushNSObject(kAXSharedFocusElementsAttribute as NSString);        lua_setfield(L, -2, "sharedFocusElements")
    skin.pushNSObject(kAXSharedTextUIElementsAttribute as NSString);       lua_setfield(L, -2, "sharedTextUIElements")
    skin.pushNSObject(kAXShownMenuUIElementAttribute as NSString);         lua_setfield(L, -2, "shownMenuUIElement")
    skin.pushNSObject(kAXSizeAttribute as NSString);                       lua_setfield(L, -2, "size")
    skin.pushNSObject(kAXSortDirectionAttribute as NSString);              lua_setfield(L, -2, "sortDirection")
    skin.pushNSObject(kAXSplittersAttribute as NSString);                  lua_setfield(L, -2, "splitters")
    skin.pushNSObject(kAXStrikethroughTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "strikethrough")
    skin.pushNSObject(kAXStrikethroughColorTextAttribute.takeUnretainedValue() as String as NSString);     lua_setfield(L, -2, "strikethroughColor")
    skin.pushNSObject(kAXSubroleAttribute as NSString);                    lua_setfield(L, -2, "subrole")
    skin.pushNSObject(kAXSuperscriptTextAttribute.takeUnretainedValue() as String as NSString);            lua_setfield(L, -2, "superscript")
    skin.pushNSObject(kAXTabsAttribute as NSString);                       lua_setfield(L, -2, "tabs")
    skin.pushNSObject(kAXTextAttribute as NSString);                       lua_setfield(L, -2, "text")
    skin.pushNSObject(NSAttributedString.Key.accessibilityAlignment.rawValue as NSString);                 lua_setfield(L, -2, "textAlignment")
    skin.pushNSObject(kAXTitleAttribute as NSString);                      lua_setfield(L, -2, "title")
    skin.pushNSObject(kAXTitleUIElementAttribute as NSString);             lua_setfield(L, -2, "titleUIElement")
    skin.pushNSObject(kAXToolbarButtonAttribute as NSString);              lua_setfield(L, -2, "toolbarButton")
    skin.pushNSObject(kAXTopLevelUIElementAttribute as NSString);          lua_setfield(L, -2, "topLevelUIElement")
    skin.pushNSObject(kAXUnderlineTextAttribute.takeUnretainedValue() as String as NSString);              lua_setfield(L, -2, "underline")
    skin.pushNSObject(kAXUnderlineColorTextAttribute.takeUnretainedValue() as String as NSString);         lua_setfield(L, -2, "underlineColor")
    skin.pushNSObject(kAXUnitDescriptionAttribute as NSString);            lua_setfield(L, -2, "unitDescription")
    skin.pushNSObject(kAXUnitsAttribute as NSString);                      lua_setfield(L, -2, "units")
    skin.pushNSObject(kAXURLAttribute as NSString);                        lua_setfield(L, -2, "URL")
    skin.pushNSObject(kAXValueAttribute as NSString);                      lua_setfield(L, -2, "value")
    skin.pushNSObject(kAXValueDescriptionAttribute as NSString);           lua_setfield(L, -2, "valueDescription")
    skin.pushNSObject(kAXValueIncrementAttribute as NSString);             lua_setfield(L, -2, "valueIncrement")
    skin.pushNSObject(kAXValueWrapsAttribute as NSString);                 lua_setfield(L, -2, "valueWraps")
    skin.pushNSObject(kAXVerticalScrollBarAttribute as NSString);          lua_setfield(L, -2, "verticalScrollBar")
    skin.pushNSObject(kAXVerticalUnitDescriptionAttribute as NSString);    lua_setfield(L, -2, "verticalUnitDescription")
    skin.pushNSObject(kAXVerticalUnitsAttribute as NSString);              lua_setfield(L, -2, "verticalUnits")
    skin.pushNSObject(kAXVisibleCellsAttribute as NSString);               lua_setfield(L, -2, "visibleCells")
    skin.pushNSObject(kAXVisibleCharacterRangeAttribute as NSString);      lua_setfield(L, -2, "visibleCharacterRange")
    skin.pushNSObject(kAXVisibleChildrenAttribute as NSString);            lua_setfield(L, -2, "visibleChildren")
    skin.pushNSObject(kAXVisibleColumnsAttribute as NSString);             lua_setfield(L, -2, "visibleColumns")
    skin.pushNSObject(kAXVisibleRowsAttribute as NSString);                lua_setfield(L, -2, "visibleRows")
    skin.pushNSObject(kAXVisibleTextAttribute as NSString);                lua_setfield(L, -2, "visibleText")
    skin.pushNSObject(kAXWarningValueAttribute as NSString);               lua_setfield(L, -2, "warningValue")
    skin.pushNSObject(kAXWindowAttribute as NSString);                     lua_setfield(L, -2, "window")
    skin.pushNSObject(kAXWindowsAttribute as NSString);                    lua_setfield(L, -2, "windows")
    skin.pushNSObject(kAXYearFieldAttribute as NSString);                  lua_setfield(L, -2, "yearField")
    skin.pushNSObject(kAXZoomButtonAttribute as NSString);                 lua_setfield(L, -2, "zoomButton")

    skin.pushNSObject(NSAttributedString.Key.accessibilityAnnotationTextAttribute.rawValue as NSString);   lua_setfield(L, -2, "annotationText")
    skin.pushNSObject(NSAttributedString.Key.accessibilityCustomText.rawValue as NSString);                lua_setfield(L, -2, "customText")

    return 1
}

/// hs.axuielement.parameterizedAttributes[]
/// Constant
/// A table of common accessibility object parameterized attribute names, provided for reference.
///
/// Notes:
///  * this table is provided for reference only and is not intended to be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.parameterizedAttributes`
///  * Parameterized attributes are attributes that take an argument when querying the element. There is very little documentation available for most of these and application developers can implement their own for which we may never be able to get any documentation. This table contains parameterized attribute names that are defined within the Apple documentation and a few others that have been discovered.
///  * Documentation covering what has been discovered through experimentation about parameterized attributes is planned and should be added to the Cosmic Hammer wiki shortly after this module becomes part of a formal release.
private func axuielement_pushParameterizedAttributesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(kAXAttributedStringForRangeParameterizedAttribute as NSString);  lua_setfield(L, -2, "attributedStringForRange")
    skin.pushNSObject(kAXBoundsForRangeParameterizedAttribute as NSString);            lua_setfield(L, -2, "boundsForRange")
    skin.pushNSObject(kAXCellForColumnAndRowParameterizedAttribute as NSString);       lua_setfield(L, -2, "cellForColumnAndRow")
    skin.pushNSObject(kAXLayoutPointForScreenPointParameterizedAttribute as NSString); lua_setfield(L, -2, "layoutPointForScreenPoint")
    skin.pushNSObject(kAXLayoutSizeForScreenSizeParameterizedAttribute as NSString);   lua_setfield(L, -2, "layoutSizeForScreenSize")
    skin.pushNSObject(kAXLineForIndexParameterizedAttribute as NSString);              lua_setfield(L, -2, "lineForIndex")
    skin.pushNSObject(kAXRangeForIndexParameterizedAttribute as NSString);             lua_setfield(L, -2, "rangeForIndex")
    skin.pushNSObject(kAXRangeForLineParameterizedAttribute as NSString);              lua_setfield(L, -2, "rangeForLine")
    skin.pushNSObject(kAXRangeForPositionParameterizedAttribute as NSString);          lua_setfield(L, -2, "rangeForPosition")
    skin.pushNSObject(kAXRTFForRangeParameterizedAttribute as NSString);               lua_setfield(L, -2, "RTFForRange")
    skin.pushNSObject(kAXScreenPointForLayoutPointParameterizedAttribute as NSString); lua_setfield(L, -2, "screenPointForLayoutPoint")
    skin.pushNSObject(kAXScreenSizeForLayoutSizeParameterizedAttribute as NSString);   lua_setfield(L, -2, "screenSizeForLayoutSize")
    skin.pushNSObject(kAXStringForRangeParameterizedAttribute as NSString);            lua_setfield(L, -2, "stringForRange")
    skin.pushNSObject(kAXStyleRangeForIndexParameterizedAttribute as NSString);        lua_setfield(L, -2, "styleRangeForIndex")

    return 1
}

/// hs.axuielement.actions[]
/// Constant
/// A table of common accessibility object action names, provided for reference.
///
/// Notes:
///  * this table is provided for reference only and is not intended to be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.actions`
private func axuielement_pushActionsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(kAXCancelAction as NSString);          lua_setfield(L, -2, "cancel")
    skin.pushNSObject(kAXConfirmAction as NSString);         lua_setfield(L, -2, "confirm")
    skin.pushNSObject(kAXDecrementAction as NSString);       lua_setfield(L, -2, "decrement")
    skin.pushNSObject(NSAccessibility.Action.delete.rawValue as NSString);                   lua_setfield(L, -2, "delete")
    skin.pushNSObject(kAXIncrementAction as NSString);       lua_setfield(L, -2, "increment")
    skin.pushNSObject(kAXPickAction as NSString);            lua_setfield(L, -2, "pick")
    skin.pushNSObject(kAXPressAction as NSString);           lua_setfield(L, -2, "press")
    skin.pushNSObject(kAXRaiseAction as NSString);           lua_setfield(L, -2, "raise")
    skin.pushNSObject(kAXShowAlternateUIAction as NSString); lua_setfield(L, -2, "showAlternateUI")
    skin.pushNSObject(kAXShowDefaultUIAction as NSString);   lua_setfield(L, -2, "showDefaultUI")
    skin.pushNSObject(kAXShowMenuAction as NSString);        lua_setfield(L, -2, "showMenu")
    return 1
}

/// hs.axuielement.roles[]
/// Constant
/// A table of common accessibility object roles which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as attribute values for "AXRole" in the match criteria argument.
///
/// Notes:
///  * this table is provided for reference only and is not intended to be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.roles`
private func axuielement_pushRolesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(kAXApplicationRole as NSString);        lua_setfield(L, -2, "application")
    skin.pushNSObject(kAXBrowserRole as NSString);            lua_setfield(L, -2, "browser")
    skin.pushNSObject(kAXBusyIndicatorRole as NSString);      lua_setfield(L, -2, "busyIndicator")
    skin.pushNSObject(kAXButtonRole as NSString);             lua_setfield(L, -2, "button")
    skin.pushNSObject(kAXCellRole as NSString);               lua_setfield(L, -2, "cell")
    skin.pushNSObject(kAXCheckBoxRole as NSString);           lua_setfield(L, -2, "checkBox")
    skin.pushNSObject(kAXColorWellRole as NSString);          lua_setfield(L, -2, "colorWell")
    skin.pushNSObject(kAXColumnRole as NSString);             lua_setfield(L, -2, "column")
    skin.pushNSObject(kAXComboBoxRole as NSString);           lua_setfield(L, -2, "comboBox")
    skin.pushNSObject(kAXDateFieldRole as NSString);          lua_setfield(L, -2, "dateField")
    skin.pushNSObject(kAXDisclosureTriangleRole as NSString); lua_setfield(L, -2, "disclosureTriangle")
    skin.pushNSObject(kAXDockItemRole as NSString);           lua_setfield(L, -2, "dockItem")
    skin.pushNSObject(kAXDrawerRole as NSString);             lua_setfield(L, -2, "drawer")
    skin.pushNSObject(kAXGridRole as NSString);               lua_setfield(L, -2, "grid")
    skin.pushNSObject(kAXGroupRole as NSString);              lua_setfield(L, -2, "group")
    skin.pushNSObject(kAXGrowAreaRole as NSString);           lua_setfield(L, -2, "growArea")
    skin.pushNSObject(kAXHandleRole as NSString);             lua_setfield(L, -2, "handle")
    skin.pushNSObject(kAXHelpTagRole as NSString);            lua_setfield(L, -2, "helpTag")
    skin.pushNSObject(kAXImageRole as NSString);              lua_setfield(L, -2, "image")
    skin.pushNSObject(kAXIncrementorRole as NSString);        lua_setfield(L, -2, "incrementor")
    skin.pushNSObject(kAXLayoutAreaRole as NSString);         lua_setfield(L, -2, "layoutArea")
    skin.pushNSObject(kAXLayoutItemRole as NSString);         lua_setfield(L, -2, "layoutItem")
    skin.pushNSObject(kAXLevelIndicatorRole as NSString);     lua_setfield(L, -2, "levelIndicator")
    skin.pushNSObject(kAXListRole as NSString);               lua_setfield(L, -2, "list")
    skin.pushNSObject(kAXMatteRole as NSString);              lua_setfield(L, -2, "matteRole")
    skin.pushNSObject(kAXMenuRole as NSString);               lua_setfield(L, -2, "menu")
    skin.pushNSObject(kAXMenuBarRole as NSString);            lua_setfield(L, -2, "menuBar")
    skin.pushNSObject(kAXMenuBarItemRole as NSString);        lua_setfield(L, -2, "menuBarItem")
    skin.pushNSObject(kAXMenuButtonRole as NSString);         lua_setfield(L, -2, "menuButton")
    skin.pushNSObject(kAXMenuItemRole as NSString);           lua_setfield(L, -2, "menuItem")
    skin.pushNSObject(kAXOutlineRole as NSString);            lua_setfield(L, -2, "outline")
    skin.pushNSObject(kAXPopoverRole as NSString);            lua_setfield(L, -2, "popover")
    skin.pushNSObject(kAXPopUpButtonRole as NSString);        lua_setfield(L, -2, "popUpButton")
    skin.pushNSObject(kAXProgressIndicatorRole as NSString);  lua_setfield(L, -2, "progressIndicator")
    skin.pushNSObject(kAXRadioButtonRole as NSString);        lua_setfield(L, -2, "radioButton")
    skin.pushNSObject(kAXRadioGroupRole as NSString);         lua_setfield(L, -2, "radioGroup")
    skin.pushNSObject(kAXRelevanceIndicatorRole as NSString); lua_setfield(L, -2, "relevanceIndicator")
    skin.pushNSObject(kAXRowRole as NSString);                lua_setfield(L, -2, "row")
    skin.pushNSObject(kAXRulerRole as NSString);              lua_setfield(L, -2, "ruler")
    skin.pushNSObject(kAXRulerMarkerRole as NSString);        lua_setfield(L, -2, "rulerMarker")
    skin.pushNSObject(kAXScrollAreaRole as NSString);         lua_setfield(L, -2, "scrollArea")
    skin.pushNSObject(kAXScrollBarRole as NSString);          lua_setfield(L, -2, "scrollBar")
    skin.pushNSObject(kAXSheetRole as NSString);              lua_setfield(L, -2, "sheet")
    skin.pushNSObject(kAXSliderRole as NSString);             lua_setfield(L, -2, "slider")
    skin.pushNSObject(kAXSplitGroupRole as NSString);         lua_setfield(L, -2, "splitGroup")
    skin.pushNSObject(kAXSplitterRole as NSString);           lua_setfield(L, -2, "splitter")
    skin.pushNSObject(kAXStaticTextRole as NSString);         lua_setfield(L, -2, "staticText")
    skin.pushNSObject(kAXSystemWideRole as NSString);         lua_setfield(L, -2, "systemWide")
    skin.pushNSObject(kAXTabGroupRole as NSString);           lua_setfield(L, -2, "tabGroup")
    skin.pushNSObject(kAXTableRole as NSString);              lua_setfield(L, -2, "table")
    skin.pushNSObject(kAXTextAreaRole as NSString);           lua_setfield(L, -2, "textArea")
    skin.pushNSObject(kAXTextFieldRole as NSString);          lua_setfield(L, -2, "textField")
    skin.pushNSObject(kAXTimeFieldRole as NSString);          lua_setfield(L, -2, "timeField")
    skin.pushNSObject(kAXToolbarRole as NSString);            lua_setfield(L, -2, "toolbar")
    skin.pushNSObject(kAXUnknownRole as NSString);            lua_setfield(L, -2, "unknown")
    skin.pushNSObject(kAXValueIndicatorRole as NSString);     lua_setfield(L, -2, "valueIndicator")
    skin.pushNSObject(kAXWindowRole as NSString);             lua_setfield(L, -2, "window")

    skin.pushNSObject(NSAccessibility.Role.link.rawValue as NSString);                        lua_setfield(L, -2, "link")
    skin.pushNSObject(NSAccessibility.Role.pageRole.rawValue as NSString);                     lua_setfield(L, -2, "page")

    return 1
}

/// hs.axuielement.subroles[]
/// Constant
/// A table of common accessibility object subroles which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as attribute values for "AXSubrole" in the match criteria argument.
///
/// Notes:
///  * this table is provided for reference only and is not intended to be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.subroles`
private func axuielement_pushSubrolesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(kAXApplicationDockItemSubrole as NSString);     lua_setfield(L, -2, "applicationDockItem")
    skin.pushNSObject(kAXCloseButtonSubrole as NSString);             lua_setfield(L, -2, "closeButton")
    skin.pushNSObject(kAXContentListSubrole as NSString);             lua_setfield(L, -2, "contentList")
    skin.pushNSObject(kAXDecorativeSubrole as NSString);              lua_setfield(L, -2, "decorative")
    skin.pushNSObject(kAXDecrementArrowSubrole as NSString);          lua_setfield(L, -2, "decrementArrow")
    skin.pushNSObject(kAXDecrementPageSubrole as NSString);           lua_setfield(L, -2, "decrementPage")
    skin.pushNSObject(NSAccessibility.Subrole.definitionList.rawValue as NSString);                   lua_setfield(L, -2, "definitionList")
    skin.pushNSObject(kAXDescriptionListSubrole as NSString);         lua_setfield(L, -2, "descriptionList")
    skin.pushNSObject(kAXDialogSubrole as NSString);                  lua_setfield(L, -2, "dialog")
    skin.pushNSObject(kAXDockExtraDockItemSubrole as NSString);       lua_setfield(L, -2, "dockExtraDockItem")
    skin.pushNSObject(kAXDocumentDockItemSubrole as NSString);        lua_setfield(L, -2, "documentDockItem")
    skin.pushNSObject(kAXFloatingWindowSubrole as NSString);          lua_setfield(L, -2, "floatingWindow")
    skin.pushNSObject(kAXFolderDockItemSubrole as NSString);          lua_setfield(L, -2, "folderDockItem")
    skin.pushNSObject(kAXFullScreenButtonSubrole as NSString);        lua_setfield(L, -2, "fullScreenButton")
    skin.pushNSObject(kAXIncrementArrowSubrole as NSString);          lua_setfield(L, -2, "incrementArrow")
    skin.pushNSObject(kAXIncrementPageSubrole as NSString);           lua_setfield(L, -2, "incrementPage")
    skin.pushNSObject(kAXMinimizeButtonSubrole as NSString);          lua_setfield(L, -2, "minimizeButton")
    skin.pushNSObject(kAXMinimizedWindowDockItemSubrole as NSString); lua_setfield(L, -2, "minimizedWindowDockItem")
    skin.pushNSObject(kAXOutlineRowSubrole as NSString);              lua_setfield(L, -2, "outlineRow")
    skin.pushNSObject(kAXProcessSwitcherListSubrole as NSString);     lua_setfield(L, -2, "processSwitcherList")
    skin.pushNSObject(kAXRatingIndicatorSubrole as NSString);         lua_setfield(L, -2, "ratingIndicator")
    skin.pushNSObject(kAXSearchFieldSubrole as NSString);             lua_setfield(L, -2, "searchField")
    skin.pushNSObject(kAXSecureTextFieldSubrole as NSString);         lua_setfield(L, -2, "secureTextField")
    skin.pushNSObject(kAXSeparatorDockItemSubrole as NSString);       lua_setfield(L, -2, "separatorDockItem")
    skin.pushNSObject(kAXSortButtonSubrole as NSString);              lua_setfield(L, -2, "sortButton")
    skin.pushNSObject(kAXStandardWindowSubrole as NSString);          lua_setfield(L, -2, "standardWindow")
    skin.pushNSObject(kAXSwitchSubrole as NSString);                  lua_setfield(L, -2, "switch")
    skin.pushNSObject(kAXSystemDialogSubrole as NSString);            lua_setfield(L, -2, "systemDialog")
    skin.pushNSObject(kAXSystemFloatingWindowSubrole as NSString);    lua_setfield(L, -2, "systemFloatingWindow")
    skin.pushNSObject(kAXTableRowSubrole as NSString);                lua_setfield(L, -2, "tableRow")
    skin.pushNSObject(NSAccessibility.Subrole.textAttachment.rawValue as NSString);                   lua_setfield(L, -2, "textAttachment")
    skin.pushNSObject(NSAccessibility.Subrole.textLink.rawValue as NSString);                         lua_setfield(L, -2, "textLink")
    skin.pushNSObject(kAXTimelineSubrole as NSString);                lua_setfield(L, -2, "timeline")
    skin.pushNSObject(kAXToggleSubrole as NSString);                  lua_setfield(L, -2, "toggle")
    skin.pushNSObject(kAXToolbarButtonSubrole as NSString);           lua_setfield(L, -2, "toolbarButton")
    skin.pushNSObject(kAXTrashDockItemSubrole as NSString);           lua_setfield(L, -2, "trashDockItem")
    skin.pushNSObject(kAXUnknownSubrole as NSString);                 lua_setfield(L, -2, "unknown")
    skin.pushNSObject(kAXURLDockItemSubrole as NSString);             lua_setfield(L, -2, "URLDockItem")
    skin.pushNSObject(kAXZoomButtonSubrole as NSString);              lua_setfield(L, -2, "zoomButton")

    skin.pushNSObject(NSAccessibility.Subrole.collectionListSubrole.rawValue as NSString);             lua_setfield(L, -2, "collectionList")
    skin.pushNSObject(NSAccessibility.Subrole.tabButtonSubrole.rawValue as NSString);                  lua_setfield(L, -2, "tabButton")
    skin.pushNSObject(NSAccessibility.Subrole.sectionListSubrole.rawValue as NSString);                lua_setfield(L, -2, "sectionList")

    return 1
}

/// hs.axuielement.orientations[]
/// Constant
/// A table of orientation types which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as attribute values for "AXOrientation" in the match criteria argument.
///
/// Notes:
///  * this table is provided for reference only and may not be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.orientations`
private func axuielement_pushOrientationsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(kAXHorizontalOrientationValue as NSString); lua_setfield(L, -2, "horizontal")
    skin.pushNSObject(kAXVerticalOrientationValue as NSString);   lua_setfield(L, -2, "vertical")
    skin.pushNSObject(kAXUnknownOrientationValue as NSString);    lua_setfield(L, -2, "unknown")
    return 1
}

/// hs.axuielement.sortDirections[]
/// Constant
/// A table of sort direction types which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as attribute values for "AXSortDirection" in the match criteria argument.
///
/// Notes:
///  * this table is provided for reference only and may not be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.sortDirections`
private func axuielement_pushSortDirectionsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(kAXAscendingSortDirectionValue as NSString);  lua_setfield(L, -2, "ascending")
    skin.pushNSObject(kAXDescendingSortDirectionValue as NSString); lua_setfield(L, -2, "descending")
    skin.pushNSObject(kAXUnknownSortDirectionValue as NSString);    lua_setfield(L, -2, "unknown")
    return 1
}

/// hs.axuielement.rulerMarkers[]
/// Constant
/// A table of ruler marker types which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as attribute values for "AXMarkerType" in the match criteria argument.
///
/// Notes:
///  * this table is provided for reference only and may not be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.rulerMarkers`
private func axuielement_pushRulerMarkerTypesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.centerTabStop.rawValue as NSString);   lua_setfield(L, -2, "centerTabStop")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.decimalTabStop.rawValue as NSString);  lua_setfield(L, -2, "decimalTabStop")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.firstLineIndent.rawValue as NSString); lua_setfield(L, -2, "firstLineIndent")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.headIndent.rawValue as NSString);      lua_setfield(L, -2, "headIndent")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.leftTabStop.rawValue as NSString);     lua_setfield(L, -2, "leftTabStop")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.rightTabStop.rawValue as NSString);    lua_setfield(L, -2, "rightTabStop")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.tailIndent.rawValue as NSString);      lua_setfield(L, -2, "tailIndent")
    skin.pushNSObject(NSAccessibility.RulerMarkerTypeValue.unknown.rawValue as NSString);         lua_setfield(L, -2, "unknown")
    return 1
}

/// hs.axuielement.units[]
/// Constant
/// A table of measurement unit types which may be used with [hs.axuielement:elementSearch](#elementSearch) or [hs.axuielement:matchesCriteria](#matchesCriteria) as attribute values for attributes which specify measurement unit types (e.g. "AXUnits", "AXHorizontalUnits", and "AXVerticalUnits") in the match criteria argument.
///
/// Notes:
///  * this table is provided for reference only and may not be comprehensive.
///  * you can view the contents of this table from the Cosmic Hammer console by typing in `hs.axuielement.units`
private func axuielement_pushUnitsTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(NSAccessibility.RulerUnitValue.centimeters.rawValue as NSString); lua_setfield(L, -2, "centimeters")
    skin.pushNSObject(NSAccessibility.RulerUnitValue.inches.rawValue as NSString);      lua_setfield(L, -2, "inches")
    skin.pushNSObject(NSAccessibility.RulerUnitValue.picas.rawValue as NSString);       lua_setfield(L, -2, "picas")
    skin.pushNSObject(NSAccessibility.RulerUnitValue.points.rawValue as NSString);      lua_setfield(L, -2, "points")
    skin.pushNSObject(NSAccessibility.RulerUnitValue.unknown.rawValue as NSString);     lua_setfield(L, -2, "unknown")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    var title: NSString = "*accessibility error*"
    if errorState == .success {
        title = value as! NSString
    } else if errorState == .invalidUIElement {
        title = "*element invalid*"
    }
    let ptrStr: String
    if let ptr = lua_topointer(L, 1) {
        ptrStr = String(format: "%p", UInt(bitPattern: ptr))
    } else {
        ptrStr = "0x0"
    }
    skin.pushNSObject(NSString(format: "%s: %@ (%@)", USERDATA_TAG, title, ptrStr as NSString))
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let _ = get_axuielementref(L, 1, USERDATA_TAG)
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theRef1 = get_axuielementref(L, 1, USERDATA_TAG)
    let theRef2 = get_axuielementref(L, 2, USERDATA_TAG)
    lua_pushboolean(L, CFEqual(theRef1, theRef2) ? 1 : 0)
    return 1
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("attributeNames"),              func: axuielement_getAttributeNames),
    luaL_Reg(name: strdup("allAttributeValues"),          func: axuielement_getAllAttributeValues),
    luaL_Reg(name: strdup("parameterizedAttributeNames"), func: axuielement_getParameterizedAttributeNames),
    luaL_Reg(name: strdup("actionNames"),                 func: axuielement_getActionNames),
    luaL_Reg(name: strdup("actionDescription"),           func: axuielement_getActionDescription),
    luaL_Reg(name: strdup("attributeValue"),              func: axuielement_getAttributeValue),
    luaL_Reg(name: strdup("parameterizedAttributeValue"), func: axuielement_getParameterizedAttributeValue),
    luaL_Reg(name: strdup("attributeValueCount"),         func: axuielement_getAttributeValueCount),
    luaL_Reg(name: strdup("isAttributeSettable"),         func: axuielement_isAttributeSettable),
    luaL_Reg(name: strdup("pid"),                         func: axuielement_getPid),
    luaL_Reg(name: strdup("performAction"),               func: axuielement_performAction),
    luaL_Reg(name: strdup("elementAtPosition"),           func: axuielement_getElementAtPosition),
    luaL_Reg(name: strdup("setAttributeValue"),           func: axuielement_setAttributeValue),
    luaL_Reg(name: strdup("asHSWindow"),                  func: axuielement_toHSWindow),
    luaL_Reg(name: strdup("asHSApplication"),             func: axuielement_toHSApplication),
    luaL_Reg(name: strdup("copy"),                        func: axuielement_duplicateReference),
    luaL_Reg(name: strdup("setTimeout"),                  func: axuielement_setTimeout),
    luaL_Reg(name: strdup("isValid"),                     func: axuielement_isValid),

    luaL_Reg(name: strdup("__tostring"),                  func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                        func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),                        func: userdata_gc),
    luaL_Reg(name: nil,                                   func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("systemWideElement"),        func: axuielement_getSystemWideElement),
    luaL_Reg(name: strdup("windowElement"),            func: axuielement_getWindowElement),
    luaL_Reg(name: strdup("applicationElement"),       func: axuielement_getApplicationElement),
    luaL_Reg(name: strdup("applicationElementForPID"), func: axuielement_getApplicationElementForPID),

    luaL_Reg(name: nil,                                func: nil),
]

@_cdecl("luaopen_hs_libaxuielement")
public func luaopen_hs_libaxuielement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    luaopen_hs_libaxuielementobserver(L); lua_setfield(L, -2, "observer")
    luaopen_hs_axuielement_axtextmarker(L); lua_setfield(L, -2, "axtextmarker")

    // For reference, since the object __init wrapper in init.lua and the keys for elementSearch don't
    // actually use them in case the user wants to use an Application defined attribute or action not
    // defined in the OS X headers.
    axuielement_pushAttributesTable(L);              lua_setfield(L, -2, "attributes")
    axuielement_pushParameterizedAttributesTable(L); lua_setfield(L, -2, "parameterizedAttributes")
    axuielement_pushActionsTable(L);                 lua_setfield(L, -2, "actions")

    // ditto on these, since they are actually results, not query-able parameters or actionable
    // commands; however they can be used with elementSearch as values in the criteria to find such.
    axuielement_pushRolesTable(L);                   lua_setfield(L, -2, "roles")
    axuielement_pushSubrolesTable(L);                lua_setfield(L, -2, "subroles")
    axuielement_pushSortDirectionsTable(L);          lua_setfield(L, -2, "sortDirections")
    axuielement_pushOrientationsTable(L);            lua_setfield(L, -2, "orientations")
    axuielement_pushRulerMarkerTypesTable(L);        lua_setfield(L, -2, "rulerMarkers")
    axuielement_pushUnitsTable(L);                   lua_setfield(L, -2, "units")

    return 1
}
