import AppKit
import HSDSTCore

final class ProductionNotification: NotificationProtocol {
    func addObserver(name: String, object: AnyObject?,
                     handler: @escaping ([String: Any]) -> Void) -> any NotificationObserverToken {
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: object, queue: .main
        ) { note in
            var info = (note.userInfo as? [String: Any]) ?? [:]
            if let obj = note.object {
                info["__notificationObject"] = obj
            }
            handler(info)
        }
        return observer as AnyObject
    }

    func removeObserver(_ token: any NotificationObserverToken) {
        NotificationCenter.default.removeObserver(token)
    }

    func post(name: String, object: AnyObject?, userInfo: [String: Any]?) {
        NotificationCenter.default.post(name: Notification.Name(name), object: object, userInfo: userInfo)
    }

    func addDistributedObserver(name: String?, object: String?,
                                handler: @escaping (_ name: String, _ object: String?, _ userInfo: [String: Any]?) -> Void) -> any NotificationObserverToken {
        let noteName = name.map { Notification.Name($0) }
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: noteName, object: object, queue: .main
        ) { note in
            handler(note.name.rawValue, note.object as? String, note.userInfo as? [String: Any])
        }
        return observer as AnyObject
    }

    func postDistributed(name: String, object: String?, userInfo: [String: Any]?) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: object, userInfo: userInfo, deliverImmediately: true)
    }

    func addWorkspaceObserver(name: String, object: AnyObject?,
                              handler: @escaping ([String: Any]) -> Void) -> any NotificationObserverToken {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: Notification.Name(name), object: object, queue: .main
        ) { note in
            var info = (note.userInfo as? [String: Any]) ?? [:]
            if let obj = note.object {
                info["__notificationObject"] = obj
            }
            handler(info)
        }
        return observer as AnyObject
    }

    func deliverUserNotification(_ notification: UserNotification) {
        let n = NSUserNotification()
        n.title = notification.title
        n.subtitle = notification.subtitle
        n.informativeText = notification.informativeText
        n.soundName = notification.soundName
        n.hasActionButton = notification.hasActionButton
        n.actionButtonTitle = notification.actionButtonTitle
        n.otherButtonTitle = notification.otherButtonTitle
        n.hasReplyButton = notification.hasReplyButton
        NSUserNotificationCenter.default.deliver(n)
    }

    func scheduleUserNotification(_ notification: UserNotification) {
        let n = NSUserNotification()
        n.title = notification.title
        n.subtitle = notification.subtitle
        n.informativeText = notification.informativeText
        n.soundName = notification.soundName
        NSUserNotificationCenter.default.scheduleNotification(n)
    }

    func removeDeliveredUserNotification(identifier: String) {
        for n in NSUserNotificationCenter.default.deliveredNotifications where n.identifier == identifier {
            NSUserNotificationCenter.default.removeDeliveredNotification(n)
        }
    }

    func removeScheduledUserNotification(identifier: String) {
        for n in NSUserNotificationCenter.default.scheduledNotifications where n.identifier == identifier {
            NSUserNotificationCenter.default.removeScheduledNotification(n)
        }
    }

    func removeAllDeliveredUserNotifications() {
        NSUserNotificationCenter.default.removeAllDeliveredNotifications()
    }

    func deliveredUserNotifications() -> [UserNotification] {
        NSUserNotificationCenter.default.deliveredNotifications.map { n in
            UserNotification(
                identifier: n.identifier ?? "",
                title: n.title ?? "",
                subtitle: n.subtitle ?? "",
                informativeText: n.informativeText ?? "",
                soundName: n.soundName,
                hasActionButton: n.hasActionButton,
                actionButtonTitle: n.actionButtonTitle ?? "Show",
                otherButtonTitle: n.otherButtonTitle ?? "Close",
                hasReplyButton: n.hasReplyButton,
                isDelivered: true,
                isPresented: n.isPresented,
                actualDeliveryDate: n.actualDeliveryDate
            )
        }
    }

    func scheduledUserNotifications() -> [UserNotification] {
        NSUserNotificationCenter.default.scheduledNotifications.map { n in
            UserNotification(
                identifier: n.identifier ?? "",
                title: n.title ?? "",
                subtitle: n.subtitle ?? "",
                informativeText: n.informativeText ?? "",
                soundName: n.soundName
            )
        }
    }
}
