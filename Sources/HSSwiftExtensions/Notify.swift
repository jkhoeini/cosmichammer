import Cocoa
import LuaSkin

// NSUserNotification and its relations are deprecated but we're not ready to switch quite yet...

// MARK: - Constants

let nt_USERDATA_TAG = "hs.notify"
var nt_refTable: LSRefTable = LUA_NOREF

// changes made to userInfo dictionary in userNotificationCenter:didDeliverNotification: are not
// kept (is notification object a copy?) so we can't update delivered if it's in that particular
// dictionary... track it in here instead, keyed to unique id added when created (see new).
var nt_specifics: NSMutableDictionary!

let KEY_LOCKED        = "locked"
let KEY_ID            = "gus"
let KEY_WITHDRAWAFTER = "withdrawAfter"
let KEY_FNTAG         = "fntag"
let KEY_ALWAYSPRESENT = "alwaysPresent"
let KEY_AUTOWITHDRAW  = "autoWithdraw"
let KEY_SELFREFCOUNT  = "selfRefCount"
let KEY_DELIVERED     = "delivered"

var nt_old_delegate: NSUserNotificationCenterDelegate?

// MARK: - Support Functions and Classes

class HSModuleNotificationManager: NSObject, NSUserNotificationCenterDelegate {
    static let shared = HSModuleNotificationManager()

    // Notification delivered to Notification Center
    func userNotificationCenter(_ center: NSUserNotificationCenter, didDeliver notification: NSUserNotification) {
        // if it's ours, we've copied the necessary info into the userInfo dictionary...
        guard let gus = notification.userInfo?[KEY_ID] as? String else { return }

        // however we *might* need to recreate the local record so we can update KEY_DELIVERED
        if nt_specifics[gus] == nil {
            nt_specifics[gus] = (notification.userInfo! as NSDictionary).mutableCopy()
        }
        let userInfo = nt_specifics[gus] as! NSMutableDictionary
        userInfo[KEY_DELIVERED] = true

        let withdrawAfter = (userInfo[KEY_WITHDRAWAFTER] as? NSNumber)?.doubleValue ?? 0.0

        if withdrawAfter > 0 {
            center.perform(#selector(NSUserNotificationCenter.removeDeliveredNotification(_:)),
                           with: notification,
                           afterDelay: withdrawAfter)
        }
    }

    // User clicked on notification...
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        // if it's ours, we've copied the necessary info into the userInfo dictionary...
        guard let gus = notification.userInfo?[KEY_ID] as? String else {
            LuaSkin.skin(with: nil).logError("\(nt_USERDATA_TAG) passing off to original handler")
            if let delegate = nt_old_delegate, delegate.responds(to: #selector(NSUserNotificationCenterDelegate.userNotificationCenter(_:didActivate:))) {
                delegate.userNotificationCenter?(center, didActivate: notification)
            }
            return
        }

        // however we *might* need to recreate the local record so we can update KEY_DELIVERED
        if nt_specifics[gus] == nil {
            nt_specifics[gus] = (notification.userInfo! as NSDictionary).mutableCopy()
        }
        let userInfo = nt_specifics[gus] as! NSMutableDictionary
        userInfo[KEY_DELIVERED] = true // just in case its a holdover from before a reload/relaunch

        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!

        _lua_stackguard_entry(L)
        if !skin.requireModule(nt_USERDATA_TAG) {
            skin.logError("\(nt_USERDATA_TAG):_didActivateNotification - unable to load tag handler: \(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1) // remove error message
            _lua_stackguard_exit(L)
            return
        }
        lua_getfield(L, -1, "_tag_handler") // now we know the function hs.notify._tag_handler is on the stack...
        skin.pushNSObject(userInfo[KEY_FNTAG])
        skin.pushNSObject(notification)

        if !skin.protectedCallAndError("\(nt_USERDATA_TAG) callback", nargs: 2, nresults: 0) {
            lua_pop(L, 1) // pop the hs.notify module
            _lua_stackguard_exit(L)
            return
        }
        lua_pop(L, 1) // pop the hs.notify module

        let shouldWithdraw: Bool
        if notification.deliveryRepeatInterval != nil {
            shouldWithdraw = true
        } else {
            shouldWithdraw = (userInfo[KEY_AUTOWITHDRAW] as? NSNumber)?.boolValue ?? true
        }

        if shouldWithdraw {
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
            NSUserNotificationCenter.default.removeScheduledNotification(notification)
        }
        _lua_stackguard_exit(skin.l)
    }

    // Should notification show, even if we're the foremost application?
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        // if it's ours, we've copied the necessary info into the userInfo dictionary...
        if let shouldPresent = notification.userInfo?[KEY_ALWAYSPRESENT] as? NSNumber {
            return shouldPresent.boolValue
        } else { // MJNotificationManager just returns YES, so this is simpler.
            return true
        }
    }
}

func nt_delegate_setup() {
    // Get and store old (core app) delegate. If it hasn't been setup yet, do so.
    nt_old_delegate = NSUserNotificationCenter.default.delegate
    if nt_old_delegate == nil {
        _ = MJUserNotificationManager.sharedManager
        nt_old_delegate = NSUserNotificationCenter.default.delegate
    }
    // Create our delegate
    NSUserNotificationCenter.default.delegate = HSModuleNotificationManager.shared
}

func nt_date_from_string(_ dateString: String) -> Date? {
    // rfc3339 (Internet Date/Time) formatted date. More or less.
    let rfc3339DateFormatter = DateFormatter()
    rfc3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
    rfc3339DateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    rfc3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    return rfc3339DateFormatter.date(from: dateString)
}

// MARK: - Helper: get_objectFromUserdata

func nt_getNotification(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSUserNotification {
    let ptr = luaL_checkudata(L, idx, nt_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    return Unmanaged<NSUserNotification>.fromOpaque(ptr.pointee!).takeUnretainedValue()
}

// MARK: - Module Functions

/// hs.notify.withdrawAll()
/// Function
/// Withdraw all delivered notifications from Cosmic Hammer
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
///
/// Notes:
///  * This will withdraw all notifications for Cosmic Hammer, including those not sent by this module or that linger from a previous load of Cosmic Hammer.
let notification_withdraw_all: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    NSUserNotificationCenter.default.removeAllDeliveredNotifications()
    return 0
}

/// hs.notify.withdrawAllScheduled()
/// Function
/// Withdraw all scheduled notifications from Cosmic Hammer
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
let notification_withdraw_allScheduled: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    NSUserNotificationCenter.default.scheduledNotifications = []
    return 0
}

/// hs.notify.deliveredNotifications() -> table
/// Function
/// Returns a table containing notifications which have been delivered.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the notification userdata objects for all Cosmic Hammer notifications currently in the notification center
///
/// Notes:
///  * Only notifications which have been presented but not cleared, either by the user clicking on the [hs.notify:otherButtonTitle](#otherButtonTitle) or through auto-withdrawal (see [hs.notify:autoWithdraw](#autoWithdraw) for more details), will be in the array returned.
///
///  * You can use this function along with [hs.notify:getFunctionTag](#getFunctionTag) to re=register necessary callback functions with [hs.notify.register](#register) when Cosmic Hammer is restarted.
///
///  * Since notifications which the user has closed (or cancelled) do not trigger a callback, you can check this table with a timer to see if the user has cleared a notification, e.g.
/// ~~~lua
/// myNotification = hs.notify.new():send()
/// clearCheck = hs.timer.doEvery(10, function()
///     if not hs.fnutils.contains(hs.notify.deliveredNotifications(), myNotification) then
///         if myNotification:activationType() == hs.notify.activationTypes.none then
///             print("You dismissed me!")
///         else
///             print("A regular action occurred, so callback (if any) was invoked")
///         end
///         clearCheck:stop() -- either way, no need to keep polling
///         clearCheck = nil
///     end
/// end)
/// ~~~
let notification_deliveredNotifications: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    let deliveredNotifications = NSUserNotificationCenter.default.deliveredNotifications

    skin.pushNSObject(deliveredNotifications as NSArray)
    // just in case pushNSUserNotification had to recreate our entries in nt_specifics
    for notification in deliveredNotifications {
        if let gus = notification.userInfo?[KEY_ID] as? String {
            if let userInfo = nt_specifics[gus] as? NSMutableDictionary {
                userInfo[KEY_DELIVERED] = true
            }
        }
    }
    return 1
}

/// hs.notify.scheduledNotifications() -> table
/// Function
/// Returns a table containing notifications which are scheduled but have not yet been delivered.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the notification userdata objects for all Cosmic Hammer notifications currently scheduled to be delivered.
///
/// Notes:
///  * Once a notification has been delivered, it is moved to [hs.notify.deliveredNotifications](#deliveredNotifications) or removed, depending upon the users action.
///
///  * You can use this function along with [hs.notify:getFunctionTag](#getFunctionTag) to re=register necessary callback functions with [hs.notify.register](#register) when Cosmic Hammer is restarted.
let notification_scheduledNotifications: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(NSUserNotificationCenter.default.scheduledNotifications as NSArray)
    return 1
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
// hs.notify._new(fntag) -> notificationObject
// Constructor
// Returns a new notification object with the specified information and the assigned callback function.
let notification_new: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let gus = ProcessInfo.processInfo.globallyUniqueString

    let userInfo: NSMutableDictionary = [
        KEY_LOCKED:        false,
        KEY_ID:            gus,
        KEY_WITHDRAWAFTER: 0.0,
        KEY_FNTAG:         skin.toNSObject(atIndex: 1)!,
        KEY_ALWAYSPRESENT: true,
        KEY_AUTOWITHDRAW:  true,
        KEY_SELFREFCOUNT:  0,
        KEY_DELIVERED:     false,
    ]

    nt_specifics[gus] = userInfo

    let notification = NSUserNotification()
    notification.userInfo = [KEY_ID: gus]
    notification.hasActionButton = false

    skin.pushNSObject(notification)
    return 1
}

// Module Methods -> NotifyMethods.swift

// MARK: - Module Constants

func nt_activationTypesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
/// hs.notify.activationTypes[]
/// Constant
/// Convenience array of the possible activation types for a notification, and their reverse for reference.
/// * None                    - The user has not interacted with the notification.
/// * ContentsClicked         - User clicked on notification
/// * ActionButtonClicked     - User clicked on Action button
/// * Replied                 - User used Reply button
/// * AdditionalActionClicked - Additional Action selected
///
/// Notes:
///  * Count starts at zero. (implemented in Objective-C)
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NSUserNotification.ActivationType.none.rawValue))
    lua_setfield(L, -2, "none")
    lua_pushinteger(L, lua_Integer(NSUserNotification.ActivationType.contentsClicked.rawValue))
    lua_setfield(L, -2, "contentsClicked")
    lua_pushinteger(L, lua_Integer(NSUserNotification.ActivationType.actionButtonClicked.rawValue))
    lua_setfield(L, -2, "actionButtonClicked")
    lua_pushinteger(L, lua_Integer(NSUserNotification.ActivationType.replied.rawValue))
    lua_setfield(L, -2, "replied")
    lua_pushinteger(L, lua_Integer(NSUserNotification.ActivationType.additionalActionClicked.rawValue))
    lua_setfield(L, -2, "additionalActionClicked")
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

func nt_pushNSUserNotification(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let value = obj as! NSUserNotification

    if let userInfoDict = value.userInfo {
        if let gus = userInfoDict[KEY_ID] as? String {
            if let userInfo = nt_specifics[gus] as? NSMutableDictionary {
                let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                userInfo[KEY_SELFREFCOUNT] = NSNumber(value: selfRefCount + 1)
            } else {
                if userInfoDict[KEY_DELIVERED] != nil { // it's a holdover from a reload/relaunch
                    nt_specifics[gus] = (userInfoDict as NSDictionary).mutableCopy()
                    let userInfo = nt_specifics[gus] as! NSMutableDictionary
                    userInfo[KEY_SELFREFCOUNT] = NSNumber(value: 1)
                }
            }
        } // else not ours -- how does it exist?
    } // else not ours (probably from core app)
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, nt_USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

func nt_toNSUserNotificationFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, nt_USERDATA_TAG) != nil {
        return nt_getNotification(L, idx)
    } else {
        skin.logError("expected \(nt_USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))!))")
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

let nt_userdata_tostring: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at: 1, toClass: "NSUserNotification") as! NSUserNotification
    let title = obj.title ?? ""
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject(NSString(string: "\(nt_USERDATA_TAG): \(title) (\(String(describing: ptr)))"))
    return 1
}

let nt_userdata_eq: lua_CFunction = { L in
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, nt_USERDATA_TAG) != nil && luaL_testudata(L, 2, nt_USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "NSUserNotification") as! NSUserNotification
        let obj2 = skin.luaObject(at: 2, toClass: "NSUserNotification") as! NSUserNotification
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

let nt_userdata_gc: lua_CFunction = { L in
    let ptr = luaL_checkudata(L, 1, nt_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<NSUserNotification>.fromOpaque(rawPtr).takeRetainedValue()

        if let userInfoDict = obj.userInfo {
            if let gus = userInfoDict[KEY_ID] as? String { // it's ours
                if let userInfo = nt_specifics[gus] as? NSMutableDictionary { // and we have a record for it
                    let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                    userInfo[KEY_SELFREFCOUNT] = NSNumber(value: selfRefCount - 1)
                    if selfRefCount == 0 {
                        nt_specifics[gus] = nil
                    }
                }
            }
        }
        ptr.pointee = nil
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metamethods for the module
let nt_meta_gc: lua_CFunction = { _ in
    NSUserNotificationCenter.default.delegate = nt_old_delegate
    nt_specifics.removeAllObjects()
    nt_specifics = nil
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = {
    var lib: [luaL_Reg] = [
        luaL_Reg(name: strdup("send"),                        func: notification_send),
        luaL_Reg(name: strdup("schedule"),                    func: notification_scheduleNotification),
        luaL_Reg(name: strdup("withdraw"),                    func: notification_withdraw),
        luaL_Reg(name: strdup("title"),                       func: notification_title),
        luaL_Reg(name: strdup("subTitle"),                    func: notification_subtitle),
        luaL_Reg(name: strdup("informativeText"),             func: notification_informativeText),
        luaL_Reg(name: strdup("actionButtonTitle"),           func: notification_actionButtonTitle),
        luaL_Reg(name: strdup("otherButtonTitle"),            func: notification_otherButtonTitle),
        luaL_Reg(name: strdup("hasActionButton"),             func: notification_hasActionButton),
        luaL_Reg(name: strdup("soundName"),                   func: notification_soundName),
        luaL_Reg(name: strdup("alwaysPresent"),               func: notification_alwaysPresent),
        luaL_Reg(name: strdup("autoWithdraw"),                func: notification_autoWithdraw),
        luaL_Reg(name: strdup("_contentImage"),               func: notification_contentImage),
        luaL_Reg(name: strdup("_setIdImage"),                 func: notification_setIdImage),
        luaL_Reg(name: strdup("getFunctionTag"),              func: notification_getFunctionTag),
        luaL_Reg(name: strdup("presented"),                   func: notification_presented),
        luaL_Reg(name: strdup("delivered"),                   func: notification_delivered),
        luaL_Reg(name: strdup("activationType"),              func: notification_activationType),
        luaL_Reg(name: strdup("actualDeliveryDate"),          func: notification_actualDeliveryDate),

        luaL_Reg(name: strdup("responsePlaceholder"),         func: notification_responsePlaceholder),
        luaL_Reg(name: strdup("hasReplyButton"),              func: notification_hasReplyButton),
        luaL_Reg(name: strdup("additionalActions"),           func: notification_additionalActions),
        luaL_Reg(name: strdup("response"),                    func: notification_response),
        luaL_Reg(name: strdup("additionalActivationAction"),  func: notification_additionalActivationAction),
        luaL_Reg(name: strdup("alwaysShowAdditionalActions"), func: notification_alwaysShowAdditionalActions),
        luaL_Reg(name: strdup("withdrawAfter"),               func: notification_withdrawAfter),
    ]
    #if DEBUG
    lib.append(luaL_Reg(name: strdup("showMyDict"), func: showMyDict))
    #endif
    lib.append(contentsOf: [
        luaL_Reg(name: strdup("__tostring"),          func: nt_userdata_tostring),
        luaL_Reg(name: strdup("__eq"),                func: nt_userdata_eq),
        luaL_Reg(name: strdup("__gc"),                func: nt_userdata_gc),
        luaL_Reg(name: nil,                           func: nil),
    ])
    return lib
}()

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_new"),                   func: notification_new),
    luaL_Reg(name: strdup("withdrawAll"),            func: notification_withdraw_all),
    luaL_Reg(name: strdup("withdrawAllScheduled"),   func: notification_withdraw_allScheduled),
    luaL_Reg(name: strdup("deliveredNotifications"), func: notification_deliveredNotifications),
    luaL_Reg(name: strdup("scheduledNotifications"), func: notification_scheduledNotifications),
    luaL_Reg(name: nil,                              func: nil),
]

// Metatable for module, if needed
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: nt_meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

@_cdecl("luaopen_hs_libnotify")
public func luaopen_hs_libnotify(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    nt_refTable = skin.registerLibrary(withObject: nt_USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    _ = nt_activationTypesTable(L)
    lua_setfield(L, -2, "activationTypes")

/// hs.notify.defaultNotificationSound
/// Constant
/// The string representation of the default notification sound. Use `hs.notify:soundName()` or set the `soundName` attribute in `hs:notify.new()`, to this constant, if you want to use the default sound
    lua_pushstring(L, NSUserNotificationDefaultSoundName)
    lua_setfield(L, -2, "defaultNotificationSound")

    skin.registerPushNSHelper(nt_pushNSUserNotification, forClass: "NSUserNotification")
    skin.registerLuaObjectHelper(nt_toNSUserNotificationFromLua, forClass: "NSUserNotification",
                                 withUserdataMapping: nt_USERDATA_TAG)

    nt_delegate_setup()
    nt_specifics = NSMutableDictionary()

    return 1
}
