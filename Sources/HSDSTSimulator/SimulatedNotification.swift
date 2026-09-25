import Foundation
import HSDSTCore

// Tracking keys shared with the hs.notify module layer (KEY_ALWAYSPRESENT is
// defined in HSSwiftExtensions/Notify.swift; redefine locally since
// HSDSTSimulator cannot import the app extension target).
private let KEY_ALWAYSPRESENT = "alwaysPresent"

public final class SimulatedNotification: NotificationProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    private var observers: [(token: AnyObject, name: String, handler: ([String: Any]) -> Void)] = []
    private var distributedObservers: [(token: AnyObject, name: String?, object: String?, handler: (_ name: String, _ object: String?, _ userInfo: [String: Any]?) -> Void)] = []
    private var workspaceObservers: [(token: AnyObject, name: String, handler: ([String: Any]) -> Void)] = []
    public var postedNotifications: [(name: String, userInfo: [String: Any]?)] = []
    public var deliveredNotifs: [UserNotification] = []
    public var scheduledNotifs: [UserNotification] = []
    public var userNotificationCallbacks: [String: (UserNotification) -> Void] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func addObserver(name: String, object: AnyObject?,
                            handler: @escaping ([String: Any]) -> Void) -> any NotificationObserverToken {
        let token = NSObject()
        observers.append((token: token, name: name, handler: handler))
        return token
    }

    public func removeObserver(_ token: any NotificationObserverToken) {
        observers.removeAll { $0.token === token }
        distributedObservers.removeAll { $0.token === token }
        workspaceObservers.removeAll { $0.token === token }
    }

    public func post(name: String, object: AnyObject?, userInfo: [String: Any]?) {
        postedNotifications.append((name: name, userInfo: userInfo))
        if rng.boolean(probability: faults.notificationDropProbability) { return }
        for entry in observers where entry.name == name {
            entry.handler(userInfo ?? [:])
        }
    }

    public func addDistributedObserver(name: String?, object: String?,
                                       handler: @escaping (_ name: String, _ object: String?, _ userInfo: [String: Any]?) -> Void) -> any NotificationObserverToken {
        let token = NSObject()
        distributedObservers.append((token: token, name: name, object: object, handler: handler))
        return token
    }

    public func postDistributed(name: String, object: String?, userInfo: [String: Any]?) {
        postedNotifications.append((name: name, userInfo: userInfo))
        if rng.boolean(probability: faults.notificationDropProbability) { return }
        for entry in distributedObservers {
            if let filterName = entry.name, filterName != name { continue }
            if let filterObj = entry.object, filterObj != object { continue }
            entry.handler(name, object, userInfo)
        }
    }

    public func addWorkspaceObserver(name: String, object: AnyObject?,
                                     handler: @escaping ([String: Any]) -> Void) -> any NotificationObserverToken {
        let token = NSObject()
        workspaceObservers.append((token: token, name: name, handler: handler))
        return token
    }

    public func postWorkspace(name: String, userInfo: [String: Any]?) {
        if rng.boolean(probability: faults.notificationDropProbability) { return }
        for entry in workspaceObservers where entry.name == name {
            entry.handler(userInfo ?? [:])
        }
    }

    public func deliverUserNotification(_ notification: UserNotification) {
        var n = notification
        n.isDelivered = true
        n.actualDeliveryDate = Date()
        deliveredNotifs.append(n)
    }

    /// UN willPresent equivalent: honor KEY_ALWAYSPRESENT from the userInfo
    /// (defaults to true like the production delegate).
    public func presentNotification(_ notification: UserNotification) -> Bool {
        (notification.userInfo[KEY_ALWAYSPRESENT] as? NSNumber)?.boolValue ?? true
    }

    /// Test hook: fire a didReceive-like activation for a delivered
    /// notification. Looks up the registered callback for the identifier
    /// (usually the notify delegate's activation handler) and invokes it with
    /// the stored notification so tests can exercise the callback path
    /// without the real OS notification center.
    public func activateNotification(identifier: String, actionIdentifier: String?, userText: String?) {
        if let callback = userNotificationCallbacks.removeValue(forKey: identifier) {
            let note = deliveredNotifs.first { $0.identifier == identifier } ?? UserNotification(identifier: identifier)
            callback(note)
            return
        }
        // No registered callback: mark the activation on the stored note so
        // callers reading the simulator state see the response.
        if let idx = deliveredNotifs.firstIndex(where: { $0.identifier == identifier }) {
            deliveredNotifs[idx].activationType = activationType(forAction: actionIdentifier)
            deliveredNotifs[idx].response = userText
        }
    }

    private func activationType(forAction actionIdentifier: String?) -> Int {
        switch actionIdentifier {
        case nil, UserNotificationActionIdentifier.defaultAction:
            return 1 // contentsClicked
        case UserNotificationActionIdentifier.dismissAction:
            return 0 // none
        case UserNotificationActionIdentifier.actionButton:
            return 2 // actionButtonClicked
        case UserNotificationActionIdentifier.reply:
            return 3 // replied
        default:
            return 4 // additionalActionClicked
        }
    }

    public func scheduleUserNotification(_ notification: UserNotification) {
        scheduledNotifs.append(notification)
    }

    public func removeDeliveredUserNotification(identifier: String) {
        deliveredNotifs.removeAll { $0.identifier == identifier }
    }

    public func removeScheduledUserNotification(identifier: String) {
        scheduledNotifs.removeAll { $0.identifier == identifier }
    }

    public func removeAllDeliveredUserNotifications() {
        deliveredNotifs.removeAll()
    }

    public func deliveredUserNotifications() -> [UserNotification] {
        deliveredNotifs
    }

    public func scheduledUserNotifications() -> [UserNotification] {
        scheduledNotifs
    }
}
