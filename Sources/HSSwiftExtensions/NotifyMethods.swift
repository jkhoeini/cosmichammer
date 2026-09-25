import Cocoa
import CLua
import Lua
import os.log
import HSDSTCore

// MARK: - Module Methods

private func nt_pushNSImageOrNil(_ L: UnsafeMutablePointer<lua_State>!, _ image: NSImage?) {
    guard let image = image else {
        lua_pushnil(L)
        return
    }
    if NSImage_tolua(L, image) == 0 {
        lua_pushnil(L)
    }
}

// MARK: Shared getter/setter scaffolding

private func nt_wrapper(_ L: LuaState, _ idx: Int32) -> HSNotifyObject {
    nt_getNotification(L, idx)
}

/// Resolve the wrapper and its tracking record for a module method.
/// Returns nil record when the notification was not created by this module.
private func nt_recordFor(_ wrapper: HSNotifyObject) -> NSMutableDictionary? {
    if let record = wrapper.record { return record }
    guard let gus = wrapper.note.userInfo[KEY_ID] as? String else { return nil }
    if nt_specifics == nil { return nil }
    let record = nt_specifics[gus] as? NSMutableDictionary
    wrapper.record = record
    return record
}

private func nt_isLocked(_ record: NSMutableDictionary?) -> Bool {
    (record?[KEY_LOCKED] as? NSNumber)?.boolValue ?? false
}

private func nt_lockedError() -> String {
    "notification has been dispatched and can no longer be modified"
}

private func nt_notOursError() -> String {
    "notification was not created by this module"
}

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
func notification_send(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    guard let gus = wrapper.note.userInfo[KEY_ID] as? String else {
        throw L.error(nt_notOursError())
    }
    guard let userInfo = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary) else {
        throw L.error(nt_notOursError())
    }
    wrapper.record = userInfo
    userInfo[KEY_DELIVERED] = false
    userInfo[KEY_LOCKED] = true
    // Snapshot the content config into the record so the userInfo copied into
    // the UN content restores it when the record is recreated after a reload.
    nt_recordContentConfig(userInfo, wrapper.note)
    wrapper.note.userInfo = (userInfo.copy() as! NSDictionary) as? [String: Any] ?? wrapper.note.userInfo

    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
    var note = wrapper.note
    note.isDelivered = false
    note.isPresented = false
    wrapper.note = note
    notification.deliverUserNotification(wrapper.note)

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
func notification_scheduleNotification(_ L: LuaState) throws -> CInt {
    let wrapper = nt_wrapper(L, 1)

    let myDate: Date?
    if lua_isnumber(L, 2) != 0 {
        myDate = Date(timeIntervalSince1970: lua_tonumber(L, 2))
    } else if lua_isstring(L, 2) != 0 {
        myDate = nt_date_from_string(String(cString: lua_tostring(L, 2)!))
    } else {
        myDate = nil
    }

    guard let date = myDate else {
        throw L.error("-- \(nt_USERDATA_TAG):schedule: improper date specified: must be a number (# of seconds since 1970-01-01 00:00:00Z) or string in the format of 'YYYY-MM-DD[T]HH:MM:SS[Z]' (rfc3339)")
    }

    guard let gus = wrapper.note.userInfo[KEY_ID] as? String else {
        throw L.error(nt_notOursError())
    }
    guard let userInfo = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary) else {
        throw L.error(nt_notOursError())
    }
    wrapper.record = userInfo
    userInfo[KEY_DELIVERED] = false
    userInfo[KEY_LOCKED] = true
    nt_recordContentConfig(userInfo, wrapper.note)
    wrapper.note.userInfo = (userInfo.copy() as! NSDictionary) as? [String: Any] ?? wrapper.note.userInfo

    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
    var note = wrapper.note
    note.deliveryDate = date
    note.isDelivered = false
    note.isPresented = false
    wrapper.note = note
    notification.scheduleUserNotification(wrapper.note)

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
func notification_withdraw(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification

    if let gus = wrapper.note.userInfo[KEY_ID] as? String {
        guard let userInfo = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary) else {
            throw L.error(nt_notOursError())
        }
        wrapper.record = userInfo
        let isLocked = (userInfo[KEY_LOCKED] as? NSNumber)?.boolValue ?? false

        if isLocked {
            notification.removeDeliveredUserNotification(identifier: gus)
            notification.removeScheduledUserNotification(identifier: gus)
            nt_cancelWithdrawTimer(gus: gus)

            userInfo[KEY_DELIVERED] = false
            userInfo[KEY_LOCKED] = false
            var note = wrapper.note
            note.isDelivered = false
            note.isPresented = false
            note.userInfo = [KEY_ID: gus]
            wrapper.note = note
        } else {
            throw L.error("notification has not yet been dispatched and cannot be withdrawn")
        }
    } else { // not ours, but withdraw anyways
        notification.removeDeliveredUserNotification(identifier: wrapper.note.identifier)
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
func notification_title(_ L: LuaState) throws -> CInt {
    try nt_genericStringMethod(L, read: { $0.title }, write: { $0.title = $1 ?? "" }, recordKey: KEY_TITLE)
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
func notification_subtitle(_ L: LuaState) throws -> CInt {
    try nt_genericStringMethod(L, read: { $0.subtitle }, write: { $0.subtitle = $1 ?? "" }, recordKey: KEY_SUBTITLE)
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
func notification_informativeText(_ L: LuaState) throws -> CInt {
    try nt_genericStringMethod(L, read: { $0.informativeText }, write: { $0.informativeText = $1 ?? "" }, recordKey: KEY_INFORMATIVETEXT)
}

/// Shared string attribute method: getter reads the wrapper's UserNotification;
/// setter applies to both the wrapper and the tracking record, honoring the
/// lock/ownership checks.
private func nt_genericStringMethod(
    _ L: LuaState,
    read: (UserNotification) -> String?,
    write: (inout UserNotification, String?) -> Void,
    recordKey: String? = nil
) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        lua_pushany(L, read(wrapper.note) as NSString?)
    } else if let gus, record != nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        var note = wrapper.note
        let newValue: String? = lua_isnil(L, 2) ? nil : (lua_tovalue(L, at: 2) as? String ?? "")
        write(&note, newValue)
        wrapper.note = note
        if let recordKey, let record {
            record[recordKey] = newValue ?? NSNull()
        }
        lua_pushvalue(L, 1)
    } else if gus != nil && record == nil {
        // Not tracked: still apply to the wrapper note.
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        var note = wrapper.note
        let newValue: String? = lua_isnil(L, 2) ? nil : (lua_tovalue(L, at: 2) as? String ?? "")
        write(&note, newValue)
        wrapper.note = note
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_actionButtonTitle(_ L: LuaState) throws -> CInt {
    try nt_genericStringMethod(L, read: { $0.actionButtonTitle }, write: { $0.actionButtonTitle = $1 ?? "" }, recordKey: KEY_ACTIONBUTTON_TITLE)
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
func notification_otherButtonTitle(_ L: LuaState) throws -> CInt {
    // UserNotifications has no "other button" concept; keep the Lua API but the
    // value is stored locally and never rendered by the OS.
    try nt_genericStringMethod(L, read: { $0.otherButtonTitle }, write: { $0.otherButtonTitle = $1 ?? "" })
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
func notification_hasActionButton(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        L.push(wrapper.note.hasActionButton)
    } else if let gus, record != nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        var note = wrapper.note
        note.hasActionButton = lua_toboolean(L, 2) != 0
        wrapper.note = note
        record?[KEY_HASACTIONBUTTON] = NSNumber(value: note.hasActionButton)
        lua_pushvalue(L, 1)
    } else if gus != nil && record == nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        var note = wrapper.note
        note.hasActionButton = lua_toboolean(L, 2) != 0
        wrapper.note = note
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_alwaysPresent(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        if gus != nil {
            let alwaysPresent = (record?[KEY_ALWAYSPRESENT] as? NSNumber)?.boolValue ?? true
            L.push(alwaysPresent)
        } else {
            lua_pushnil(L)
        }
    } else if let gus, record != nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        record?[KEY_ALWAYSPRESENT] = lua_toboolean(L, 2)
        lua_pushvalue(L, 1)
    } else if gus != nil && record == nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        // Not tracked; the alwaysPresent state lives in the record only.
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_getFunctionTag(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    if let gus = wrapper.note.userInfo[KEY_ID] as? String {
        let record = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary)
        lua_pushany(L, record?[KEY_FNTAG])
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
func notification_autoWithdraw(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        if gus != nil {
            let autoWithdraw = (record?[KEY_AUTOWITHDRAW] as? NSNumber)?.boolValue ?? true
            L.push(autoWithdraw)
        } else {
            lua_pushnil(L)
        }
    } else if let gus, record != nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        record?[KEY_AUTOWITHDRAW] = lua_toboolean(L, 2)
        lua_pushvalue(L, 1)
    } else if gus != nil && record == nil {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_soundName(_ L: LuaState) throws -> CInt {
    try nt_genericStringMethod(L, read: { $0.soundName }, write: { $0.soundName = $1 }, recordKey: KEY_SOUNDNAME)
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
func notification_contentImage(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        let image: NSImage? = wrapper.note.contentImageData.flatMap { NSImage(data: $0) }
        nt_pushNSImageOrNil(L, image)
    } else if let gus {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        let image = lua_isnil(L, 2) ? nil : toNSImage(L, at: 2)
        var note = wrapper.note
        if let image {
            note.contentImageData = image.tiffRepresentation
        } else {
            note.contentImageData = nil
        }
        wrapper.note = note
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
    }
    return 1
}

// NOTE: THIS FUNCTION IS WRAPPED IN init.lua
func notification_setIdImage(_ L: LuaState) throws -> CInt {
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if let gus {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        guard toNSImage(L, at: 2) != nil else {
            throw L.error("expected hs.image userdata for argument 2")
        }
        // UNUserNotificationCenter has no per-notification identification image
        // API backing this option is gone with the NS chain);
        // the image is accepted but has no effect.
        NSLog("%@:setIdImage() is not supported by UserNotifications; the image is stored but not rendered", nt_USERDATA_TAG)
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_hasReplyButton(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        L.push(wrapper.note.hasReplyButton)
    } else if let gus {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        var note = wrapper.note
        note.hasReplyButton = lua_toboolean(L, 2) != 0
        wrapper.note = note
        record?[KEY_HASREPLYBUTTON] = NSNumber(value: note.hasReplyButton)
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_alwaysShowAdditionalActions(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    // The private API backing this option is gone with the
    // NS chain; the option is accepted but has no effect under UserNotifications.
    if lua_isnone(L, 2) {
        L.push(false)
    } else if let gus {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        NSLog("%@:alwaysShowAdditionalActions() is not supported by UserNotifications; the setting is accepted but has no effect", nt_USERDATA_TAG)
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_withdrawAfter(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_isnone(L, 2) {
        if gus != nil {
            lua_pushany(L, record?[KEY_WITHDRAWAFTER])
        } else {
            lua_pushnil(L)
        }
    } else if let gus {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        let value = lua_tovalue(L, at: 2)
        if let number = value as? NSNumber {
            // Cancel/replace any pending timer only when already dispatched;
            // the timer itself is scheduled at send()/activation time.
            if (record?[KEY_LOCKED] as? NSNumber)?.boolValue == true, number.doubleValue <= 0 {
                nt_cancelWithdrawTimer(gus: gus)
            }
        }
        record?[KEY_WITHDRAWAFTER] = value
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_responsePlaceholder(_ L: LuaState) throws -> CInt {
    try nt_genericStringMethod(L, read: { $0.responsePlaceholder.isEmpty ? nil : $0.responsePlaceholder }, write: { $0.responsePlaceholder = $1 ?? "" }, recordKey: KEY_RESPONSEPLACEHOLDER)
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
func notification_response(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    if let response = wrapper.note.response {
        // since placeholder is a string, and there are no tools to edit within the reply, let's leave it as a string unless someone cares.
        lua_pushany(L, response as NSString)
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
func notification_additionalActions(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)
    let record = nt_recordFor(wrapper)
    let gus = wrapper.note.userInfo[KEY_ID] as? String

    if lua_gettop(L) == 1 {
        let actions = wrapper.note.additionalActions
        lua_newtable(L)
        for (i, action) in actions.enumerated() {
            lua_pushany(L, action.title as NSString?)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
    } else if let gus {
        if nt_isLocked(record) {
            throw L.error(nt_lockedError())
        }
        let actions = lua_tovalue(L, at: 2) as? [Any]
        var newActions: [(identifier: String, title: String)] = []
        var errorMsg: String? = nil

        if let actions {
            for (idx, item) in actions.enumerated() {
                guard let str = item as? String else {
                    errorMsg = "expected string at index \(idx + 1)"
                    break
                }
                newActions.append((identifier: str, title: str))
            }
        } else {
            errorMsg = "expected a table containing an array of strings"
        }
        if let errorMsg {
            throw L.error("bad argument #2: \(errorMsg)")
        }
        var note = wrapper.note
        note.additionalActions = newActions
        wrapper.note = note
        record?[KEY_ADDITIONALACTIONS] = newActions.map {
            ["identifier": $0.identifier, "title": $0.title]
        }
        lua_pushvalue(L, 1)
    } else {
        throw L.error(nt_notOursError())
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
func notification_additionalActivationAction(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    if let action = wrapper.note.additionalActivationAction {
        lua_pushany(L, action as NSString)
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
func notification_presented(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    L.push(wrapper.note.isPresented)
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
func notification_delivered(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    if let gus = wrapper.note.userInfo[KEY_ID] as? String {
        let record = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary)
        wrapper.record = record
        let delivered = (record?[KEY_DELIVERED] as? NSNumber)?.boolValue ?? false
        L.push(delivered)
    } else {
        let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
        L.push(notification.deliveredUserNotifications().contains { $0.identifier == wrapper.note.identifier })
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
func notification_activationType(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    L.push(lua_Integer(wrapper.note.activationType))
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
func notification_actualDeliveryDate(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    lua_pushany(L, wrapper.note.actualDeliveryDate)
    return 1
}

#if DEBUG
func showMyDict(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, nt_USERDATA_TAG)
    let wrapper = nt_wrapper(L, 1)

    let fromNotificationItself = lua_gettop(L) > 1 ? (lua_toboolean(L, 2) != 0) : false

    if fromNotificationItself {
        lua_pushany(L, wrapper.note.userInfo as NSDictionary?)
    } else {
        let gus = wrapper.note.userInfo[KEY_ID] as? String
        lua_pushany(L, gus != nil && nt_specifics != nil ? nt_specifics[gus!] : nil)
    }
    return 1
}
#endif
