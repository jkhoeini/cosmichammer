import Cocoa
import CLua
import Lua
import os.log
import HSDSTCore
import UserNotifications

// Migrated off the deprecated NS-era notification APIs;
// all delivery now goes through NotificationProtocol (UNUserNotificationCenter in
// production, SimulatedNotification under DST tests).

// MARK: - Constants

let nt_USERDATA_TAG = "hs.notify"
var nt_refTable: Int32 = LUA_NOREF

// UN has no "default notification sound" constant (the NS-era
// DefaultSoundName constant was removed); keep the same Lua-visible string value.
let UserNotificationDefaultSoundName = "DefaultSoundName"

// Record of per-notification state, keyed to the unique id (gus) added when the
// notification is created (see notification_new). The authoritative live copy is
// the wrapper's UserNotification; this dictionary carries the Lua-visible
// tracking state (locked/fntag/...) plus a content snapshot copied into the
// UN content userInfo so a reload-recreated record restores it.
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
let KEY_ACTIVATIONTYPE        = "activationType"
let KEY_RESPONSE              = "response"
let KEY_ADDITIONALACTIVATION  = "additionalActivationAction"
let KEY_TITLE                 = "title"
let KEY_SUBTITLE              = "subTitle"
let KEY_INFORMATIVETEXT       = "informativeText"
let KEY_SOUNDNAME             = "soundName"
let KEY_HASACTIONBUTTON       = "hasActionButton"
let KEY_ACTIONBUTTON_TITLE    = "actionButtonTitle"
let KEY_HASREPLYBUTTON        = "hasReplyButton"
let KEY_RESPONSEPLACEHOLDER   = "responsePlaceholder"
let KEY_ADDITIONALACTIONS     = "additionalActions"

// Pending withdrawAfter timers, keyed by gus id. UNUserNotificationCenter has no
// per-notification withdrawal timer, so hs.notify:withdrawAfter() schedules a
// DispatchWorkItem on the main queue here.
var nt_withdrawTimers: [String: DispatchWorkItem] = [:]

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

// MARK: - Wrapper class held by the userdata

/// Strong table keeping live HSNotifyObject wrappers reachable from the delegate
/// path (which only has the gus string). Keyed by gus id.
var nt_wrapperRegistry: NSMutableDictionary?

/// The userdata box for hs.notify. UserNotification is a Swift struct, so the
/// userdata must hold a class wrapper; the Unmanaged retained-pointer model
/// (instead of Metatable<T> boilerplate) is preserved.
final class HSNotifyObject: NSObject {
    var note: UserNotification
    /// Local record (nt_specifics entry) for Lua-visible tracking state.
    var record: NSMutableDictionary?

    init(note: UserNotification, record: NSMutableDictionary? = nil) {
        self.note = note
        self.record = record
    }
}

// MARK: - Support Functions and Classes

/// Activation handling for hs.notify notifications. Not the UN delegate itself:
/// MJUserNotificationManager is the process-wide UNUserNotificationCenter
/// delegate (UN has a single delegate slot) and forwards hs.notify responses
/// here. The UN center calls delegates on a secondary queue, so all Lua work is
/// marshaled onto the main run loop (see Websocket.swift's performLuaWork).
final class HSModuleNotificationManager: NSObject {
    static let shared = HSModuleNotificationManager()

    /// Marshal Lua callback work onto the main run loop. The Lua host pumps the
    /// main run loop; DispatchQueue.main.async is not reliably drained by the
    /// Swift test harness polling loop, so use RunLoop.main.perform off-main.
    private func performOnMainRunLoop(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            RunLoop.main.perform(work)
        }
    }

    /// Entry from the process UN delegate (MJUserNotificationManager) for a
    /// notification response on an hs.notify notification.
    func handleActivationResponse(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        guard let gus = content.userInfo[KEY_ID] as? String else { return }

        // UN invokes its delegate off-main. All module state and Lua work stays
        // serialized on the main run loop.
        let activationType = nt_activationType(
            for: response.actionIdentifier,
            category: content.categoryIdentifier
        )
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        performOnMainRunLoop {
            if nt_specifics == nil { nt_specifics = NSMutableDictionary() }
            if nt_specifics[gus] == nil {
                nt_specifics[gus] = (content.userInfo as NSDictionary).mutableCopy()
            }
            guard let record = nt_specifics[gus] as? NSMutableDictionary else { return }
            record[KEY_DELIVERED] = true
            record[KEY_ACTIVATIONTYPE] = NSNumber(value: activationType)
            if response.actionIdentifier == UserNotificationActionIdentifier.reply, let userText {
                record[KEY_RESPONSE] = userText
            }
            if let additional = nt_additionalActivationAction(
                for: response.actionIdentifier,
                category: content.categoryIdentifier
            ) {
                record[KEY_ADDITIONALACTIVATION] = additional
            }
            nt_handleActivation(
                gus: gus,
                activationType: activationType,
                delivered: true,
                record: record,
                actionIdentifier: response.actionIdentifier,
                userText: userText
            )
        }
    }

    /// Entry from the process UN delegate for a notification shown while the
    /// app is frontmost. Returns whether to present (alwaysPresent honored).
    func presentationDecision(identifier: String, userInfo: [AnyHashable: Any], deliveryDate: Date) -> Bool {
        if userInfo["MJNotification"] != nil {
            return true
        }
        guard let gus = userInfo[KEY_ID] as? String else { return false }

        let alwaysPresent = (userInfo[KEY_ALWAYSPRESENT] as? NSNumber)?.boolValue ?? true
        performOnMainRunLoop {
            if nt_specifics == nil { nt_specifics = NSMutableDictionary() }
            if nt_specifics[gus] == nil {
                nt_specifics[gus] = (userInfo as NSDictionary).mutableCopy()
            }
            (nt_specifics[gus] as? NSMutableDictionary)?[KEY_DELIVERED] = true
            nt_recordPresentation(gus: gus, presented: alwaysPresent, deliveryDate: deliveryDate)
        }
        return alwaysPresent
    }

    /// Test hook mirroring the didReceive response path for the DST simulator:
    /// runs the same activation handling the process delegate performs for a
    /// real UNNotificationResponse. Tests drive this via
    /// SimulatedNotification.activateNotification.
    func testActivationFromSimulator(
        gus: String,
        activationType: Int,
        delivered: Bool,
        record: NSMutableDictionary,
        actionIdentifier: String?,
        userText: String?
    ) {
        record[KEY_DELIVERED] = delivered
        record[KEY_ACTIVATIONTYPE] = NSNumber(value: activationType)
        if actionIdentifier == UserNotificationActionIdentifier.reply, let userText {
            record[KEY_RESPONSE] = userText
        }
        nt_handleActivation(
            gus: gus,
            activationType: activationType,
            delivered: delivered,
            record: record,
            actionIdentifier: actionIdentifier,
            userText: userText
        )
    }
}

/// Recreate/refresh the wrapper-side state for a delivered notification.
/// Marshaled to the main run loop by the delegate path.
private func nt_recordPresentation(gus: String, presented: Bool, deliveryDate: Date) {
    if nt_specifics == nil { nt_specifics = NSMutableDictionary() }
    let userInfo = nt_specifics[gus] as? NSMutableDictionary
    userInfo?[KEY_DELIVERED] = true
    guard let wrapper = nt_wrapperRegistry?[gus] as? HSNotifyObject else { return }
    wrapper.note.isDelivered = true
    wrapper.note.isPresented = presented
    if wrapper.note.actualDeliveryDate == nil {
        wrapper.note.actualDeliveryDate = deliveryDate
    }
}

/// Map a UN action identifier + category to the hs.notify numeric activation type.
func nt_activationType(for actionIdentifier: String?, category: String?) -> Int {
    UserNotificationSemantics.activationType(
        actionIdentifier: actionIdentifier,
        categoryIdentifier: category
    )
}

/// Extract the selected additional action title from an
/// "hs.notify.<identifier>" action identifier scoped by the category.
private func nt_additionalActivationAction(for actionIdentifier: String?, category: String?) -> String? {
    guard let actionIdentifier, actionIdentifier.hasPrefix("hs.notify."),
          actionIdentifier != UserNotificationActionIdentifier.actionButton,
          actionIdentifier != UserNotificationActionIdentifier.reply,
          let category, category.hasPrefix("hs.notify.category.") else { return nil }
    return String(actionIdentifier.dropFirst("hs.notify.".count))
}

// MARK: - Activation handling

/// Handle a notification activation: sync the wrapper state, look up the
/// callback tag, call hs.notify._tag_handler through luaTelemetryPCall, honor
/// autoWithdraw. Runs on the main thread/run loop.
func nt_handleActivation(
    gus: String,
    activationType: Int,
    delivered: Bool,
    record: NSMutableDictionary,
    actionIdentifier: String?,
    userText: String?
) {
    guard record[KEY_FNTAG] != nil else { return }

    // Sync the activation state onto the live wrapper so the getters
    // (activationType/response/...) observe the recorded values.
    if let wrapper = nt_wrapperRegistry?[gus] as? HSNotifyObject {
        wrapper.note.activationType = (record[KEY_ACTIVATIONTYPE] as? NSNumber)?.intValue ?? wrapper.note.activationType
        if let response = record[KEY_RESPONSE] as? String {
            wrapper.note.response = response
        }
        if let additional = record[KEY_ADDITIONALACTIVATION] as? String {
            wrapper.note.additionalActivationAction = additional
        }
        if delivered {
            wrapper.note.isDelivered = true
        }
    }

    let L = lua_getCurrentState()!
    let requireType = lua_getglobal(L, "require")
    guard requireType == LUA_TFUNCTION else {
        lua_pop(L, 1) // pop the non-function value
        NSLog("%@:_didActivateNotification - require is unavailable", nt_USERDATA_TAG)
        return
    }
    L.push(nt_USERDATA_TAG)
    if lua_pcall(L, 1, 1, 0) != LUA_OK {
        NSLog("%@:_didActivateNotification - unable to load tag handler: %@", nt_USERDATA_TAG, String(cString: lua_tostring(L, -1)!))
        lua_pop(L, 1) // remove error message
        return
    }
    lua_getfield(L, -1, "_tag_handler") // now we know the function hs.notify._tag_handler is on the stack...
    lua_pushany(L, record[KEY_FNTAG])
    nt_pushNotification(L, gus: gus)

    if luaTelemetryPCall(
        L,
        nargs: 2,
        nresults: 0,
        callbackName: "hs.notify.activation",
        attributes: [
            "notification.delivered": delivered,
            "notification.has_action": activationType != 0,
        ]
    ) != LUA_OK {
        lua_pop(L, 1) // pop error message
        lua_pop(L, 1) // pop the hs.notify module
        return
    }
    lua_pop(L, 1) // pop the hs.notify module

    let shouldWithdraw = (record[KEY_AUTOWITHDRAW] as? NSNumber)?.boolValue ?? true
    if shouldWithdraw {
        let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
        notification.removeDeliveredUserNotification(identifier: gus)
        notification.removeScheduledUserNotification(identifier: gus)
        // Cancel any pending withdrawAfter timer; activation wins.
        nt_cancelWithdrawTimer(gus: gus)
    }
}

// MARK: - withdrawAfter timers

func nt_scheduleWithdrawTimer(
    gus: String,
    after seconds: Double,
    from deliveryTime: Date? = nil,
    notification: any NotificationProtocol
) {
    nt_cancelWithdrawTimer(gus: gus)
    let item = DispatchWorkItem {
        notification.removeDeliveredUserNotification(identifier: gus)
        if let specifics = nt_specifics,
           let userInfo = specifics[gus] as? NSMutableDictionary {
            userInfo[KEY_DELIVERED] = false
        }
        if let wrapper = nt_wrapperRegistry?[gus] as? HSNotifyObject {
            wrapper.note.isDelivered = false
            wrapper.note.isPresented = false
        }
        nt_withdrawTimers[gus] = nil
    }
    nt_withdrawTimers[gus] = item
    let delay = deliveryTime.map { max(0, $0.timeIntervalSinceNow) + seconds } ?? seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
}

func nt_cancelWithdrawTimer(gus: String) {
    if let item = nt_withdrawTimers.removeValue(forKey: gus) {
        item.cancel()
    }
}


/// Copy the wrapper's content configuration into the record so the userInfo
/// copied into the UN content restores it when the record is recreated after a
/// reload (the UN content only carries userInfo across relaunches).
func nt_recordContentConfig(_ userInfo: NSMutableDictionary, _ note: UserNotification) {
    userInfo[KEY_TITLE] = note.title
    userInfo[KEY_SUBTITLE] = note.subtitle
    userInfo[KEY_INFORMATIVETEXT] = note.informativeText
    if let soundName = note.soundName {
        userInfo[KEY_SOUNDNAME] = soundName
    } else {
        userInfo.removeObject(forKey: KEY_SOUNDNAME)
    }
    userInfo[KEY_HASACTIONBUTTON] = NSNumber(value: note.hasActionButton)
    userInfo[KEY_ACTIONBUTTON_TITLE] = note.actionButtonTitle
    userInfo[KEY_HASREPLYBUTTON] = NSNumber(value: note.hasReplyButton)
    userInfo[KEY_RESPONSEPLACEHOLDER] = note.responsePlaceholder
    userInfo[KEY_ADDITIONALACTIONS] = note.additionalActions.map {
        ["identifier": $0.identifier, "title": $0.title]
    }
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

func nt_getNotification(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSNotifyObject {
    let ptr = luaL_checkudata(L, idx, nt_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    return Unmanaged<HSNotifyObject>.fromOpaque(ptr.pointee!).takeUnretainedValue()
}

func nt_pushNotificationArray(_ L: UnsafeMutablePointer<lua_State>!, _ notifications: [UserNotification]) {
    lua_newtable(L)
    for (idx, notification) in notifications.enumerated() {
        nt_pushNotification(L, note: notification)
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
    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
    notification.removeAllDeliveredUserNotifications()
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
    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
    for note in notification.scheduledUserNotifications() {
        notification.removeScheduledUserNotification(identifier: note.identifier)
    }
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
    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
    let deliveredNotifications = notification.deliveredUserNotifications()

    nt_pushNotificationArray(L, deliveredNotifications)
    // just in case pushNotification had to recreate our entries in nt_specifics
    for note in deliveredNotifications {
        if note.userInfo[KEY_ID] is String {
            if let userInfo = nt_specifics[note.identifier] as? NSMutableDictionary {
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
    let notification = environmentGetGlobalOrNil()?.notification ?? environmentGet(L).notification
    nt_pushNotificationArray(L, notification.scheduledUserNotifications())
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

    // UN presents the notification content's title; the Lua layer defaults it
    // to "Notification" (see notify.lua module.new), but a raw _new() call
    // yields an empty title like the old NS-era object did.
    let notification = UserNotification(
        identifier: gus,
        title: "",
        subtitle: "",
        informativeText: "",
        soundName: nil,
        hasActionButton: false,
        actionButtonTitle: "",
        otherButtonTitle: "",
        hasReplyButton: false,
        userInfo: [KEY_ID: gus]
    )

    nt_pushNotification(L, note: notification, record: userInfo)
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
    L.push(lua_Integer(0))
    lua_setfield(L, -2, "none")
    L.push(lua_Integer(1))
    lua_setfield(L, -2, "contentsClicked")
    L.push(lua_Integer(2))
    lua_setfield(L, -2, "actionButtonClicked")
    L.push(lua_Integer(3))
    lua_setfield(L, -2, "replied")
    L.push(lua_Integer(4))
    lua_setfield(L, -2, "additionalActionClicked")
    return 1
}

// MARK: - Lua<->Wrapper Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from
// delegates and blocks.

func nt_pushNotification(
    _ L: UnsafeMutablePointer<lua_State>!,
    note: UserNotification? = nil,
    record: NSMutableDictionary? = nil,
    gus: String? = nil
) -> Int32 {
    // Resolve the wrapper being pushed: an existing one from the registry, a
    // recreated one from the tracked record (holdover from a reload/relaunch),
    // or a fresh one from the given note.
    if nt_specifics == nil { nt_specifics = NSMutableDictionary() }
    let wrapper: HSNotifyObject
    let candidateGus = gus ?? note?.userInfo[KEY_ID] as? String
    if let candidateGus, let existing = nt_wrapperRegistry?[candidateGus] as? HSNotifyObject {
        wrapper = existing
    } else if let gus, let userInfo = nt_specifics[gus] as? NSMutableDictionary {
        var rebuilt = UserNotification(
            identifier: gus,
            title: userInfo[KEY_TITLE] as? String ?? "",
            subtitle: userInfo[KEY_SUBTITLE] as? String ?? "",
            informativeText: userInfo[KEY_INFORMATIVETEXT] as? String ?? "",
            soundName: userInfo[KEY_SOUNDNAME] as? String,
            hasActionButton: (userInfo[KEY_HASACTIONBUTTON] as? NSNumber)?.boolValue ?? true,
            actionButtonTitle: userInfo[KEY_ACTIONBUTTON_TITLE] as? String ?? "Show",
            otherButtonTitle: "",
            hasReplyButton: (userInfo[KEY_HASREPLYBUTTON] as? NSNumber)?.boolValue ?? false,
            isDelivered: (userInfo[KEY_DELIVERED] as? NSNumber)?.boolValue ?? false,
            isPresented: (userInfo[KEY_DELIVERED] as? NSNumber)?.boolValue ?? false,
            additionalActions: [],
            userInfo: [KEY_ID: gus],
            activationType: (userInfo[KEY_ACTIVATIONTYPE] as? NSNumber)?.intValue ?? 0,
            response: userInfo[KEY_RESPONSE] as? String,
            additionalActivationAction: userInfo[KEY_ADDITIONALACTIVATION] as? String,
            responsePlaceholder: userInfo[KEY_RESPONSEPLACEHOLDER] as? String ?? ""
        )
        if let actions = userInfo[KEY_ADDITIONALACTIONS] as? [[String: String]] {
            rebuilt.additionalActions = actions.compactMap { dict in
                if let id = dict["identifier"], let title = dict["title"] {
                    return (identifier: id, title: title)
                }
                return nil
            }
        }
        wrapper = HSNotifyObject(note: rebuilt, record: userInfo)
    } else {
        guard let note else { return 0 }
        wrapper = HSNotifyObject(note: note, record: record)
    }

    let gus = wrapper.note.identifier
    if wrapper.note.userInfo[KEY_ID] is String { // only track ours
        if nt_wrapperRegistry == nil {
            nt_wrapperRegistry = NSMutableDictionary()
        }
        nt_wrapperRegistry?[gus] = wrapper
    }

    if let userInfo = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary) {
        let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
        userInfo[KEY_SELFREFCOUNT] = NSNumber(value: selfRefCount + 1)
        setNotifyUserdataCounted(userInfo, true, L: L)
        wrapper.record = userInfo
    } else if wrapper.note.userInfo[KEY_DELIVERED] != nil {
        // it's a holdover from a reload/relaunch whose record was never
        // recreated by the delegate path: rebuild it from the wrapper's own
        // state (its userInfo was copied into the UN content at send time).
        let userInfo = NSMutableDictionary(dictionary: wrapper.note.userInfo)
        userInfo[KEY_SELFREFCOUNT] = NSNumber(value: 1)
        userInfo[KEY_ACTIVEGAUGE] = NSNumber(value: false)
        nt_specifics[gus] = userInfo
        setNotifyUserdataCounted(userInfo, true, L: L)
        wrapper.record = userInfo
    } // else not ours (probably from the core app)

    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(wrapper).toOpaque()
    luaL_getmetatable(L, nt_USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func nt_userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = nt_getNotification(L, 1)
    let title = obj.note.title
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
        L.push(obj1.note.identifier == obj2.note.identifier)
    } else {
        L.push(false)
    }
    return 1
}

func nt_userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, nt_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let wrapper = Unmanaged<HSNotifyObject>.fromOpaque(rawPtr).takeRetainedValue()

        if let gus = wrapper.note.userInfo[KEY_ID] as? String, nt_specifics != nil { // it's ours
            if let userInfo = wrapper.record ?? (nt_specifics[gus] as? NSMutableDictionary) { // and we have a record for it
                let selfRefCount = (userInfo[KEY_SELFREFCOUNT] as? NSNumber)?.intValue ?? 0
                let newSelfRefCount = selfRefCount - 1
                userInfo[KEY_SELFREFCOUNT] = NSNumber(value: newSelfRefCount)
                if newSelfRefCount <= 0 {
                    setNotifyUserdataCounted(userInfo, false, L: L)
                    nt_specifics[gus] = nil
                    nt_wrapperRegistry?[gus] = nil
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
    // UNUserNotificationCenter has a single delegate slot shared by the whole
    // process; leave it installed after module gc so notifications delivered
    // while hs.notify is unloaded still route through the activation handler.
    if nt_specifics != nil {
        activeNotifyUserdataCount = 0
        recordActiveNotifyUserdataGauge(L)
        nt_specifics.removeAllObjects()
        nt_specifics = nil
    }
    nt_wrapperRegistry?.removeAllObjects()
    nt_wrapperRegistry = nil
    return 0
}

#if DEBUG
@MainActor
func nt_debugSetSpecificsRecord(_ gus: String, _ userInfo: NSMutableDictionary) {
    guard let specifics = nt_specifics else { return }
    specifics[gus] = userInfo
}

@MainActor
func nt_debugSpecifics() -> NSMutableDictionary? {
    nt_specifics
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
        // NOTE: the wrapper class is stored via Unmanaged raw pointer, so we
        // cannot use Metatable<T>/installMetatableBoilerplate. Manual
        // registration is correct here.
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
            do {
                return try nt_userdata_gc(L)
            } catch {
                // luaL_checkudata failed: nothing to release; just strip the metatable.
                lua_pushnil(L)
                lua_setmetatable(L, 1)
                return 0
            }
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
            do {
                return try nt_meta_gc(L)
            } catch {
                return 0
            }
        }, 0)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        _ = nt_activationTypesTable(L)
        lua_setfield(L, -2, "activationTypes")

    /// hs.notify.defaultNotificationSound
    /// Constant
    /// The string representation of the default notification sound. Use `hs.notify:soundName()` or set the `soundName` attribute in `hs:notify.new()`, to this constant, if you want to use the default sound
        L.push(UserNotificationDefaultSoundName)
        lua_setfield(L, -2, "defaultNotificationSound")

        // Ensure the process-wide UN delegate is installed (no-op under tests;
        // the delegate stays installed for the process lifetime).
        MJUserNotificationManager.sharedManager.installAsDelegateIfNeeded()

        nt_specifics = NSMutableDictionary()
    }
}
