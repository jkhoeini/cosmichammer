import Cocoa
import LuaSkin

// NSUserNotification and its relations are deprecated but we're not ready to switch quite yet...

// MARK: - Constants

private let USERDATA_TAG = "hs.notify"
private var refTable: LSRefTable = LUA_NOREF

// changes made to userInfo dictionary in userNotificationCenter:didDeliverNotification: are not
// kept (is notification object a copy?) so we can't update delivered if it's in that particular
// dictionary... track it in here instead, keyed to unique id added when created (see new).
private var ourNotificationSpecifics: NSMutableDictionary!

private let KEY_LOCKED        = "locked"
private let KEY_ID            = "gus"
private let KEY_WITHDRAWAFTER = "withdrawAfter"
private let KEY_FNTAG         = "fntag"
private let KEY_ALWAYSPRESENT = "alwaysPresent"
private let KEY_AUTOWITHDRAW  = "autoWithdraw"
private let KEY_SELFREFCOUNT  = "selfRefCount"
private let KEY_DELIVERED     = "delivered"

private var old_delegate: NSUserNotificationCenterDelegate?

// MARK: - Support Functions and Classes

class HSModuleNotificationManager: NSObject, NSUserNotificationCenterDelegate {
    static let shared = HSModuleNotificationManager()

    // Notification delivered to Notification Center
    func userNotificationCenter(_ center: NSUserNotificationCenter, didDeliver notification: NSUserNotification) {
        // if it's ours, we've copied the necessary info into the userInfo dictionary...
        guard let gus = notification.userInfo?[KEY_ID] as? String else { return }

        // however we *might* need to recreate the local record so we can update KEY_DELIVERED
        if ourNotificationSpecifics[gus] == nil {
            ourNotificationSpecifics[gus] = (notification.userInfo! as NSDictionary).mutableCopy()
        }
        let userInfo = ourNotificationSpecifics[gus] as! NSMutableDictionary
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
            LuaSkin.skin(with: nil).logError("\(USERDATA_TAG) passing off to original handler")
            if let delegate = old_delegate, delegate.responds(to: #selector(NSUserNotificationCenterDelegate.userNotificationCenter(_:didActivate:))) {
                delegate.userNotificationCenter?(center, didActivate: notification)
            }
            return
        }

        // however we *might* need to recreate the local record so we can update KEY_DELIVERED
        if ourNotificationSpecifics[gus] == nil {
            ourNotificationSpecifics[gus] = (notification.userInfo! as NSDictionary).mutableCopy()
        }
        let userInfo = ourNotificationSpecifics[gus] as! NSMutableDictionary
        userInfo[KEY_DELIVERED] = true // just in case its a holdover from before a reload/relaunch

        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!

        _lua_stackguard_entry(L)
        if !skin.requireModule(USERDATA_TAG) {
            skin.logError("\(USERDATA_TAG):_didActivateNotification - unable to load tag handler: \(String(cString: lua_tostring(L, -1)!))")
            lua_pop(L, 1) // remove error message
            _lua_stackguard_exit(L)
            return
        }
        lua_getfield(L, -1, "_tag_handler") // now we know the function hs.notify._tag_handler is on the stack...
        skin.pushNSObject(userInfo[KEY_FNTAG])
        skin.pushNSObject(notification)

        if !skin.protectedCallAndError("\(USERDATA_TAG) callback", nargs: 2, nresults: 0) {
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

private func notification_delegate_setup() {
    // Get and store old (core app) delegate. If it hasn't been setup yet, do so.
    old_delegate = NSUserNotificationCenter.default.delegate
    if old_delegate == nil {
        _ = MJUserNotificationManager.sharedManager
        old_delegate = NSUserNotificationCenter.default.delegate
    }
    // Create our delegate
    NSUserNotificationCenter.default.delegate = HSModuleNotificationManager.shared
}

private func date_from_string(_ dateString: String) -> Date? {
    // rfc3339 (Internet Date/Time) formatted date. More or less.
    let rfc3339DateFormatter = DateFormatter()
    rfc3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
    rfc3339DateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    rfc3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    return rfc3339DateFormatter.date(from: dateString)
}

// MARK: - Helper: get_objectFromUserdata

private func getNotification(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSUserNotification {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
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
private let notification_withdraw_all: lua_CFunction = { L in
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
private let notification_withdraw_allScheduled: lua_CFunction = { L in
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
private let notification_deliveredNotifications: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    let deliveredNotifications = NSUserNotificationCenter.default.deliveredNotifications

    skin.pushNSObject(deliveredNotifications as NSArray)
    // just in case pushNSUserNotification had to recreate our entries in ourNotificationSpecifics
    for notification in deliveredNotifications {
        if let gus = notification.userInfo?[KEY_ID] as? String {
            if let userInfo = ourNotificationSpecifics[gus] as? NSMutableDictionary {
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
private let notification_scheduledNotifications: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(NSUserNotificationCenter.default.scheduledNotifications as NSArray)
    return 1
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
// hs.notify._new(fntag) -> notificationObject
// Constructor
// Returns a new notification object with the specified information and the assigned callback function.
private let notification_new: lua_CFunction = { L in
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

    ourNotificationSpecifics[gus] = userInfo

    let notification = NSUserNotification()
    notification.userInfo = [KEY_ID: gus]
    notification.hasActionButton = false

    skin.pushNSObject(notification)
    return 1
}

// MARK: - Module Methods

/// hs.notify:send() -> notificationObject
/// Method
/// Delivers the notification immediately to the users Notification Center.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The notification object
///
/// Notes:
///  * See also hs.notify:schedule()
///  * If a notification has been modified, then this will resend it.
///  * You can invoke this multiple times if you wish to repeat the same notification.
private let notification_send: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    guard let gus = notification.userInfo?[KEY_ID] as? String else {
        return luaL_error(L, "notification was not created by this module")
    }
    let userInfo = ourNotificationSpecifics[gus] as! NSMutableDictionary
    userInfo[KEY_DELIVERED] = false
    userInfo[KEY_LOCKED] = true
    notification.userInfo = (userInfo.copy() as! NSDictionary) as? [String: Any]

    NSUserNotificationCenter.default.deliver(notification)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.notify:schedule(date) -> notificationObject
/// Method
/// Schedules a notification for delivery in the future.
///
/// Parameters:
///  * date - the date the notification should be delivered to the users Notification Center specified as the number of seconds since 1970-01-01 00:00:00Z or as a string in rfc3339 format: "YYYY-MM-DD[T]HH:MM:SS[Z]".
///
/// Returns:
///  * The notification object
///
/// Notes:
///  * See also hs.notify:send()
///  * hs.settings.dateFormat specifies a lua format string which can be used with `os.date()` to properly present the date and time as a string for use with this method.
private let notification_scheduleNotification: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let myDate: Date?
    if lua_isnumber(L, 2) {
        myDate = Date(timeIntervalSince1970: lua_tonumber(L, 2))
    } else if lua_isstring(L, 2) {
        myDate = date_from_string(String(cString: lua_tostring(L, 2)!))
    } else {
        myDate = nil
    }

    guard let date = myDate else {
        return luaL_error(L, "-- \(USERDATA_TAG):schedule: improper date specified: must be a number (# of seconds since 1970-01-01 00:00:00Z) or string in the format of 'YYYY-MM-DD[T]HH:MM:SS[Z]' (rfc3339)")
    }
    notification.deliveryDate = date

    guard let gus = notification.userInfo?[KEY_ID] as? String else {
        return luaL_error(L, "notification was not created by this module")
    }
    let userInfo = ourNotificationSpecifics[gus] as! NSMutableDictionary
    userInfo[KEY_DELIVERED] = false
    userInfo[KEY_LOCKED] = true
    notification.userInfo = (userInfo.copy() as! NSDictionary) as? [String: Any]

    NSUserNotificationCenter.default.scheduleNotification(notification)
    lua_settop(L, 1)
    return 1
}

/// hs.notify:withdraw() -> notificationObject
/// Method
/// Withdraws a delivered notification from the Notification Center.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The notification object
///  * This method allows you to unlock a dispatched notification so that it can be modified and resent.
///  * if the notification was not created by this module, it will still be withdrawn if possible
private let notification_withdraw: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    if let gus = notification.userInfo?[KEY_ID] as? String {
        let userInfo = ourNotificationSpecifics[gus] as! NSMutableDictionary
        let isLocked = (userInfo[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

        if isLocked {
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
            NSUserNotificationCenter.default.removeScheduledNotification(notification)

            userInfo[KEY_DELIVERED] = false
            userInfo[KEY_LOCKED] = false
            notification.userInfo = [KEY_ID: gus]
        } else {
            return luaL_error(L, "notification has not yet been dispatched and cannot be withdrawn")
        }
    } else { // not ours, but withdraw anyways
        NSUserNotificationCenter.default.removeDeliveredNotification(notification)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.notify:title([titleText]) -> notificationObject | current-setting
/// Method
/// Get or set the title of a notification
///
/// Parameters:
///  * titleText - An optional string containing the title to be set on the notification object.  The default value is "Notification".  If `nil` is passed, then the title is set to the empty string.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if titleText is present; otherwise the current setting.
private let notification_title: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.title as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.title = ""
            } else {
                notification.title = skin.toNSObject(atIndex: 2) as? String
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:subTitle([subtitleText]) -> notificationObject | current-setting
/// Method
/// Get or set the subtitle of a notification
///
/// Parameters:
///  * subtitleText - An optional string containing the subtitle to be set on the notification object. This can be an empty string. If `nil` is passed, any existing subtitle will be removed.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if subtitleText is present; otherwise the current setting.
private let notification_subtitle: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.subtitle as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.subtitle = nil
            } else {
                notification.subtitle = skin.toNSObject(atIndex: 2) as? String
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:informativeText([informativeText]) -> notificationObject | current-setting
/// Method
/// Get or set the informative text of a notification
///
/// Parameters:
///  * informativeText - An optional string containing the informative text to be set on the notification object. This can be an empty string. If `nil` is passed, any existing informative text will be removed.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if informativeText is present; otherwise the current setting.
private let notification_informativeText: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.informativeText as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.informativeText = nil
            } else {
                notification.informativeText = skin.toNSObject(atIndex: 2) as? String
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:actionButtonTitle([buttonTitle]) -> notificationObject | current-setting
/// Method
/// Get or set the label of a notification's action button
///
/// Parameters:
///  * buttonTitle - An optional string containing the title for the notification's action button.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if buttonTitle is present; otherwise the current setting.
///
/// Notes:
///  * The affects of this method only apply if the user has set Cosmic Hammer notifications to `Alert` in the Notification Center pane of System Preferences
///  * This value is ignored if [hs.notify:hasReplyButton](#hasReplyButton) is true.
private let notification_actionButtonTitle: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.actionButtonTitle as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.actionButtonTitle = ""
            } else {
                notification.actionButtonTitle = skin.toNSObject(atIndex: 2) as? String ?? ""
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:otherButtonTitle([buttonTitle]) -> notificationObject | current-setting
/// Method
/// Get or set the label of a notification's other button
///
/// Parameters:
///  * buttonTitle - An optional string containing the title for the notification's other button.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if buttonTitle is present; otherwise the current setting.
///
/// Notes:
///  * The affects of this method only apply if the user has set Cosmic Hammer notifications to `Alert` in the Notification Center pane of System Preferences
///  * Due to OSX limitations, it is NOT possible to get a callback for this button.
private let notification_otherButtonTitle: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.otherButtonTitle as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.otherButtonTitle = ""
            } else {
                notification.otherButtonTitle = skin.toNSObject(atIndex: 2) as? String ?? ""
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:hasActionButton([hasButton]) -> notificationObject | current-setting
/// Method
/// Get or set the presence of an action button in a notification
///
/// Parameters:
///  * hasButton - An optional boolean indicating whether an action button should be present.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if hasButton is present; otherwise the current setting.
///
/// Notes:
///  * The affects of this method only apply if the user has set Cosmic Hammer notifications to `Alert` in the Notification Center pane of System Preferences
private let notification_hasActionButton: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        lua_pushboolean(L, notification.hasActionButton ? 1 : 0)
    } else if let _ = gus {
        if !isLocked {
            notification.hasActionButton = lua_toboolean(L, 2) != 0
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:alwaysPresent([alwaysPresent]) -> notificationObject | current-setting
/// Method
/// Get or set whether a notification should be presented even if this overrides Notification Center's decision process.
///
/// Parameters:
///  * alwaysPresent - An optional boolean parameter indicating whether the notification should override Notification Center's decision about whether to present the notification or not. Defaults to true.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if alwaysPresent is provided; otherwise the current setting.
///
/// Notes:
///  * This does not affect the return value of `hs.notify:presented()` -- that will still reflect the decision of the Notification Center
///  * Examples of why the users Notification Center would choose not to display a notification would be if Cosmic Hammer is the currently focussed application, being attached to a projector, or the user having set Do Not Disturb.
///
///  * if the notification was not created by this module, this method will return nil
private let notification_alwaysPresent: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        if gus != nil {
            let alwaysPresent = (userInfo?[KEY_ALWAYSPRESENT] as? NSNumber)?.boolValue ?? true
            lua_pushboolean(L, alwaysPresent ? 1 : 0)
        } else {
            lua_pushnil(L)
        }
    } else if let _ = gus {
        if !isLocked {
            userInfo![KEY_ALWAYSPRESENT] = lua_toboolean(L, 2)
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:getFunctionTag() -> functiontag
/// Method
/// Return the name of the function tag the notification will call when activated.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The function tag for this notification as a string.
///
/// Notes:
///  * This tag should correspond to a function in [hs.notify.registry](#registry) and can be used to either add a replacement with `hs.notify.register(...)` or remove it with `hs.notify.unregister(...)`
///
///  * if the notification was not created by this module, this method will return nil
private let notification_getFunctionTag: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    if let gus = notification.userInfo?[KEY_ID] as? String {
        let userInfo = ourNotificationSpecifics[gus] as? NSMutableDictionary
        skin.pushNSObject(userInfo?[KEY_FNTAG])
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.notify:autoWithdraw([shouldWithdraw]) -> notificationObject | current-setting
/// Method
/// Get or set whether a notification should automatically withdraw once activated
///
/// Parameters:
///  * shouldWithdraw - An optional boolean indicating whether the notification should automatically withdraw. Defaults to true.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if shouldWithdraw is present; otherwise the current setting.
///
/// Notes:
///  * This method has no effect if the user has set Cosmic Hammer notifications to `Alert` in the Notification Center pane of System Preferences: clicking on either the action or other button will clear the notification automatically.
///  * If a notification which was created before your last reload (or restart) of Cosmic Hammer and is clicked upon before hs.notify has been loaded into memory, this setting will not be honored because the initial application delegate is not aware of this option and is set to automatically withdraw all notifications which are acted upon.
///
///  * if the notification was not created by this module, this method will return nil
private let notification_autoWithdraw: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        if gus != nil {
            let autoWithdraw = (userInfo?[KEY_AUTOWITHDRAW] as? NSNumber)?.boolValue ?? true
            lua_pushboolean(L, autoWithdraw ? 1 : 0)
        } else {
            lua_pushnil(L)
        }
    } else if let _ = gus {
        if !isLocked {
            userInfo![KEY_AUTOWITHDRAW] = lua_toboolean(L, 2)
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:soundName([soundName]) -> notificationObject | current-setting
/// Method
/// Get or set the sound for a notification
///
/// Parameters:
///  * soundName - An optional string containing the name of a sound to play with the notification. If `nil`, no sound will be played. Defaults to `nil`.  If no parameter is provided, then the current setting is returned.
///
/// Returns:
///  * The notification object, if soundName is present; otherwise the current setting.
///
/// Notes:
///  * Sounds will first be matched against the names of system sounds. If no matches can be found, they will then be searched for in the following paths, in order:
///   * `~/Library/Sounds`
///   * `/Library/Sounds`
///   * `/Network/Sounds`
///   * `/System/Library/Sounds`
private let notification_soundName: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.soundName as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.soundName = nil
            } else {
                notification.soundName = skin.toNSObject(atIndex: 2) as? String
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
private let notification_contentImage: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK | LS_TVARARG)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.contentImage)
    } else if let _ = gus {
        if !isLocked {
            skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TUSERDATA, "hs.image", LS_TBREAK)
            notification.contentImage = skin.toNSObject(atIndex: 2) as? NSImage
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
private let notification_setIdImage: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TUSERDATA, "hs.image", LS_TBOOLEAN, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if let _ = gus {
        if !isLocked {
            let idImage = skin.toNSObject(atIndex: 2) as! NSImage
            let hasBorder = lua_toboolean(L, 3)

            if notification.responds(to: Selector(("set_identityImage:"))) && notification.responds(to: Selector(("_identityImageHasBorder"))) {
                notification.perform(Selector(("set_identityImage:")), with: idImage)
                notification.setValue(hasBorder, forKey: "_identityImageHasBorder")
            } else {
                skin.logInfo("\(USERDATA_TAG):setIdImage() is not supported on this machine or macOS version. Please file an issue")
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:hasReplyButton([state]) -> notificationObject | boolean
/// Method
/// Get or set whether an alert notification has a "Reply" button for additional user input.
///
/// Parameters:
///  * state - An optional boolean, default false, indicating whether the notification should include a reply button for additional user input.
///
/// Returns:
///  * The notification object, if an argument is present; otherwise the current value
///
/// Notes:
///  * This method has no effect unless the user has set Cosmic Hammer notifications to `Alert` in the Notification Center pane of System Preferences.
///  * [hs.notify:hasActionButton](#hasActionButton) must also be true or the "Reply" button will not be displayed.
///  * If this is set to true, the action button will be "Reply" even if you have set another one with [hs.notify:actionButtonTitle](#actionButtonTitle).
private let notification_hasReplyButton: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        lua_pushboolean(L, notification.hasReplyButton ? 1 : 0)
    } else if let _ = gus {
        if !isLocked {
            notification.hasReplyButton = lua_toboolean(L, 2) != 0
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:alwaysShowAdditionalActions([state]) -> notificationObject | boolean
/// Method
/// Get or set whether an alert notification should always show an alternate action menu.
///
/// Parameters:
///  * state - An optional boolean, default false, indicating whether the notification should always show an alternate action menu.
///
/// Returns:
///  * The notification object, if an argument is present; otherwise the current value.
///
/// Notes:
///  * This method has no effect unless the user has set Cosmic Hammer notifications to `Alert` in the Notification Center pane of System Preferences.
///  * [hs.notify:additionalActions](#additionalActions) must also be used for this method to have any effect.
///  * **WARNING:** This method uses a private API. It could break at any time. Please file an issue if it does.
private let notification_alwaysShowAdditionalActions: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if notification.responds(to: Selector(("_alwaysShowAlternateActionMenu"))) {
        if lua_isnone(L, 2) {
            let val = notification.value(forKey: "_alwaysShowAlternateActionMenu") as? Bool ?? false
            lua_pushboolean(L, val ? 1 : 0)
        } else if let _ = gus {
            if !isLocked {
                notification.setValue(lua_toboolean(L, 2), forKey: "_alwaysShowAlternateActionMenu")
                lua_pushvalue(L, 1)
            } else {
                return luaL_error(L, "notification has been dispatched and can no longer be modified")
            }
        } else {
            return luaL_error(L, "notification was not created by this module")
        }
    } else {
        skin.logInfo("\(USERDATA_TAG):alwaysShowAdditionalActions() is not supported on this machine or macOS version. Please file an issue")
    }
    return 1
}

/// hs.notify:withdrawAfter([seconds]) -> notificationObject | number
/// Method
/// Get or set the number of seconds after which to automatically withdraw a notification
///
/// Parameters:
///  * seconds - An optional number, default 5, of seconds after which to withdraw a notification. A value of 0 will not withdraw a notification automatically
///
/// Returns:
///  * The notification object, if an argument is present; otherwise the current value.
///
/// Notes:
///  * While this setting applies to both Banner and Alert styles of notifications, it is functionally meaningless for Banner styles
///  * A value of 0 will disable auto-withdrawal
///
///  * if the notification was not created by this module, this method will return nil
private let notification_withdrawAfter: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        if gus != nil {
            skin.pushNSObject(userInfo?[KEY_WITHDRAWAFTER])
        } else {
            lua_pushnil(L)
        }
    } else if let _ = gus {
        if !isLocked {
            userInfo![KEY_WITHDRAWAFTER] = skin.toNSObject(atIndex: 2)
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:responsePlaceholder([string]) -> notificationObject | string
/// Method
/// Set a placeholder string for alert type notifications with a reply button.
///
/// Parameters:
///  * `string` - an optional string specifying placeholder text to display in the reply box before the user has types anything in an alert type notification with a reply button.
///
/// Returns:
///  * The notification object, if an argument is present; otherwise the current value
///
/// Notes:
///  * In macOS 10.13, this text appears so light that it is almost unreadable; so far no workaround has been found.
///  * See also [hs.notify:hasReplyButton](#hasReplyButton)
private let notification_responsePlaceholder: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_isnone(L, 2) {
        skin.pushNSObject(notification.responsePlaceholder as NSString?)
    } else if let _ = gus {
        if !isLocked {
            if lua_isnil(L, 2) {
                notification.responsePlaceholder = ""
            } else {
                notification.responsePlaceholder = skin.toNSObject(atIndex: 2) as? String
            }
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:response() -> string | nil
/// Method
/// Get the users input from an alert type notification with a reply button.
///
/// Parameters:
///  * None
///
/// Returns:
///  * If the notification has a reply button and the user clicks on it, returns a string containing the user input (may be an empty string); otherwise returns nil.
///
/// Notes:
///  * [hs.notify:activationType](#activationType) will equal `hs.notify.activationTypes.replied` if the user clicked on the Reply button and then clicks on Send.
///  * See also [hs.notify:hasReplyButton](#hasReplyButton)
private let notification_response: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    if let response = notification.response {
        // since placeholder is a string, and there are no tools to edit within the reply, let's leave it as a string unless someone cares.
        skin.pushNSObject(response.string as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.notify:additionalActions([actionsTable]) -> notificationObject | table
/// Method
/// Get or set additional actions which will be displayed for an alert type notification when the user clicks and holds down the action button of the alert.
///
/// Parameters:
///  * an optional table containing an array of strings specifying the additional options to list for the user to select from the notification.
///
/// Returns:
///  * The notification object, if an argument is present; otherwise the current value
///
/// Notes:
///  * The additional items will be listed in a pop-up menu when the user clicks and holds down the mouse button in the action button of the alert.
///  * If the user selects one of the additional actions, [hs.notify:activationType](#activationType) will equal `hs.notify.activationTypes.additionalActionClicked`
///  * See also [hs.notify:additionalActivationAction](#additionalActivationAction)
private let notification_additionalActions: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let gus = notification.userInfo?[KEY_ID] as? String
    let userInfo = gus != nil ? ourNotificationSpecifics[gus!] as? NSMutableDictionary : nil
    let isLocked = (userInfo?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

    if lua_gettop(L) == 1 {
        let actions = notification.additionalActions
        lua_newtable(L)
        if let actions = actions {
            for (i, action) in actions.enumerated() {
                skin.pushNSObject(action.title as NSString?)
                lua_rawseti(L, -2, lua_Integer(i + 1))
            }
        }
    } else if let _ = gus {
        if !isLocked {
            let actions = skin.toNSObject(atIndex: 2) as? [Any]
            var newActions: [NSUserNotificationAction] = []
            var errorMsg: String? = nil

            if let actions = actions as? [Any] {
                for (idx, item) in actions.enumerated() {
                    guard let str = item as? String else {
                        errorMsg = "expected string at index \(idx + 1)"
                        break
                    }
                    newActions.append(NSUserNotificationAction(identifier: str, title: str))
                }
            } else {
                errorMsg = "expected a table containing an array of strings"
            }
            if let errorMsg = errorMsg {
                return luaL_argerror(L, 2, errorMsg)
            }
            notification.additionalActions = newActions
            lua_pushvalue(L, 1)
        } else {
            return luaL_error(L, "notification has been dispatched and can no longer be modified")
        }
    } else {
        return luaL_error(L, "notification was not created by this module")
    }
    return 1
}

/// hs.notify:additionalActivationAction() -> string | nil
/// Method
/// Return the additional action that the user selected from an alert type notification that has additional actions available.
///
/// Parameters:
///  * None
///
/// Returns:
///  * If the notification has additional actions assigned with [hs.notify:additionalActions](#additionalActions) and the user selects one, returns a string containing the selected action; otherwise returns nil.
///
/// Notes:
///  * If the user selects one of the additional actions, [hs.notify:activationType](#activationType) will equal `hs.notify.activationTypes.additionalActionClicked`
///  * See also [hs.notify:additionalActions](#additionalActions)
private let notification_additionalActivationAction: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    if let action = notification.additionalActivationAction {
        skin.pushNSObject(action.title as NSString?)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.notify:presented() -> bool
/// Method
/// Returns whether the users Notification Center decided to display the notification
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean indicating whether the users Notification Center decided to display the notification
///
/// Notes:
///  * Examples of why the users Notification Center would choose not to display a notification would be if Cosmic Hammer is the currently focussed application, being attached to a projector, or the user having set Do Not Disturb.
private let notification_presented: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    lua_pushboolean(L, notification.isPresented ? 1 : 0)
    return 1
}

/// hs.notify:delivered() -> bool
/// Method
/// Returns whether the notification has been delivered to the Notification Center
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean indicating whether the notification has been delivered to the users Notification Center
private let notification_delivered: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    if let gus = notification.userInfo?[KEY_ID] as? String {
        let userInfo = ourNotificationSpecifics[gus] as? NSMutableDictionary
        let delivered = (userInfo?[KEY_DELIVERED] as? NSNumber)?.boolValue ?? false
        lua_pushboolean(L, delivered ? 1 : 0)
    } else {
        let deliveredNotifications = NSUserNotificationCenter.default.deliveredNotifications
        lua_pushboolean(L, deliveredNotifications.contains(notification) ? 1 : 0)
    }
    return 1
}

/// hs.notify:activationType() -> number
/// Method
/// Returns how the notification was activated by the user.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the integer value corresponding to how the notification was activated by the user.  See the table `hs.notify.activationTypes[]` for more information.
private let notification_activationType: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    lua_pushinteger(L, lua_Integer(notification.activationType.rawValue))
    return 1
}

/// hs.notify:actualDeliveryDate() -> number
/// Method
/// Returns the date and time when a notification was delivered
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the delivery date/time of the notification, in seconds since the epoch (i.e. 1970-01-01 00:00:00 +0000)
///
/// Notes:
///  * You can turn epoch times into a human readable string or a table of date elements with the `os.date()` function.
private let notification_actualDeliveryDate: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    skin.pushNSObject(notification.actualDeliveryDate)
    return 1
}

#if DEBUG
private let showMyDict: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let notification = skin.toNSObject(atIndex: 1) as! NSUserNotification

    let fromNotificationItself = lua_gettop(L) > 1 ? (lua_toboolean(L, 2) != 0) : false

    if fromNotificationItself {
        skin.pushNSObject(notification.userInfo as NSDictionary?)
    } else {
        let gus = notification.userInfo?[KEY_ID] as? String
        skin.pushNSObject(gus != nil ? ourNotificationSpecifics[gus!] : nil)
    }
    return 1
}
#endif

// MARK: - Module Constants

private func notification_activationTypesTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

private func pushNSUserNotification(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let value = obj as! NSUserNotification

    if let userInfoDict = value.userInfo {
        if let gus = userInfoDict[KEY_ID] as? String {
            if let userInfo = ourNotificationSpecifics[gus] as? NSMutableDictionary {
                let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                userInfo[KEY_SELFREFCOUNT] = NSNumber(value: selfRefCount + 1)
            } else {
                if userInfoDict[KEY_DELIVERED] != nil { // it's a holdover from a reload/relaunch
                    ourNotificationSpecifics[gus] = (userInfoDict as NSDictionary).mutableCopy()
                    let userInfo = ourNotificationSpecifics[gus] as! NSMutableDictionary
                    userInfo[KEY_SELFREFCOUNT] = NSNumber(value: 1)
                }
            }
        } // else not ours -- how does it exist?
    } // else not ours (probably from core app)
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toNSUserNotificationFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return getNotification(L, idx)
    } else {
        skin.logError("expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))!))")
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private let userdata_tostring: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at: 1, toClass: "NSUserNotification") as! NSUserNotification
    let title = obj.title ?? ""
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject(NSString(string: "\(USERDATA_TAG): \(title) (\(String(describing: ptr)))"))
    return 1
}

private let userdata_eq: lua_CFunction = { L in
    // can't get here if at least one of us isn't a userdata type, and we only care if both types are ours,
    // so use luaL_testudata before the macro causes a lua error
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "NSUserNotification") as! NSUserNotification
        let obj2 = skin.luaObject(at: 2, toClass: "NSUserNotification") as! NSUserNotification
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private let userdata_gc: lua_CFunction = { L in
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<NSUserNotification>.fromOpaque(rawPtr).takeRetainedValue()

        if let userInfoDict = obj.userInfo {
            if let gus = userInfoDict[KEY_ID] as? String { // it's ours
                if let userInfo = ourNotificationSpecifics[gus] as? NSMutableDictionary { // and we have a record for it
                    let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                    userInfo[KEY_SELFREFCOUNT] = NSNumber(value: selfRefCount - 1)
                    if selfRefCount == 0 {
                        ourNotificationSpecifics[gus] = nil
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
private let meta_gc: lua_CFunction = { _ in
    NSUserNotificationCenter.default.delegate = old_delegate
    ourNotificationSpecifics.removeAllObjects()
    ourNotificationSpecifics = nil
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
        luaL_Reg(name: strdup("__tostring"),          func: userdata_tostring),
        luaL_Reg(name: strdup("__eq"),                func: userdata_eq),
        luaL_Reg(name: strdup("__gc"),                func: userdata_gc),
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
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

@_cdecl("luaopen_hs_libnotify")
public func luaopen_hs_libnotify(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    _ = notification_activationTypesTable(L)
    lua_setfield(L, -2, "activationTypes")

/// hs.notify.defaultNotificationSound
/// Constant
/// The string representation of the default notification sound. Use `hs.notify:soundName()` or set the `soundName` attribute in `hs:notify.new()`, to this constant, if you want to use the default sound
    lua_pushstring(L, NSUserNotificationDefaultSoundName)
    lua_setfield(L, -2, "defaultNotificationSound")

    skin.registerPushNSHelper(pushNSUserNotification, forClass: "NSUserNotification")
    skin.registerLuaObjectHelper(toNSUserNotificationFromLua, forClass: "NSUserNotification",
                                 withUserdataMapping: USERDATA_TAG)

    notification_delegate_setup()
    ourNotificationSpecifics = NSMutableDictionary()

    return 1
}
