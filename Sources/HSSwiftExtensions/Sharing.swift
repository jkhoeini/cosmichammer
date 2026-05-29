import Cocoa
import CLua
import os.log

private let USERDATA_TAG = "hs.sharing"
private var refTable: Int32 = LUA_NOREF

private func get_objectFromUserdata<T: AnyObject>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    return Unmanaged<T>.fromOpaque(ptr.pointee).takeUnretainedValue()
}

// MARK: - Support Functions and Classes

private func toNSURLFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSURL? {
    let absIdx = lua_absindex(L, idx)

    if lua_type(L, absIdx) == LUA_TSTRING {
        let str = lua_tovalue(L, at: absIdx) as! String
        return NSURL(string: str)
    } else if lua_type(L, absIdx) == LUA_TTABLE {
        if lua_getfield(L, absIdx, "url") == LUA_TSTRING {
            let str = lua_tovalue(L, at: -1) as! String
            lua_pop(L, 1)
            return NSURL(string: str)
        }
        lua_pop(L, 1)
    }

    os_log(.error, "%{public}s", "expected string or table describing an NSURL, found \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
    return nil
}

// MARK: - HSSharingService

class HSSharingService: NSObject, NSSharingServiceDelegate {
    var sharingService: NSSharingService?
    var callbackRef: Int32 = LUA_NOREF
    var selfRefCount: Int = 0

    init(serviceName: String) {
        super.init()
        sharingService = NSSharingService(named: NSSharingService.Name(rawValue: serviceName))
        if sharingService != nil {
            sharingService!.delegate = self
        }
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard callbackRef != LUA_NOREF else { return }
        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        lua_pushany(L, self)
        lua_pushany(L, "didFail" as NSString)
        lua_pushany(L, items as NSArray)
        lua_pushany(L, error.localizedDescription as NSString)
        if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard callbackRef != LUA_NOREF else { return }
        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        lua_pushany(L, self)
        lua_pushany(L, "didShare" as NSString)
        lua_pushany(L, items as NSArray)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        guard callbackRef != LUA_NOREF else { return }
        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        lua_pushany(L, self)
        lua_pushany(L, "willShare" as NSString)
        lua_pushany(L, items as NSArray)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
}

// MARK: - Module Functions

/// hs.sharing.newShare(type) -> sharingObject
/// Constructor
/// Creates a new sharing object of the type specified by the identifier provided.
///
/// Parameters:
///  * type - a string specifying a sharing type identifier as listed in the [hs.sharing.builtinSharingServices](#builtinSharingServices) table or returned by the [hs.sharing.shareTypesFor](#shareTypesFor).
///
/// Returns:
///  * a sharingObject or nil if the type identifier cannot be created on this system
private func sharing_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    let serviceName = lua_tovalue(L, at: 1) as! String
    let wrapper = HSSharingService(serviceName: serviceName)

    if wrapper.sharingService != nil {
        lua_pushany(L, wrapper)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sharing.shareTypesFor(items) -> identifiersTable
/// Function
/// Returns a table containing the sharing service identifiers which can share the items specified.
///
/// Parameters:
///  * items - an array (table) or list of items separated by commas which you wish to share with this module.
///
/// Returns:
///  * an array (table) containing strings which identify sharing service identifiers which may be used by the [hs.sharing.newShare](#newShare) constructor to share the specified data.
///
/// Notes:
///  * this function is intended to be used to determine the identifiers for sharing services available on your computer and that may not be included in the [hs.sharing.builtinSharingServices](#builtinSharingServices) table.
private func sharing_servicesForItems(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    var items: [Any]?
    if lua_gettop(L) == 1 {
        guard let arr = lua_tovalue(L, at: 1) as? [Any] else {
            return luaL_argerror(L, 1, "unrecognized element in array")
        }
        items = arr
    }

    lua_newtable(L)
    let services = NSSharingService.sharingServices(forItems: items ?? [])
    for aService in services {
        var label: String?
        // The internal "name" property can be used with sharingServiceNamed: but Apple hid it
        if aService.responds(to: NSSelectorFromString("name")) {
            label = aService.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String
        }
        if label == nil { label = aService.title }
        lua_pushany(L, (label ?? "") as NSString)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

/// hs.sharing.URL(URL, [fileURL]) -> table
/// Function
/// Returns a table representing the URL specified.
///
/// Parameters:
///  * URL     - a string or table specifying the URL.
///  * fileURL - an optional boolean, default `false`, specifying whether or not the URL is supposed to represent a file on the local computer.
///
/// Returns:
///  * a table containing the necessary labels for representing the specified URL as required by the macOS APIs.
///
/// Notes:
///  * If the URL is specified as a table, it is expected to contain a `url` key with a string value specifying a proper schema and resource locator.
///
///  * Because macOS requires URLs to be represented as a specific object type which has no exact equivalent in Lua, Cosmic Hammer uses a table with specific keys to allow proper identification of a URL when included as an argument or result type.  Use this function or the [hs.sharing.fileURL](#fileURL) wrapper function when specifying a URL to ensure that the proper keys are defined.
///  * At present, the following keys are defined for a URL table (additional keys may be added in the future if future Cosmic Hammer modules require them to more completely utilize the macOS NSURL class, but these will not change):
///    * url           - a string containing the URL with a proper schema and resource locator
///    * filePath      = a string specifying the actual path to the file in case the url is a file reference URL.  Note that setting this field with this method will be silently ignored; the field is automatically inserted if appropriate when returning an NSURL object to lua.
///    * __luaSkinType - a string specifying the macOS type this table represents when converted into an Objective-C type
private func sharing_makeURL(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let shouldBeFileURL = lua_gettop(L) == 2 ? (lua_toboolean(L, 2) != 0) : false

    var theURL: NSURL?
    if shouldBeFileURL && lua_type(L, 1) == LUA_TSTRING {
        let path = lua_tovalue(L, at: 1) as! String
        if !path.hasPrefix("file:") && !path.hasPrefix("FILE:") {
            theURL = NSURL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
    }

    if theURL == nil {
        theURL = toNSURLFromLua(L, 1)
    }

    if let url = theURL {
        lua_pushany(L, url)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Module Methods

/// hs.sharing:shareItems(items) -> sharingObject
/// Method
/// Shares the items specified with the sharing service represented by the sharingObject.
///
/// Parameters:
///  * items - an array (table) or list of items separated by commas which are to be shared by the sharing service
///
/// Returns:
///  * the sharingObject, or nil if one or more of the items cannot be shared with the sharing service represented by the sharingObject.
///
/// Notes:
///  * You can check to see if all of your items can be shared with the [hs.sharing:canShareItems](#canShareItems) method.
private func sharing_performWith(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)

    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService

    guard let items = lua_tovalue(L, at: 2) as? [Any] else {
        return luaL_argerror(L, 2, "unrecognized element in array")
    }

    if wrapper.sharingService?.canPerform(withItems:items) ?? false {
        wrapper.sharingService?.perform(withItems: items)
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sharing:canShareItems(items) -> boolean
/// Method
/// Returns a boolean specifying whether or not all of the items specified can be shared with the sharing service represented by the sharingObject.
///
/// Parameters:
///  * items - an array (table) or list of items separated by commas which are to be shared by the sharing service
///
/// Returns:
///  * a boolean value indicating whether or not all of the specified items can be shared with the sharing service represented by the sharingObject.
private func sharing_canPerformWith(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)

    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService

    guard let items = lua_tovalue(L, at: 2) as? [Any] else {
        return luaL_argerror(L, 2, "unrecognized element in array")
    }

    lua_pushboolean(L, (wrapper.sharingService?.canPerform(withItems:items) ?? false) ? 1 : 0)
    return 1
}

/// hs.sharing:callback(fn) -> sharingObject
/// Method
/// Set or clear the callback for the sharingObject.
///
/// Parameters:
///  * fn - A function, or nil, to set or remove the callback for the sharingObject
///
/// Returns:
///  * the sharingObject
///
/// Notes:
///  * the callback should expect 3 or 4 arguments and return no results.  The arguments will be as follows:
///    * the sharingObject itself
///    * the callback message, which will be a string equal to one of the following:
///      * "didFail"   - an error occurred while attempting to share the items
///      * "didShare"  - the sharing service has finished sharing the items
///      * "willShare" - the sharing service is about to start sharing the items; occurs before sharing actually begins
///    * an array (table) containing the items being shared; if the message is "didFail" or "didShare", the items may be in a different order or converted to a different internal type to facilitate sharing.
///    * if the message is "didFail", the fourth argument will be a localized description of the error that occurred.
private func sharing_callback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, wrapper.callbackRef)


    wrapper.callbackRef = LUA_NOREF
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        wrapper.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.sharing:recipients([recipients]) -> current value | sharingObject
/// Method
/// Get or set the subject to be used when the sharing service performs its sharing method.
///
/// Parameters:
///  * recipients - an optional array (table) or list of recipient strings separated by commas which specify the recipients of the shared items.
///
/// Returns:
///  * if an argument is provided, returns the sharingObject; otherwise returns the current value.
///
/// Notes:
///  * not all sharing services will make use of the value set by this method.
///  * the individual recipients should be specified as strings in the format expected by the sharing service; e.g. for items being shared in an email, the recipients should be email address, etc.
private func sharing_recipients(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService

    if lua_gettop(L) == 1 {
        lua_pushany(L, wrapper.sharingService?.recipients as NSArray?)
    } else {
        guard let recipients = lua_tovalue(L, at: 2) as? [Any] else {
            return luaL_argerror(L, 2, "expected table of strings")
        }

        var errorMessage: String?
        for (idx, obj) in recipients.enumerated() {
            if !(obj is String) {
                errorMessage = "expected string at index \(idx + 1)"
                break
            }
        }

        if let msg = errorMessage {
            return luaL_argerror(L, 2, msg)
        } else {
            wrapper.sharingService?.recipients = recipients as? [String]
            lua_pushvalue(L, 1)
        }
    }
    return 1
}

/// hs.sharing:subject([subject]) -> current value | sharingObject
/// Method
/// Get or set the subject to be used when the sharing service performs its sharing method.
///
/// Parameters:
///  * subject - an optional string specifying the subject for the posting of the shared content
///
/// Returns:
///  * if an argument is provided, returns the sharingObject; otherwise returns the current value.
///
/// Notes:
///  * not all sharing services will make use of the value set by this method.
private func sharing_subject(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService

    if lua_gettop(L) == 1 {
        if let subject = wrapper.sharingService?.subject {
            lua_pushany(L, subject as NSString)
        } else {
            lua_pushnil(L)
        }
    } else {
        wrapper.sharingService?.subject = lua_tovalue(L, at: 2) as? String
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.sharing:attachments() -> table | nil
/// Method
/// If the sharing service provides an array of the attachments included when the data was posted, this method will return an array of file URL tables of the attachments.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array (table) containing the attachment file URLs, or nil if the sharing service selected does not provide this.
///
/// Notes:
///  * not all sharing services will set a value for this property.
private func sharing_attachmentURLs(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    lua_pushany(L, wrapper.sharingService?.attachmentFileURLs as NSArray?)
    return 1
}

/// hs.sharing:accountName() -> string | nil
/// Method
/// The account name used by the sharing service when posting on Twitter or Sina Weibo.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the account name used by the sharing service, or nil if the sharing service does not provide this.
///
/// Notes:
///  * According to the Apple API documentation, only the Twitter and Sina Weibo sharing services will set this property, but this has not been fully tested.
private func sharing_accountName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    if let name = wrapper.sharingService?.accountName {
        lua_pushany(L, name as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sharing:messageBody() -> string | nil
/// Method
/// If the sharing service provides the message body that was posted when sharing has completed, this method will return the message body as a string.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the message body, or nil if the sharing service selected does not provide this.
///
/// Notes:
///  * not all sharing services will set a value for this property.
private func sharing_messageBody(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    if let body = wrapper.sharingService?.messageBody {
        lua_pushany(L, body as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sharing:title() -> string
/// Method
/// The title for the sharing service represented by the sharingObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the title of the sharing service.
///
/// Notes:
///  * this string differs from the identifier used to create the sharing service object with [hs.sharing.newShare](#newShare) and is intended to provide a more friendly label for the service if you need to list or refer to it elsewhere.
private func sharing_title(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    lua_pushany(L, wrapper.sharingService?.title as NSString?)
    return 1
}

/// hs.sharing:serviceName() -> string
/// Method
/// The service identifier for the sharing service represented by the sharingObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the identifier for the sharing service.
///
/// Notes:
///  * this string will match the identifier used to create the sharing service object with [hs.sharing.newShare](#newShare)
private func sharing_serviceName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService

    var label: String?
    // Apple hid the "name" property, but it returns the identifier usable with sharingServiceNamed:
    if let service = wrapper.sharingService, service.responds(to: NSSelectorFromString("name")) {
        label = service.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String
    }

    if let l = label {
        lua_pushany(L, l as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.sharing:permanentLink() -> URL table | nil
/// Method
/// If the sharing service provides a permanent link to the post when sharing has completed, this method will return the corresponding URL.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the URL for the permanent link, or nil if the sharing service selected does not provide this.
///
/// Notes:
///  * not all sharing services will set a value for this property.
private func sharing_permanentLink(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    lua_pushany(L, wrapper.sharingService?.permanentLink as NSURL?)
    return 1
}

/// hs.sharing:alternateImage() -> hs.image object | nil
/// Method
/// Returns an alternate image, if one exists, representing the sharing service provided by this sharing object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an hs.image object or nil, if no alternate image representation for the sharing service is defined.
private func sharing_alternateImage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    lua_pushany(L, wrapper.sharingService?.alternateImage)
    return 1
}

/// hs.sharing:image() -> hs.image object | nil
/// Method
/// Returns an image, if one exists, representing the sharing service provided by this sharing object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an hs.image object or nil, if no image representation for the sharing service is defined.
private func sharing_image(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let wrapper: HSSharingService = lua_tovalue(L, at: 1) as! HSSharingService
    lua_pushany(L, wrapper.sharingService?.image)
    return 1
}

// MARK: - Module Constants

private func pushBuiltinSharingServices(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushany(L, NSSharingService.Name.addToAperture.rawValue as NSString);             lua_setfield(L, -2, "addToAperture")
    lua_pushany(L, NSSharingService.Name.addToIPhoto.rawValue as NSString);               lua_setfield(L, -2, "addToIPhoto")
    lua_pushany(L, NSSharingService.Name.addToSafariReadingList.rawValue as NSString);    lua_setfield(L, -2, "addToSafariReadingList")
    lua_pushany(L, NSSharingService.Name.composeEmail.rawValue as NSString);              lua_setfield(L, -2, "composeEmail")
    lua_pushany(L, NSSharingService.Name.composeMessage.rawValue as NSString);            lua_setfield(L, -2, "composeMessage")
    lua_pushany(L, NSSharingService.Name.sendViaAirDrop.rawValue as NSString);            lua_setfield(L, -2, "sendViaAirDrop")
    lua_pushany(L, NSSharingService.Name.useAsDesktopPicture.rawValue as NSString);       lua_setfield(L, -2, "useAsDesktopPicture")
    return 1
}

// MARK: - Lua<->NSObject Conversion

private func pushHSSharingService(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let value = obj as! HSSharingService
    value.selfRefCount += 1
    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    ptr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSSharingServiceFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return get_objectFromUserdata(L, idx, USERDATA_TAG) as HSSharingService
    } else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
}

private func pushNSURL(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let url = obj as! NSURL
    lua_newtable(L)
    lua_pushany(L, url.absoluteString as NSString?)
    lua_setfield(L, -2, "url")
    if url.isFileURL {
        lua_pushany(L, url.path as NSString?)
        lua_setfield(L, -2, "filePath")
    }
    lua_pushstring(L, "NSURL")
    lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func toNSURLFromLuaHelper(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    return toNSURLFromLua(L, idx)
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let obj = lua_tovalue(L, at: 1) as! HSSharingService
    let title = obj.sharingService?.title ?? "unknown"
    lua_pushany(L, "\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let obj1 = lua_tovalue(L, at: 1) as! HSSharingService
        let obj2 = lua_tovalue(L, at: 2) as! HSSharingService
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let obj = Unmanaged<HSSharingService>.fromOpaque(ptr.pointee).takeRetainedValue()

    obj.selfRefCount -= 1
    if obj.selfRefCount == 0 {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.callbackRef)

        obj.callbackRef = LUA_NOREF
        obj.sharingService = nil
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - luaL_Reg tables

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("callback"), func: sharing_callback),
    luaL_Reg(name: strdup("recipients"), func: sharing_recipients),
    luaL_Reg(name: strdup("subject"), func: sharing_subject),
    luaL_Reg(name: strdup("shareItems"), func: sharing_performWith),
    luaL_Reg(name: strdup("canShareItems"), func: sharing_canPerformWith),
    luaL_Reg(name: strdup("attachments"), func: sharing_attachmentURLs),
    luaL_Reg(name: strdup("accountName"), func: sharing_accountName),
    luaL_Reg(name: strdup("messageBody"), func: sharing_messageBody),
    luaL_Reg(name: strdup("title"), func: sharing_title),
    luaL_Reg(name: strdup("permanentLink"), func: sharing_permanentLink),
    luaL_Reg(name: strdup("alternateImage"), func: sharing_alternateImage),
    luaL_Reg(name: strdup("image"), func: sharing_image),
    luaL_Reg(name: strdup("serviceName"), func: sharing_serviceName),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("newShare"), func: sharing_new),
    luaL_Reg(name: strdup("shareTypesFor"), func: sharing_servicesForItems),
    luaL_Reg(name: strdup("URL"), func: sharing_makeURL),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libsharing")
public func luaopen_hs_libsharing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    _ = pushBuiltinSharingServices(L)
    lua_setfield(L, -2, "builtinSharingServices")

    return 1
}
