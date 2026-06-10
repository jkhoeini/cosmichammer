import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = axuielement_USERDATA_TAG
private var refTable: Int32 = LUA_NOREF

private func luaNSObject(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32, metatableName: String) -> NSObject? {
    guard luaL_testudata(L, idx, metatableName) != nil else { return nil }
    return lua_toAnyObject(L, at: idx) as? NSObject
}

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

    if let what = what {
        os_log(.debug, "%{public}s", String(format: "%s:%@ AXError %d for %@: %s", USERDATA_TAG, where_, err.rawValue, what, String(cString: axErrMsg)))
    } else {
        os_log(.debug, "%{public}s", String(format: "%s:%@ AXError %d: %s", USERDATA_TAG, where_, err.rawValue, String(cString: axErrMsg)))
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
private func axuielement_getWindowElement(_ L: LuaState) throws -> CInt {
    // vararg here to mimic original behavior and allow constructs to use `hs.window(...)` as arg as this may
    // return more than one result
    if let object = luaNSObject(L, at: 1, metatableName: "hs.window"),
       let ref = getElementRefPropertyFromClassObject(object) {
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
private func axuielement_getApplicationElement(_ L: LuaState) throws -> CInt {
    // vararg here to mimic original behavior and allow constructs to use `hs.application(...)` as arg as this may
    // return more than one result
    if let object = luaNSObject(L, at: 1, metatableName: "hs.application"),
       let ref = getElementRefPropertyFromClassObject(object) {
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
private func axuielement_getSystemWideElement(_ L: LuaState) throws -> CInt {
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
private func axuielement_getApplicationElementForPID(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TNUMBER)
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
private func axuielement_duplicateReference(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
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
private func axuielement_getAttributeNames(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var attributeNames: CFArray?
    let errorState = AXUIElementCopyAttributeNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_newtable(L)
        for value in attributeNames! as [AnyObject] {
            lua_pushany(L, value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        _ = errorWrapper(L, "attributeNames", nil, errorState)
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
private func axuielement_getActionNames(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var attributeNames: CFArray?
    let errorState = AXUIElementCopyActionNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_newtable(L)
        for value in attributeNames! as [AnyObject] {
            lua_pushany(L, value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        _ = errorWrapper(L, "actionNames", nil, errorState)
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
private func axuielement_getActionDescription(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let action = lua_tovalue(L, at: 2) as! NSString
    var description: CFString?
    let errorState = AXUIElementCopyActionDescription(theRef, action as CFString, &description)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushany(L, description! as NSString)
    } else if errorState == .noValue {
        lua_pushnil(L)
    } else {
        _ = errorWrapper(L, "actionDescription", action, errorState)
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
private func axuielement_getAttributeValue(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = lua_tovalue(L, at: 2) as! NSString
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, attribute as CFString, &value)
    var returnCount: Int32 = 1
    if errorState == .success {
        pushCFTypeToLua(L, value, refTable)
    } else if errorState == .noValue {
        lua_pushnil(L)
    } else {
        _ = errorWrapper(L, "attributeValue", attribute, errorState)
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
private func axuielement_getAllAttributeValues(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
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
            _ = errorWrapper(L, "allAttributeValues", "retrieving attribute values", errorState)
            returnCount += 1
        }
    } else {
        _ = errorWrapper(L, "allAttributeValues", "retrieving attribute names", errorState)
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
private func axuielement_getAttributeValueCount(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = lua_tovalue(L, at: 2) as! NSString
    var count: CFIndex = 0
    let errorState = AXUIElementGetAttributeValueCount(theRef, attribute as CFString, &count)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushinteger(L, lua_Integer(count))
    } else {
        _ = errorWrapper(L, "attributeValueCount", attribute, errorState)
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
private func axuielement_getParameterizedAttributeNames(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var attributeNames: CFArray?
    let errorState = AXUIElementCopyParameterizedAttributeNames(theRef, &attributeNames)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_newtable(L)
        for value in attributeNames! as [AnyObject] {
            lua_pushany(L, value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        _ = errorWrapper(L, "parameterizedAttributeNames", nil, errorState)
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
private func axuielement_isAttributeSettable(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = lua_tovalue(L, at: 2) as! NSString
    var settable: DarwinBoolean = false
    let errorState = AXUIElementIsAttributeSettable(theRef, attribute as CFString, &settable)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushboolean(L, settable.boolValue ? 1 : 0)
    } else {
        _ = errorWrapper(L, "isAttributeSettable", attribute, errorState)
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
private func axuielement_isValid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushboolean(L, 1)
    } else if errorState == .invalidUIElement {
        lua_pushboolean(L, 0)
    } else {
        _ = errorWrapper(L, "pid", nil, errorState)
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
private func axuielement_getPid(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var thePid: pid_t = 0
    let errorState = AXUIElementGetPid(theRef, &thePid)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushinteger(L, lua_Integer(thePid))
    } else {
        _ = errorWrapper(L, "pid", nil, errorState)
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
private func axuielement_performAction(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let action = lua_tovalue(L, at: 2) as! NSString
    var errorState: AXError = .success
    if let exMsg = catchingObjCException({
        errorState = AXUIElementPerformAction(theRef, action as CFString)
    }) {
        os_log(.error, "caught ObjC exception in AXUIElementPerformAction: %{public}s", exMsg)
        lua_pushnil(L)
        return 1
    }
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushvalue(L, 1)
    } else if errorState == .cannotComplete {
        lua_pushboolean(L, 0)
    } else {
        _ = errorWrapper(L, "performAction", action, errorState)
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
private func axuielement_getElementAtPosition(_ L: LuaState) throws -> CInt {
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var returnCount: Int32 = 1
    if isApplicationOrSystem(theRef) {
        var x: Float
        var y: Float
        if lua_type(L, 2) == LUA_TTABLE && lua_gettop(L) == 2 {
            let thePoint = lua_tableToPoint(L, at: 2)
            x = Float(thePoint.x)
            y = Float(thePoint.y)
        } else if lua_gettop(L) == 3 {
            x = Float(lua_tonumber(L, 2))
            y = Float(lua_tonumber(L, 3))
        } else {
            throw LuaCallError("point table or x and y as numbers expected")
        }
        var value: AXUIElement?
        let errorState = AXUIElementCopyElementAtPosition(theRef, x, y, &value)
        if errorState == .success {
            pushAXUIElement(L, value!)
        } else {
            _ = errorWrapper(L, "elementAtPosition", nil, errorState)
            returnCount += 1
        }
    } else {
        throw LuaCallError("must be application or systemWide element")
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
private func axuielement_getParameterizedAttributeValue(_ L: LuaState) throws -> CInt {
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = lua_tovalue(L, at: 2) as! NSString
    let parameter = lua_toCFType(L, 3)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyParameterizedAttributeValue(theRef, attribute as CFString, parameter, &value)
    var returnCount: Int32 = 1
    if errorState == .success {
        pushCFTypeToLua(L, value, refTable)
    } else if errorState == .noValue {
        lua_pushnil(L)
    } else {
        _ = errorWrapper(L, "parameterizedAttributeValue", attribute, errorState)
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
private func axuielement_setAttributeValue(_ L: LuaState) throws -> CInt {
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    let attribute = lua_tovalue(L, at: 2) as! NSString
    let value = lua_toCFType(L, 3)
    let errorState = AXUIElementSetAttributeValue(theRef, attribute as CFString, value)
    var returnCount: Int32 = 1
    if errorState == .success {
        lua_pushvalue(L, 1)
    } else {
        _ = errorWrapper(L, "setAttributeValue", attribute, errorState)
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
private func axuielement_toHSApplication(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
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
            pushHSapplicationOrNil(L, HSapplication(pid: thePid, withState: L))
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
private func axuielement_toHSWindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var value: CFTypeRef?
    let errorState = AXUIElementCopyAttributeValue(theRef, "AXRole" as CFString, &value)
    if errorState == .success,
       let value = value,
       CFGetTypeID(value) == CFStringGetTypeID(),
       (value as! String) == (kAXWindowRole as String) {
        pushHSwindowOrNil(L, HSwindow(axuiElementRef: theRef))
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
private func axuielement_setTimeout(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)
    let theRef = get_axuielementref(L, 1, USERDATA_TAG)
    var returnCount: Int32 = 1
    var timeout = Float(lua_tonumber(L, 2))
    if timeout < 0 { timeout = 0 }
    let errorState = AXUIElementSetMessagingTimeout(theRef, timeout)
    if errorState == .success {
        lua_pushvalue(L, 1)
    } else {
        _ = errorWrapper(L, "setTimeout", nil, errorState)
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
    lua_newtable(L)
    lua_pushany(L, NSAccessibility.Attribute.activationPoint.rawValue as NSString);                     lua_setfield(L, -2, "activationPoint")
    lua_pushany(L, kAXAllowedValuesAttribute as NSString);              lua_setfield(L, -2, "allowedValues")
    lua_pushany(L, kAXAlternateUIVisibleAttribute as NSString);         lua_setfield(L, -2, "alternateUIVisible")
    lua_pushany(L, kAXAMPMFieldAttribute as NSString);                  lua_setfield(L, -2, "AMPMField")
    lua_pushany(L, kAXAttachmentTextAttribute.takeUnretainedValue() as String as NSString);             lua_setfield(L, -2, "attachment")
    lua_pushany(L, kAXAutocorrectedTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "autocorrected")
    lua_pushany(L, kAXBackgroundColorTextAttribute.takeUnretainedValue() as String as NSString);        lua_setfield(L, -2, "backgroundColor")
    lua_pushany(L, kAXCancelButtonAttribute as NSString);               lua_setfield(L, -2, "cancelButton")
    lua_pushany(L, kAXChildrenAttribute as NSString);                   lua_setfield(L, -2, "children")
    lua_pushany(L, kAXClearButtonAttribute as NSString);                lua_setfield(L, -2, "clearButton")
    lua_pushany(L, kAXCloseButtonAttribute as NSString);                lua_setfield(L, -2, "closeButton")
    lua_pushany(L, kAXColumnCountAttribute as NSString);                lua_setfield(L, -2, "columnCount")
    lua_pushany(L, kAXColumnHeaderUIElementsAttribute as NSString);     lua_setfield(L, -2, "columnHeaderUIElements")
    lua_pushany(L, kAXColumnIndexRangeAttribute as NSString);           lua_setfield(L, -2, "columnIndexRange")
    lua_pushany(L, kAXColumnsAttribute as NSString);                    lua_setfield(L, -2, "columns")
    lua_pushany(L, kAXColumnTitlesAttribute as NSString);               lua_setfield(L, -2, "columnTitles")
    lua_pushany(L, NSAccessibility.Attribute.containsProtectedContent.rawValue as NSString);            lua_setfield(L, -2, "containsProtectedContent")
    lua_pushany(L, kAXContentsAttribute as NSString);                   lua_setfield(L, -2, "contents")
    lua_pushany(L, kAXCriticalValueAttribute as NSString);              lua_setfield(L, -2, "criticalValue")
    lua_pushany(L, kAXDayFieldAttribute as NSString);                   lua_setfield(L, -2, "dayField")
    lua_pushany(L, kAXDecrementButtonAttribute as NSString);            lua_setfield(L, -2, "decrementButton")
    lua_pushany(L, kAXDefaultButtonAttribute as NSString);              lua_setfield(L, -2, "defaultButton")
    lua_pushany(L, kAXDescriptionAttribute as NSString);                lua_setfield(L, -2, "description")
    lua_pushany(L, kAXDisclosedByRowAttribute as NSString);             lua_setfield(L, -2, "disclosedByRow")
    lua_pushany(L, kAXDisclosedRowsAttribute as NSString);              lua_setfield(L, -2, "disclosedRows")
    lua_pushany(L, kAXDisclosingAttribute as NSString);                 lua_setfield(L, -2, "disclosing")
    lua_pushany(L, kAXDisclosureLevelAttribute as NSString);            lua_setfield(L, -2, "disclosureLevel")
    lua_pushany(L, kAXDocumentAttribute as NSString);                   lua_setfield(L, -2, "document")
    lua_pushany(L, kAXEditedAttribute as NSString);                     lua_setfield(L, -2, "edited")
    lua_pushany(L, kAXElementBusyAttribute as NSString);                lua_setfield(L, -2, "elementBusy")
    lua_pushany(L, kAXEnabledAttribute as NSString);                    lua_setfield(L, -2, "enabled")
    lua_pushany(L, kAXExpandedAttribute as NSString);                   lua_setfield(L, -2, "expanded")
    lua_pushany(L, kAXExtrasMenuBarAttribute as NSString);              lua_setfield(L, -2, "extrasMenuBar")
    lua_pushany(L, kAXFilenameAttribute as NSString);                   lua_setfield(L, -2, "filename")
    lua_pushany(L, kAXFocusedAttribute as NSString);                    lua_setfield(L, -2, "focused")
    lua_pushany(L, kAXFocusedApplicationAttribute as NSString);         lua_setfield(L, -2, "focusedApplication")
    lua_pushany(L, kAXFocusedUIElementAttribute as NSString);           lua_setfield(L, -2, "focusedUIElement")
    lua_pushany(L, kAXFocusedWindowAttribute as NSString);              lua_setfield(L, -2, "focusedWindow")
    lua_pushany(L, kAXFontTextAttribute.takeUnretainedValue() as String as NSString);                   lua_setfield(L, -2, "font")
    lua_pushany(L, kAXForegroundColorTextAttribute.takeUnretainedValue() as String as NSString);        lua_setfield(L, -2, "foregroundColor")
    lua_pushany(L, kAXFrontmostAttribute as NSString);                  lua_setfield(L, -2, "frontmost")
    lua_pushany(L, kAXFullScreenButtonAttribute as NSString);           lua_setfield(L, -2, "fullScreenButton")
    lua_pushany(L, kAXGrowAreaAttribute as NSString);                   lua_setfield(L, -2, "growArea")
    lua_pushany(L, kAXHandlesAttribute as NSString);                    lua_setfield(L, -2, "handles")
    lua_pushany(L, kAXHeaderAttribute as NSString);                     lua_setfield(L, -2, "header")
    lua_pushany(L, kAXHelpAttribute as NSString);                       lua_setfield(L, -2, "help")
    lua_pushany(L, kAXHiddenAttribute as NSString);                     lua_setfield(L, -2, "hidden")
    lua_pushany(L, kAXHorizontalScrollBarAttribute as NSString);        lua_setfield(L, -2, "horizontalScrollBar")
    lua_pushany(L, kAXHorizontalUnitDescriptionAttribute as NSString);  lua_setfield(L, -2, "horizontalUnitDescription")
    lua_pushany(L, kAXHorizontalUnitsAttribute as NSString);            lua_setfield(L, -2, "horizontalUnits")
    lua_pushany(L, kAXHourFieldAttribute as NSString);                  lua_setfield(L, -2, "hourField")
    lua_pushany(L, kAXIdentifierAttribute as NSString);                 lua_setfield(L, -2, "identifier")
    lua_pushany(L, kAXIncrementButtonAttribute as NSString);            lua_setfield(L, -2, "incrementButton")
    lua_pushany(L, kAXIncrementorAttribute as NSString);                lua_setfield(L, -2, "incrementor")
    lua_pushany(L, kAXIndexAttribute as NSString);                      lua_setfield(L, -2, "index")
    lua_pushany(L, kAXInsertionPointLineNumberAttribute as NSString);   lua_setfield(L, -2, "insertionPointLineNumber")
    lua_pushany(L, kAXIsApplicationRunningAttribute as NSString);       lua_setfield(L, -2, "isApplicationRunning")
    lua_pushany(L, kAXIsEditableAttribute as NSString);                 lua_setfield(L, -2, "isEditable")
    lua_pushany(L, kAXLabelUIElementsAttribute as NSString);            lua_setfield(L, -2, "labelUIElements")
    lua_pushany(L, kAXLabelValueAttribute as NSString);                 lua_setfield(L, -2, "labelValue")
    lua_pushany(L, kAXLinkTextAttribute.takeUnretainedValue() as String as NSString);                   lua_setfield(L, -2, "link")
    lua_pushany(L, kAXLinkedUIElementsAttribute as NSString);           lua_setfield(L, -2, "linkedUIElements")
    lua_pushany(L, kAXListItemIndexTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "listItemIndex")
    lua_pushany(L, kAXListItemLevelTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "listItemLevel")
    lua_pushany(L, kAXListItemPrefixTextAttribute.takeUnretainedValue() as String as NSString);         lua_setfield(L, -2, "listItemPrefix")
    lua_pushany(L, kAXMainAttribute as NSString);                       lua_setfield(L, -2, "main")
    lua_pushany(L, kAXMainWindowAttribute as NSString);                 lua_setfield(L, -2, "mainWindow")
    lua_pushany(L, kAXMarkedMisspelledTextAttribute.takeUnretainedValue() as String as NSString);       lua_setfield(L, -2, "markedMisspelled")
    lua_pushany(L, NSAccessibility.Attribute.markerGroupUIElement.rawValue as NSString);                lua_setfield(L, -2, "markerGroupUIElement")
    lua_pushany(L, kAXMarkerTypeAttribute as NSString);                 lua_setfield(L, -2, "markerType")
    lua_pushany(L, kAXMarkerTypeDescriptionAttribute as NSString);      lua_setfield(L, -2, "markerTypeDescription")
    lua_pushany(L, kAXMarkerUIElementsAttribute as NSString);           lua_setfield(L, -2, "markerUIElements")
    lua_pushany(L, NSAccessibility.Attribute.markerValues.rawValue as NSString);                        lua_setfield(L, -2, "markerValues")
    lua_pushany(L, kAXMatteContentUIElementAttribute as NSString);      lua_setfield(L, -2, "matteContentUIElement")
    lua_pushany(L, kAXMatteHoleAttribute as NSString);                  lua_setfield(L, -2, "matteHole")
    lua_pushany(L, kAXMaxValueAttribute as NSString);                   lua_setfield(L, -2, "maxValue")
    lua_pushany(L, kAXMenuBarAttribute as NSString);                    lua_setfield(L, -2, "menuBar")
    lua_pushany(L, kAXMenuItemCmdCharAttribute as NSString);            lua_setfield(L, -2, "menuItemCmdChar")
    lua_pushany(L, kAXMenuItemCmdGlyphAttribute as NSString);           lua_setfield(L, -2, "menuItemCmdGlyph")
    lua_pushany(L, kAXMenuItemCmdModifiersAttribute as NSString);       lua_setfield(L, -2, "menuItemCmdModifiers")
    lua_pushany(L, kAXMenuItemCmdVirtualKeyAttribute as NSString);      lua_setfield(L, -2, "menuItemCmdVirtualKey")
    lua_pushany(L, kAXMenuItemMarkCharAttribute as NSString);           lua_setfield(L, -2, "menuItemMarkChar")
    lua_pushany(L, kAXMenuItemPrimaryUIElementAttribute as NSString);   lua_setfield(L, -2, "menuItemPrimaryUIElement")
    lua_pushany(L, kAXMinimizeButtonAttribute as NSString);             lua_setfield(L, -2, "minimizeButton")
    lua_pushany(L, kAXMinimizedAttribute as NSString);                  lua_setfield(L, -2, "minimized")
    lua_pushany(L, kAXMinuteFieldAttribute as NSString);                lua_setfield(L, -2, "minuteField")
    lua_pushany(L, kAXMinValueAttribute as NSString);                   lua_setfield(L, -2, "minValue")
    lua_pushany(L, kAXMisspelledTextAttribute.takeUnretainedValue() as String as NSString);             lua_setfield(L, -2, "misspelled")
    lua_pushany(L, kAXModalAttribute as NSString);                      lua_setfield(L, -2, "modal")
    lua_pushany(L, kAXMonthFieldAttribute as NSString);                 lua_setfield(L, -2, "monthField")
    lua_pushany(L, kAXNaturalLanguageTextAttribute.takeUnretainedValue() as String as NSString);        lua_setfield(L, -2, "naturalLanguage")
    lua_pushany(L, kAXNextContentsAttribute as NSString);               lua_setfield(L, -2, "nextContents")
    lua_pushany(L, kAXNumberOfCharactersAttribute as NSString);         lua_setfield(L, -2, "numberOfCharacters")
    lua_pushany(L, kAXOrderedByRowAttribute as NSString);               lua_setfield(L, -2, "orderedByRow")
    lua_pushany(L, kAXOrientationAttribute as NSString);                lua_setfield(L, -2, "orientation")
    lua_pushany(L, kAXOverflowButtonAttribute as NSString);             lua_setfield(L, -2, "overflowButton")
    lua_pushany(L, kAXParentAttribute as NSString);                     lua_setfield(L, -2, "parent")
    lua_pushany(L, kAXPlaceholderValueAttribute as NSString);           lua_setfield(L, -2, "placeholderValue")
    lua_pushany(L, kAXPositionAttribute as NSString);                   lua_setfield(L, -2, "position")
    lua_pushany(L, kAXPreviousContentsAttribute as NSString);           lua_setfield(L, -2, "previousContents")
    lua_pushany(L, kAXProxyAttribute as NSString);                      lua_setfield(L, -2, "proxy")
    lua_pushany(L, kAXReplacementStringTextAttribute.takeUnretainedValue() as String as NSString);      lua_setfield(L, -2, "replacementString")
    lua_pushany(L, NSAccessibility.Attribute.required.rawValue as NSString);                            lua_setfield(L, -2, "required")
    lua_pushany(L, kAXRoleAttribute as NSString);                       lua_setfield(L, -2, "role")
    lua_pushany(L, kAXRoleDescriptionAttribute as NSString);            lua_setfield(L, -2, "roleDescription")
    lua_pushany(L, kAXRowCountAttribute as NSString);                   lua_setfield(L, -2, "rowCount")
    lua_pushany(L, kAXRowHeaderUIElementsAttribute as NSString);        lua_setfield(L, -2, "rowHeaderUIElements")
    lua_pushany(L, kAXRowIndexRangeAttribute as NSString);              lua_setfield(L, -2, "rowIndexRange")
    lua_pushany(L, kAXRowsAttribute as NSString);                       lua_setfield(L, -2, "rows")
    lua_pushany(L, kAXSearchButtonAttribute as NSString);               lua_setfield(L, -2, "searchButton")
    lua_pushany(L, NSAccessibility.Attribute.searchMenu.rawValue as NSString);                          lua_setfield(L, -2, "searchMenu")
    lua_pushany(L, kAXSecondFieldAttribute as NSString);                lua_setfield(L, -2, "secondField")
    lua_pushany(L, kAXSelectedAttribute as NSString);                   lua_setfield(L, -2, "selected")
    lua_pushany(L, kAXSelectedCellsAttribute as NSString);              lua_setfield(L, -2, "selectedCells")
    lua_pushany(L, kAXSelectedChildrenAttribute as NSString);           lua_setfield(L, -2, "selectedChildren")
    lua_pushany(L, kAXSelectedColumnsAttribute as NSString);            lua_setfield(L, -2, "selectedColumns")
    lua_pushany(L, kAXSelectedRowsAttribute as NSString);               lua_setfield(L, -2, "selectedRows")
    lua_pushany(L, kAXSelectedTextAttribute as NSString);               lua_setfield(L, -2, "selectedText")
    lua_pushany(L, kAXSelectedTextRangeAttribute as NSString);          lua_setfield(L, -2, "selectedTextRange")
    lua_pushany(L, kAXSelectedTextRangesAttribute as NSString);         lua_setfield(L, -2, "selectedTextRanges")
    lua_pushany(L, kAXServesAsTitleForUIElementsAttribute as NSString); lua_setfield(L, -2, "servesAsTitleForUIElements")
    lua_pushany(L, kAXShadowTextAttribute.takeUnretainedValue() as String as NSString);                 lua_setfield(L, -2, "shadow")
    lua_pushany(L, kAXSharedCharacterRangeAttribute as NSString);       lua_setfield(L, -2, "sharedCharacterRange")
    lua_pushany(L, kAXSharedFocusElementsAttribute as NSString);        lua_setfield(L, -2, "sharedFocusElements")
    lua_pushany(L, kAXSharedTextUIElementsAttribute as NSString);       lua_setfield(L, -2, "sharedTextUIElements")
    lua_pushany(L, kAXShownMenuUIElementAttribute as NSString);         lua_setfield(L, -2, "shownMenuUIElement")
    lua_pushany(L, kAXSizeAttribute as NSString);                       lua_setfield(L, -2, "size")
    lua_pushany(L, kAXSortDirectionAttribute as NSString);              lua_setfield(L, -2, "sortDirection")
    lua_pushany(L, kAXSplittersAttribute as NSString);                  lua_setfield(L, -2, "splitters")
    lua_pushany(L, kAXStrikethroughTextAttribute.takeUnretainedValue() as String as NSString);          lua_setfield(L, -2, "strikethrough")
    lua_pushany(L, kAXStrikethroughColorTextAttribute.takeUnretainedValue() as String as NSString);     lua_setfield(L, -2, "strikethroughColor")
    lua_pushany(L, kAXSubroleAttribute as NSString);                    lua_setfield(L, -2, "subrole")
    lua_pushany(L, kAXSuperscriptTextAttribute.takeUnretainedValue() as String as NSString);            lua_setfield(L, -2, "superscript")
    lua_pushany(L, kAXTabsAttribute as NSString);                       lua_setfield(L, -2, "tabs")
    lua_pushany(L, kAXTextAttribute as NSString);                       lua_setfield(L, -2, "text")
    lua_pushany(L, NSAttributedString.Key.accessibilityAlignment.rawValue as NSString);                 lua_setfield(L, -2, "textAlignment")
    lua_pushany(L, kAXTitleAttribute as NSString);                      lua_setfield(L, -2, "title")
    lua_pushany(L, kAXTitleUIElementAttribute as NSString);             lua_setfield(L, -2, "titleUIElement")
    lua_pushany(L, kAXToolbarButtonAttribute as NSString);              lua_setfield(L, -2, "toolbarButton")
    lua_pushany(L, kAXTopLevelUIElementAttribute as NSString);          lua_setfield(L, -2, "topLevelUIElement")
    lua_pushany(L, kAXUnderlineTextAttribute.takeUnretainedValue() as String as NSString);              lua_setfield(L, -2, "underline")
    lua_pushany(L, kAXUnderlineColorTextAttribute.takeUnretainedValue() as String as NSString);         lua_setfield(L, -2, "underlineColor")
    lua_pushany(L, kAXUnitDescriptionAttribute as NSString);            lua_setfield(L, -2, "unitDescription")
    lua_pushany(L, kAXUnitsAttribute as NSString);                      lua_setfield(L, -2, "units")
    lua_pushany(L, kAXURLAttribute as NSString);                        lua_setfield(L, -2, "URL")
    lua_pushany(L, kAXValueAttribute as NSString);                      lua_setfield(L, -2, "value")
    lua_pushany(L, kAXValueDescriptionAttribute as NSString);           lua_setfield(L, -2, "valueDescription")
    lua_pushany(L, kAXValueIncrementAttribute as NSString);             lua_setfield(L, -2, "valueIncrement")
    lua_pushany(L, kAXValueWrapsAttribute as NSString);                 lua_setfield(L, -2, "valueWraps")
    lua_pushany(L, kAXVerticalScrollBarAttribute as NSString);          lua_setfield(L, -2, "verticalScrollBar")
    lua_pushany(L, kAXVerticalUnitDescriptionAttribute as NSString);    lua_setfield(L, -2, "verticalUnitDescription")
    lua_pushany(L, kAXVerticalUnitsAttribute as NSString);              lua_setfield(L, -2, "verticalUnits")
    lua_pushany(L, kAXVisibleCellsAttribute as NSString);               lua_setfield(L, -2, "visibleCells")
    lua_pushany(L, kAXVisibleCharacterRangeAttribute as NSString);      lua_setfield(L, -2, "visibleCharacterRange")
    lua_pushany(L, kAXVisibleChildrenAttribute as NSString);            lua_setfield(L, -2, "visibleChildren")
    lua_pushany(L, kAXVisibleColumnsAttribute as NSString);             lua_setfield(L, -2, "visibleColumns")
    lua_pushany(L, kAXVisibleRowsAttribute as NSString);                lua_setfield(L, -2, "visibleRows")
    lua_pushany(L, kAXVisibleTextAttribute as NSString);                lua_setfield(L, -2, "visibleText")
    lua_pushany(L, kAXWarningValueAttribute as NSString);               lua_setfield(L, -2, "warningValue")
    lua_pushany(L, kAXWindowAttribute as NSString);                     lua_setfield(L, -2, "window")
    lua_pushany(L, kAXWindowsAttribute as NSString);                    lua_setfield(L, -2, "windows")
    lua_pushany(L, kAXYearFieldAttribute as NSString);                  lua_setfield(L, -2, "yearField")
    lua_pushany(L, kAXZoomButtonAttribute as NSString);                 lua_setfield(L, -2, "zoomButton")

    lua_pushany(L, NSAttributedString.Key.accessibilityAnnotationTextAttribute.rawValue as NSString);   lua_setfield(L, -2, "annotationText")
    lua_pushany(L, NSAttributedString.Key.accessibilityCustomText.rawValue as NSString);                lua_setfield(L, -2, "customText")

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
    lua_newtable(L)
    lua_pushany(L, kAXAttributedStringForRangeParameterizedAttribute as NSString);  lua_setfield(L, -2, "attributedStringForRange")
    lua_pushany(L, kAXBoundsForRangeParameterizedAttribute as NSString);            lua_setfield(L, -2, "boundsForRange")
    lua_pushany(L, kAXCellForColumnAndRowParameterizedAttribute as NSString);       lua_setfield(L, -2, "cellForColumnAndRow")
    lua_pushany(L, kAXLayoutPointForScreenPointParameterizedAttribute as NSString); lua_setfield(L, -2, "layoutPointForScreenPoint")
    lua_pushany(L, kAXLayoutSizeForScreenSizeParameterizedAttribute as NSString);   lua_setfield(L, -2, "layoutSizeForScreenSize")
    lua_pushany(L, kAXLineForIndexParameterizedAttribute as NSString);              lua_setfield(L, -2, "lineForIndex")
    lua_pushany(L, kAXRangeForIndexParameterizedAttribute as NSString);             lua_setfield(L, -2, "rangeForIndex")
    lua_pushany(L, kAXRangeForLineParameterizedAttribute as NSString);              lua_setfield(L, -2, "rangeForLine")
    lua_pushany(L, kAXRangeForPositionParameterizedAttribute as NSString);          lua_setfield(L, -2, "rangeForPosition")
    lua_pushany(L, kAXRTFForRangeParameterizedAttribute as NSString);               lua_setfield(L, -2, "RTFForRange")
    lua_pushany(L, kAXScreenPointForLayoutPointParameterizedAttribute as NSString); lua_setfield(L, -2, "screenPointForLayoutPoint")
    lua_pushany(L, kAXScreenSizeForLayoutSizeParameterizedAttribute as NSString);   lua_setfield(L, -2, "screenSizeForLayoutSize")
    lua_pushany(L, kAXStringForRangeParameterizedAttribute as NSString);            lua_setfield(L, -2, "stringForRange")
    lua_pushany(L, kAXStyleRangeForIndexParameterizedAttribute as NSString);        lua_setfield(L, -2, "styleRangeForIndex")

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
    lua_newtable(L)
    lua_pushany(L, kAXCancelAction as NSString);          lua_setfield(L, -2, "cancel")
    lua_pushany(L, kAXConfirmAction as NSString);         lua_setfield(L, -2, "confirm")
    lua_pushany(L, kAXDecrementAction as NSString);       lua_setfield(L, -2, "decrement")
    lua_pushany(L, NSAccessibility.Action.delete.rawValue as NSString);                   lua_setfield(L, -2, "delete")
    lua_pushany(L, kAXIncrementAction as NSString);       lua_setfield(L, -2, "increment")
    lua_pushany(L, kAXPickAction as NSString);            lua_setfield(L, -2, "pick")
    lua_pushany(L, kAXPressAction as NSString);           lua_setfield(L, -2, "press")
    lua_pushany(L, kAXRaiseAction as NSString);           lua_setfield(L, -2, "raise")
    lua_pushany(L, kAXShowAlternateUIAction as NSString); lua_setfield(L, -2, "showAlternateUI")
    lua_pushany(L, kAXShowDefaultUIAction as NSString);   lua_setfield(L, -2, "showDefaultUI")
    lua_pushany(L, kAXShowMenuAction as NSString);        lua_setfield(L, -2, "showMenu")
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
    lua_newtable(L)
    lua_pushany(L, kAXApplicationRole as NSString);        lua_setfield(L, -2, "application")
    lua_pushany(L, kAXBrowserRole as NSString);            lua_setfield(L, -2, "browser")
    lua_pushany(L, kAXBusyIndicatorRole as NSString);      lua_setfield(L, -2, "busyIndicator")
    lua_pushany(L, kAXButtonRole as NSString);             lua_setfield(L, -2, "button")
    lua_pushany(L, kAXCellRole as NSString);               lua_setfield(L, -2, "cell")
    lua_pushany(L, kAXCheckBoxRole as NSString);           lua_setfield(L, -2, "checkBox")
    lua_pushany(L, kAXColorWellRole as NSString);          lua_setfield(L, -2, "colorWell")
    lua_pushany(L, kAXColumnRole as NSString);             lua_setfield(L, -2, "column")
    lua_pushany(L, kAXComboBoxRole as NSString);           lua_setfield(L, -2, "comboBox")
    lua_pushany(L, kAXDateFieldRole as NSString);          lua_setfield(L, -2, "dateField")
    lua_pushany(L, kAXDisclosureTriangleRole as NSString); lua_setfield(L, -2, "disclosureTriangle")
    lua_pushany(L, kAXDockItemRole as NSString);           lua_setfield(L, -2, "dockItem")
    lua_pushany(L, kAXDrawerRole as NSString);             lua_setfield(L, -2, "drawer")
    lua_pushany(L, kAXGridRole as NSString);               lua_setfield(L, -2, "grid")
    lua_pushany(L, kAXGroupRole as NSString);              lua_setfield(L, -2, "group")
    lua_pushany(L, kAXGrowAreaRole as NSString);           lua_setfield(L, -2, "growArea")
    lua_pushany(L, kAXHandleRole as NSString);             lua_setfield(L, -2, "handle")
    lua_pushany(L, kAXHelpTagRole as NSString);            lua_setfield(L, -2, "helpTag")
    lua_pushany(L, kAXImageRole as NSString);              lua_setfield(L, -2, "image")
    lua_pushany(L, kAXIncrementorRole as NSString);        lua_setfield(L, -2, "incrementor")
    lua_pushany(L, kAXLayoutAreaRole as NSString);         lua_setfield(L, -2, "layoutArea")
    lua_pushany(L, kAXLayoutItemRole as NSString);         lua_setfield(L, -2, "layoutItem")
    lua_pushany(L, kAXLevelIndicatorRole as NSString);     lua_setfield(L, -2, "levelIndicator")
    lua_pushany(L, kAXListRole as NSString);               lua_setfield(L, -2, "list")
    lua_pushany(L, kAXMatteRole as NSString);              lua_setfield(L, -2, "matteRole")
    lua_pushany(L, kAXMenuRole as NSString);               lua_setfield(L, -2, "menu")
    lua_pushany(L, kAXMenuBarRole as NSString);            lua_setfield(L, -2, "menuBar")
    lua_pushany(L, kAXMenuBarItemRole as NSString);        lua_setfield(L, -2, "menuBarItem")
    lua_pushany(L, kAXMenuButtonRole as NSString);         lua_setfield(L, -2, "menuButton")
    lua_pushany(L, kAXMenuItemRole as NSString);           lua_setfield(L, -2, "menuItem")
    lua_pushany(L, kAXOutlineRole as NSString);            lua_setfield(L, -2, "outline")
    lua_pushany(L, kAXPopoverRole as NSString);            lua_setfield(L, -2, "popover")
    lua_pushany(L, kAXPopUpButtonRole as NSString);        lua_setfield(L, -2, "popUpButton")
    lua_pushany(L, kAXProgressIndicatorRole as NSString);  lua_setfield(L, -2, "progressIndicator")
    lua_pushany(L, kAXRadioButtonRole as NSString);        lua_setfield(L, -2, "radioButton")
    lua_pushany(L, kAXRadioGroupRole as NSString);         lua_setfield(L, -2, "radioGroup")
    lua_pushany(L, kAXRelevanceIndicatorRole as NSString); lua_setfield(L, -2, "relevanceIndicator")
    lua_pushany(L, kAXRowRole as NSString);                lua_setfield(L, -2, "row")
    lua_pushany(L, kAXRulerRole as NSString);              lua_setfield(L, -2, "ruler")
    lua_pushany(L, kAXRulerMarkerRole as NSString);        lua_setfield(L, -2, "rulerMarker")
    lua_pushany(L, kAXScrollAreaRole as NSString);         lua_setfield(L, -2, "scrollArea")
    lua_pushany(L, kAXScrollBarRole as NSString);          lua_setfield(L, -2, "scrollBar")
    lua_pushany(L, kAXSheetRole as NSString);              lua_setfield(L, -2, "sheet")
    lua_pushany(L, kAXSliderRole as NSString);             lua_setfield(L, -2, "slider")
    lua_pushany(L, kAXSplitGroupRole as NSString);         lua_setfield(L, -2, "splitGroup")
    lua_pushany(L, kAXSplitterRole as NSString);           lua_setfield(L, -2, "splitter")
    lua_pushany(L, kAXStaticTextRole as NSString);         lua_setfield(L, -2, "staticText")
    lua_pushany(L, kAXSystemWideRole as NSString);         lua_setfield(L, -2, "systemWide")
    lua_pushany(L, kAXTabGroupRole as NSString);           lua_setfield(L, -2, "tabGroup")
    lua_pushany(L, kAXTableRole as NSString);              lua_setfield(L, -2, "table")
    lua_pushany(L, kAXTextAreaRole as NSString);           lua_setfield(L, -2, "textArea")
    lua_pushany(L, kAXTextFieldRole as NSString);          lua_setfield(L, -2, "textField")
    lua_pushany(L, kAXTimeFieldRole as NSString);          lua_setfield(L, -2, "timeField")
    lua_pushany(L, kAXToolbarRole as NSString);            lua_setfield(L, -2, "toolbar")
    lua_pushany(L, kAXUnknownRole as NSString);            lua_setfield(L, -2, "unknown")
    lua_pushany(L, kAXValueIndicatorRole as NSString);     lua_setfield(L, -2, "valueIndicator")
    lua_pushany(L, kAXWindowRole as NSString);             lua_setfield(L, -2, "window")

    lua_pushany(L, NSAccessibility.Role.link.rawValue as NSString);                        lua_setfield(L, -2, "link")
    lua_pushany(L, NSAccessibility.Role.pageRole.rawValue as NSString);                     lua_setfield(L, -2, "page")

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
    lua_newtable(L)
    lua_pushany(L, kAXApplicationDockItemSubrole as NSString);     lua_setfield(L, -2, "applicationDockItem")
    lua_pushany(L, kAXCloseButtonSubrole as NSString);             lua_setfield(L, -2, "closeButton")
    lua_pushany(L, kAXContentListSubrole as NSString);             lua_setfield(L, -2, "contentList")
    lua_pushany(L, kAXDecorativeSubrole as NSString);              lua_setfield(L, -2, "decorative")
    lua_pushany(L, kAXDecrementArrowSubrole as NSString);          lua_setfield(L, -2, "decrementArrow")
    lua_pushany(L, kAXDecrementPageSubrole as NSString);           lua_setfield(L, -2, "decrementPage")
    lua_pushany(L, NSAccessibility.Subrole.definitionList.rawValue as NSString);                   lua_setfield(L, -2, "definitionList")
    lua_pushany(L, kAXDescriptionListSubrole as NSString);         lua_setfield(L, -2, "descriptionList")
    lua_pushany(L, kAXDialogSubrole as NSString);                  lua_setfield(L, -2, "dialog")
    lua_pushany(L, kAXDockExtraDockItemSubrole as NSString);       lua_setfield(L, -2, "dockExtraDockItem")
    lua_pushany(L, kAXDocumentDockItemSubrole as NSString);        lua_setfield(L, -2, "documentDockItem")
    lua_pushany(L, kAXFloatingWindowSubrole as NSString);          lua_setfield(L, -2, "floatingWindow")
    lua_pushany(L, kAXFolderDockItemSubrole as NSString);          lua_setfield(L, -2, "folderDockItem")
    lua_pushany(L, kAXFullScreenButtonSubrole as NSString);        lua_setfield(L, -2, "fullScreenButton")
    lua_pushany(L, kAXIncrementArrowSubrole as NSString);          lua_setfield(L, -2, "incrementArrow")
    lua_pushany(L, kAXIncrementPageSubrole as NSString);           lua_setfield(L, -2, "incrementPage")
    lua_pushany(L, kAXMinimizeButtonSubrole as NSString);          lua_setfield(L, -2, "minimizeButton")
    lua_pushany(L, kAXMinimizedWindowDockItemSubrole as NSString); lua_setfield(L, -2, "minimizedWindowDockItem")
    lua_pushany(L, kAXOutlineRowSubrole as NSString);              lua_setfield(L, -2, "outlineRow")
    lua_pushany(L, kAXProcessSwitcherListSubrole as NSString);     lua_setfield(L, -2, "processSwitcherList")
    lua_pushany(L, kAXRatingIndicatorSubrole as NSString);         lua_setfield(L, -2, "ratingIndicator")
    lua_pushany(L, kAXSearchFieldSubrole as NSString);             lua_setfield(L, -2, "searchField")
    lua_pushany(L, kAXSecureTextFieldSubrole as NSString);         lua_setfield(L, -2, "secureTextField")
    lua_pushany(L, kAXSeparatorDockItemSubrole as NSString);       lua_setfield(L, -2, "separatorDockItem")
    lua_pushany(L, kAXSortButtonSubrole as NSString);              lua_setfield(L, -2, "sortButton")
    lua_pushany(L, kAXStandardWindowSubrole as NSString);          lua_setfield(L, -2, "standardWindow")
    lua_pushany(L, kAXSwitchSubrole as NSString);                  lua_setfield(L, -2, "switch")
    lua_pushany(L, kAXSystemDialogSubrole as NSString);            lua_setfield(L, -2, "systemDialog")
    lua_pushany(L, kAXSystemFloatingWindowSubrole as NSString);    lua_setfield(L, -2, "systemFloatingWindow")
    lua_pushany(L, kAXTableRowSubrole as NSString);                lua_setfield(L, -2, "tableRow")
    lua_pushany(L, NSAccessibility.Subrole.textAttachment.rawValue as NSString);                   lua_setfield(L, -2, "textAttachment")
    lua_pushany(L, NSAccessibility.Subrole.textLink.rawValue as NSString);                         lua_setfield(L, -2, "textLink")
    lua_pushany(L, kAXTimelineSubrole as NSString);                lua_setfield(L, -2, "timeline")
    lua_pushany(L, kAXToggleSubrole as NSString);                  lua_setfield(L, -2, "toggle")
    lua_pushany(L, kAXToolbarButtonSubrole as NSString);           lua_setfield(L, -2, "toolbarButton")
    lua_pushany(L, kAXTrashDockItemSubrole as NSString);           lua_setfield(L, -2, "trashDockItem")
    lua_pushany(L, kAXUnknownSubrole as NSString);                 lua_setfield(L, -2, "unknown")
    lua_pushany(L, kAXURLDockItemSubrole as NSString);             lua_setfield(L, -2, "URLDockItem")
    lua_pushany(L, kAXZoomButtonSubrole as NSString);              lua_setfield(L, -2, "zoomButton")

    lua_pushany(L, NSAccessibility.Subrole.collectionListSubrole.rawValue as NSString);             lua_setfield(L, -2, "collectionList")
    lua_pushany(L, NSAccessibility.Subrole.tabButtonSubrole.rawValue as NSString);                  lua_setfield(L, -2, "tabButton")
    lua_pushany(L, NSAccessibility.Subrole.sectionListSubrole.rawValue as NSString);                lua_setfield(L, -2, "sectionList")

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
    lua_newtable(L)
    lua_pushany(L, kAXHorizontalOrientationValue as NSString); lua_setfield(L, -2, "horizontal")
    lua_pushany(L, kAXVerticalOrientationValue as NSString);   lua_setfield(L, -2, "vertical")
    lua_pushany(L, kAXUnknownOrientationValue as NSString);    lua_setfield(L, -2, "unknown")
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
    lua_newtable(L)
    lua_pushany(L, kAXAscendingSortDirectionValue as NSString);  lua_setfield(L, -2, "ascending")
    lua_pushany(L, kAXDescendingSortDirectionValue as NSString); lua_setfield(L, -2, "descending")
    lua_pushany(L, kAXUnknownSortDirectionValue as NSString);    lua_setfield(L, -2, "unknown")
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
    lua_newtable(L)
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.centerTabStop.rawValue as NSString);   lua_setfield(L, -2, "centerTabStop")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.decimalTabStop.rawValue as NSString);  lua_setfield(L, -2, "decimalTabStop")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.firstLineIndent.rawValue as NSString); lua_setfield(L, -2, "firstLineIndent")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.headIndent.rawValue as NSString);      lua_setfield(L, -2, "headIndent")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.leftTabStop.rawValue as NSString);     lua_setfield(L, -2, "leftTabStop")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.rightTabStop.rawValue as NSString);    lua_setfield(L, -2, "rightTabStop")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.tailIndent.rawValue as NSString);      lua_setfield(L, -2, "tailIndent")
    lua_pushany(L, NSAccessibility.RulerMarkerTypeValue.unknown.rawValue as NSString);         lua_setfield(L, -2, "unknown")
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
    lua_newtable(L)
    lua_pushany(L, NSAccessibility.RulerUnitValue.centimeters.rawValue as NSString); lua_setfield(L, -2, "centimeters")
    lua_pushany(L, NSAccessibility.RulerUnitValue.inches.rawValue as NSString);      lua_setfield(L, -2, "inches")
    lua_pushany(L, NSAccessibility.RulerUnitValue.picas.rawValue as NSString);       lua_setfield(L, -2, "picas")
    lua_pushany(L, NSAccessibility.RulerUnitValue.points.rawValue as NSString);      lua_setfield(L, -2, "points")
    lua_pushany(L, NSAccessibility.RulerUnitValue.unknown.rawValue as NSString);     lua_setfield(L, -2, "unknown")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
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
    lua_pushany(L, NSString(format: "%s: %@ (%@)", USERDATA_TAG, title, ptrStr as NSString))
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    let _ = get_axuielementref(L, 1, USERDATA_TAG)
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    let theRef1 = get_axuielementref(L, 1, USERDATA_TAG)
    let theRef2 = get_axuielementref(L, 2, USERDATA_TAG)
    lua_pushboolean(L, CFEqual(theRef1, theRef2) ? 1 : 0)
    return 1
}

@_cdecl("luaopen_hs_libaxuielement")
public func luaopen_hs_libaxuielement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(axuielement_getAttributeNames);              lua_setfield(L, -2, "attributeNames")
        L.push(axuielement_getAllAttributeValues);           lua_setfield(L, -2, "allAttributeValues")
        L.push(axuielement_getParameterizedAttributeNames);  lua_setfield(L, -2, "parameterizedAttributeNames")
        L.push(axuielement_getActionNames);                  lua_setfield(L, -2, "actionNames")
        L.push(axuielement_getActionDescription);            lua_setfield(L, -2, "actionDescription")
        L.push(axuielement_getAttributeValue);               lua_setfield(L, -2, "attributeValue")
        L.push(axuielement_getParameterizedAttributeValue);  lua_setfield(L, -2, "parameterizedAttributeValue")
        L.push(axuielement_getAttributeValueCount);          lua_setfield(L, -2, "attributeValueCount")
        L.push(axuielement_isAttributeSettable);             lua_setfield(L, -2, "isAttributeSettable")
        L.push(axuielement_getPid);                          lua_setfield(L, -2, "pid")
        L.push(axuielement_performAction);                   lua_setfield(L, -2, "performAction")
        L.push(axuielement_getElementAtPosition);            lua_setfield(L, -2, "elementAtPosition")
        L.push(axuielement_setAttributeValue);               lua_setfield(L, -2, "setAttributeValue")
        L.push(axuielement_toHSWindow);                      lua_setfield(L, -2, "asHSWindow")
        L.push(axuielement_toHSApplication);                 lua_setfield(L, -2, "asHSApplication")
        L.push(axuielement_duplicateReference);              lua_setfield(L, -2, "copy")
        L.push(axuielement_setTimeout);                      lua_setfield(L, -2, "setTimeout")
        L.push(axuielement_isValid);                         lua_setfield(L, -2, "isValid")
        L.push(userdata_tostring);                           lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq);                                 lua_setfield(L, -2, "__eq")
        L.push(userdata_gc);                                 lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(axuielement_getSystemWideElement);        lua_setfield(L, -2, "systemWideElement")
        L.push(axuielement_getWindowElement);            lua_setfield(L, -2, "windowElement")
        L.push(axuielement_getApplicationElement);       lua_setfield(L, -2, "applicationElement")
        L.push(axuielement_getApplicationElementForPID); lua_setfield(L, -2, "applicationElementForPID")

        luaopen_hs_libaxuielementobserver(L); lua_setfield(L, -2, "observer")
        luaopen_hs_axuielement_axtextmarker(L); lua_setfield(L, -2, "axtextmarker")

        axuielement_pushAttributesTable(L);              lua_setfield(L, -2, "attributes")
        axuielement_pushParameterizedAttributesTable(L); lua_setfield(L, -2, "parameterizedAttributes")
        axuielement_pushActionsTable(L);                 lua_setfield(L, -2, "actions")
        axuielement_pushRolesTable(L);                   lua_setfield(L, -2, "roles")
        axuielement_pushSubrolesTable(L);                lua_setfield(L, -2, "subroles")
        axuielement_pushSortDirectionsTable(L);          lua_setfield(L, -2, "sortDirections")
        axuielement_pushOrientationsTable(L);            lua_setfield(L, -2, "orientations")
        axuielement_pushRulerMarkerTypesTable(L);        lua_setfield(L, -2, "rulerMarkers")
        axuielement_pushUnitsTable(L);                   lua_setfield(L, -2, "units")
    }
}
