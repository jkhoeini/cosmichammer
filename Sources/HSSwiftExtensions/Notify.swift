import Cocoa
import CLua
import Lua
import os.log
import HSDSTCore

// NSUserNotification and its relations are deprecated but we're not ready to switch quite yet...

// MARK: - Constants

let nt_USERDATA_TAG = "hs.notify"
var nt_refTable: Int32 = LUA_NOREF

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
let KEY_ACTIVEGAUGE   = "activeGauge"

var nt_old_delegate: NSUserNotificationCenterDelegate?
private var activeNotifyUserdataCount = 0

private func recordActiveNotifyUserdataGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.notify.userdata.active",
        kind: .gauge,
        value: Double(activeNotifyUserdataCount),
        attributes: [:],
        unit: "1"
    )
}

private func setNotifyUserdataCounted(_ userInfo: NSMutableDictionary, _ active: Bool, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let counted = (userInfo[KEY_ACTIVEGAUGE] as? NSNumber)?.boolValue ?? false
    guard counted != active else { return }
    userInfo[KEY_ACTIVEGAUGE] = NSNumber(value: active)
    if active {
        activeNotifyUserdataCount += 1
    } else {
        activeNotifyUserdataCount = max(0, activeNotifyUserdataCount - 1)
    }
    recordActiveNotifyUserdataGauge(L)
}

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
            os_log(.error, "%{public}s","\(nt_USERDATA_TAG) passing off to original handler")
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

        let L = lua_getCurrentState()!
        if !(lua_getglobal(L, "require") == LUA_OK && { L.push(nt_USERDATA_TAG); return lua_pcall(L, 1, 1, 0) == LUA_OK }()) {
            os_log(.error, "%{public}s", "\(nt_USERDATA_TAG):_didActivateNotification - unable to load tag handler: \(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1) // remove error message
            return
        }
        lua_getfield(L, -1, "_tag_handler") // now we know the function hs.notify._tag_handler is on the stack...
        lua_pushany(L, userInfo[KEY_FNTAG])
        nt_pushNSUserNotification(L, notification)

        if luaTelemetryPCall(
            L,
            nargs: 2,
            nresults: 0,
            callbackName: "hs.notify.activation",
            attributes: [
                "notification.delivered": userInfo[KEY_DELIVERED] as? Bool ?? true,
                "notification.has_action": notification.activationType != .none,
            ]
        ) != LUA_OK {
            lua_pop(L, 1) // pop error message
            lua_pop(L, 1) // pop the hs.notify module
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

func nt_pushNotificationArray(_ L: UnsafeMutablePointer<lua_State>!, _ notifications: [NSUserNotification]) {
    lua_newtable(L)
    for (idx, notification) in notifications.enumerated() {
        nt_pushNSUserNotification(L, notification)
        lua_rawseti(L, -2, lua_Integer(idx + 1))
    }
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
private func notification_withdraw_all(_ L: LuaState) throws -> CInt {
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
private func notification_withdraw_allScheduled(_ L: LuaState) throws -> CInt {
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
private func notification_deliveredNotifications(_ L: LuaState) throws -> CInt {
    let deliveredNotifications = NSUserNotificationCenter.default.deliveredNotifications

    nt_pushNotificationArray(L, deliveredNotifications)
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
private func notification_scheduledNotifications(_ L: LuaState) throws -> CInt {
    nt_pushNotificationArray(L, NSUserNotificationCenter.default.scheduledNotifications)
    return 1
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
// hs.notify._new(fntag) -> notificationObject
// Constructor
// Returns a new notification object with the specified information and the assigned callback function.
private func notification_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let gus = ProcessInfo.processInfo.globallyUniqueString

    let userInfo: NSMutableDictionary = [
        KEY_LOCKED:        false,
        KEY_ID:            gus,
        KEY_WITHDRAWAFTER: 0.0,
        KEY_FNTAG:         lua_tovalue(L, at: 1)!,
        KEY_ALWAYSPRESENT: true,
        KEY_AUTOWITHDRAW:  true,
        KEY_SELFREFCOUNT:  0,
        KEY_DELIVERED:     false,
        KEY_ACTIVEGAUGE:   false,
    ]

    nt_specifics[gus] = userInfo

    let notification = NSUserNotification()
    notification.userInfo = [KEY_ID: gus]
    notification.hasActionButton = false

    nt_pushNSUserNotification(L, notification)
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
    L.push(lua_Integer(NSUserNotification.ActivationType.none.rawValue))
    lua_setfield(L, -2, "none")
    L.push(lua_Integer(NSUserNotification.ActivationType.contentsClicked.rawValue))
    lua_setfield(L, -2, "contentsClicked")
    L.push(lua_Integer(NSUserNotification.ActivationType.actionButtonClicked.rawValue))
    lua_setfield(L, -2, "actionButtonClicked")
    L.push(lua_Integer(NSUserNotification.ActivationType.replied.rawValue))
    lua_setfield(L, -2, "replied")
    L.push(lua_Integer(NSUserNotification.ActivationType.additionalActionClicked.rawValue))
    lua_setfield(L, -2, "additionalActionClicked")
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

@discardableResult
func nt_pushNSUserNotification(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let value = obj as! NSUserNotification

    if let userInfoDict = value.userInfo {
        if let gus = userInfoDict[KEY_ID] as? String {
            if let userInfo = nt_specifics[gus] as? NSMutableDictionary {
                let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                userInfo[KEY_SELFREFCOUNT] = NSNumber(value: selfRefCount + 1)
                setNotifyUserdataCounted(userInfo, true, L: L)
            } else {
                if userInfoDict[KEY_DELIVERED] != nil { // it's a holdover from a reload/relaunch
                    nt_specifics[gus] = (userInfoDict as NSDictionary).mutableCopy()
                    let userInfo = nt_specifics[gus] as! NSMutableDictionary
                    userInfo[KEY_SELFREFCOUNT] = NSNumber(value: 1)
                    userInfo[KEY_ACTIVEGAUGE] = NSNumber(value: false)
                    setNotifyUserdataCounted(userInfo, true, L: L)
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
    if luaL_testudata(L, idx, nt_USERDATA_TAG) != nil {
        return nt_getNotification(L, idx)
    } else {
        os_log(.error, "%{public}s", "expected \(nt_USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))!))")
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func nt_userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = nt_getNotification(L, 1)
    let title = obj.title ?? ""
    let desc = "\(nt_USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))"
    L.push(desc)
    return 1
}

private func nt_userdata_eq(_ L: LuaState) throws -> CInt {
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, nt_USERDATA_TAG) != nil && luaL_testudata(L, 2, nt_USERDATA_TAG) != nil {
        let obj1 = nt_getNotification(L, 1)
        let obj2 = nt_getNotification(L, 2)
        L.push(obj1.isEqual(to: obj2))
    } else {
        L.push(false)
    }
    return 1
}

func nt_userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, nt_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<NSUserNotification>.fromOpaque(rawPtr).takeRetainedValue()

        if let userInfoDict = obj.userInfo {
            if let gus = userInfoDict[KEY_ID] as? String { // it's ours
                if let specifics = nt_specifics,
                   let userInfo = specifics[gus] as? NSMutableDictionary { // and we have a record for it
                    let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                    let newSelfRefCount = selfRefCount - 1
                    userInfo[KEY_SELFREFCOUNT] = NSNumber(value: newSelfRefCount)
                    if newSelfRefCount <= 0 {
                        setNotifyUserdataCounted(userInfo, false, L: L)
                        specifics[gus] = nil
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
private func nt_meta_gc(_ L: LuaState) throws -> CInt {
    NSUserNotificationCenter.default.delegate = nt_old_delegate
    if nt_specifics != nil {
        activeNotifyUserdataCount = 0
        recordActiveNotifyUserdataGauge(L)
        nt_specifics.removeAllObjects()
        nt_specifics = nil
    }
    return 0
}

#if DEBUG
@MainActor
func nt_debugSetSpecificsRecord(_ gus: String, _ userInfo: NSMutableDictionary) {
    guard let specifics = nt_specifics else { return }
    specifics[gus] = userInfo
}

@MainActor
func nt_debugSelfRefCount(_ gus: String) -> Int? {
    guard let specifics = nt_specifics,
          let userInfo = specifics[gus] as? NSMutableDictionary else { return nil }
    return (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue
}

@MainActor
func nt_debugHasSpecificsRecord(_ gus: String) -> Bool {
    guard let specifics = nt_specifics else { return false }
    return specifics[gus] != nil
}

@MainActor
func nt_debugCleanupModule(_ L: UnsafeMutablePointer<lua_State>!) {
    if nt_specifics != nil {
        _ = try? nt_meta_gc(L)
    }
}
#endif

@_cdecl("luaopen_hs_libnotify")
public func luaopen_hs_libnotify(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        nt_refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        // NOTE: NSUserNotification is an Apple framework class stored via Unmanaged raw pointer,
        // so we cannot use Metatable<T>/installMetatableBoilerplate. Manual registration is correct here.
        luaL_newmetatable(L, nt_USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        L.push(notification_send);                        lua_setfield(L, -2, "send")
        L.push(notification_scheduleNotification);        lua_setfield(L, -2, "schedule")
        L.push(notification_withdraw);                    lua_setfield(L, -2, "withdraw")
        L.push(notification_title);                       lua_setfield(L, -2, "title")
        L.push(notification_subtitle);                    lua_setfield(L, -2, "subTitle")
        L.push(notification_informativeText);             lua_setfield(L, -2, "informativeText")
        L.push(notification_actionButtonTitle);           lua_setfield(L, -2, "actionButtonTitle")
        L.push(notification_otherButtonTitle);            lua_setfield(L, -2, "otherButtonTitle")
        L.push(notification_hasActionButton);             lua_setfield(L, -2, "hasActionButton")
        L.push(notification_soundName);                   lua_setfield(L, -2, "soundName")
        L.push(notification_alwaysPresent);               lua_setfield(L, -2, "alwaysPresent")
        L.push(notification_autoWithdraw);                lua_setfield(L, -2, "autoWithdraw")
        L.push(notification_contentImage);                lua_setfield(L, -2, "_contentImage")
        L.push(notification_setIdImage);                  lua_setfield(L, -2, "_setIdImage")
        L.push(notification_getFunctionTag);              lua_setfield(L, -2, "getFunctionTag")
        L.push(notification_presented);                   lua_setfield(L, -2, "presented")
        L.push(notification_delivered);                   lua_setfield(L, -2, "delivered")
        L.push(notification_activationType);              lua_setfield(L, -2, "activationType")
        L.push(notification_actualDeliveryDate);          lua_setfield(L, -2, "actualDeliveryDate")
        L.push(notification_responsePlaceholder);         lua_setfield(L, -2, "responsePlaceholder")
        L.push(notification_hasReplyButton);              lua_setfield(L, -2, "hasReplyButton")
        L.push(notification_additionalActions);           lua_setfield(L, -2, "additionalActions")
        L.push(notification_response);                    lua_setfield(L, -2, "response")
        L.push(notification_additionalActivationAction);  lua_setfield(L, -2, "additionalActivationAction")
        L.push(notification_alwaysShowAdditionalActions); lua_setfield(L, -2, "alwaysShowAdditionalActions")
        L.push(notification_withdrawAfter);               lua_setfield(L, -2, "withdrawAfter")
        #if DEBUG
        L.push(showMyDict);                               lua_setfield(L, -2, "showMyDict")
        #endif
        L.push(nt_userdata_tostring);                     lua_setfield(L, -2, "__tostring")
        L.push(nt_userdata_eq);                           lua_setfield(L, -2, "__eq")

        // __gc must be a non-throwing C closure — finalizers must not raise Lua errors.
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            let ptr = luaL_checkudata(L, 1, nt_USERDATA_TAG)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let rawPtr = ptr.pointee {
                let obj = Unmanaged<NSUserNotification>.fromOpaque(rawPtr).takeRetainedValue()
                if let userInfoDict = obj.userInfo {
                    if let gus = userInfoDict[KEY_ID] as? String {
                        if let specifics = nt_specifics,
                           let userInfo = specifics[gus] as? NSMutableDictionary {
                            let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                            let newSelfRefCount = selfRefCount - 1
                            userInfo[KEY_SELFREFCOUNT] = NSNumber(value: newSelfRefCount)
                            if newSelfRefCount <= 0 {
                                specifics[gus] = nil
                            }
                        }
                    }
                }
                ptr.pointee = nil
            }
            lua_pushnil(L)
            lua_setmetatable(L, 1)
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")

        // Set __type/__name and alias metatable in registry
        L.push(nt_USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(nt_USERDATA_TAG)
        lua_setfield(L, -2, "__name")
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, nt_USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 5)
        L.push(notification_new);                    lua_setfield(L, -2, "_new")
        L.push(notification_withdraw_all);           lua_setfield(L, -2, "withdrawAll")
        L.push(notification_withdraw_allScheduled);  lua_setfield(L, -2, "withdrawAllScheduled")
        L.push(notification_deliveredNotifications); lua_setfield(L, -2, "deliveredNotifications")
        L.push(notification_scheduledNotifications); lua_setfield(L, -2, "scheduledNotifications")

        // Set module metatable (for __gc) — non-throwing C closure for finalizer safety
        lua_createtable(L, 0, 1)
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            NSUserNotificationCenter.default.delegate = nt_old_delegate
            if nt_specifics != nil {
                nt_specifics.removeAllObjects()
                nt_specifics = nil
            }
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        _ = nt_activationTypesTable(L)
        lua_setfield(L, -2, "activationTypes")

    /// hs.notify.defaultNotificationSound
    /// Constant
    /// The string representation of the default notification sound. Use `hs.notify:soundName()` or set the `soundName` attribute in `hs:notify.new()`, to this constant, if you want to use the default sound
        L.push(NSUserNotificationDefaultSoundName)
        lua_setfield(L, -2, "defaultNotificationSound")

        nt_delegate_setup()
        nt_specifics = NSMutableDictionary()
    }
}
