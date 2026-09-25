import AppKit
import CryptoKit
import HSDSTCore
import UserNotifications

final class ProductionNotification: NotificationProtocol {
    private static let categoriesLock = NSLock()
    private static var categories: [String: UNNotificationCategory] = [:]

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

    // MARK: - UNUserNotificationCenter delivery

    private func makeContent(_ notification: UserNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.informativeText
        if let soundName = notification.soundName {
            content.sound = soundName == "DefaultSoundName"
                ? .default
                : UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
        }
        if notification.hasActionButton || notification.hasReplyButton || !notification.additionalActions.isEmpty {
            content.categoryIdentifier = ProductionNotification.categoryIdentifier(
                for: notification
            )
        }
        content.userInfo = notification.userInfo
        return content
    }

    /// Register (or reuse) a UNNotificationCategory describing this
    /// notification's buttons, returning its identifier.
    static func categoryIdentifier(for notification: UserNotification) -> String {
        var actions: [UNNotificationAction] = []
        if notification.hasReplyButton {
            actions.append(UNTextInputNotificationAction(
                identifier: UserNotificationActionIdentifier.reply,
                title: notification.actionButtonTitle.isEmpty ? "Reply" : notification.actionButtonTitle,
                textInputButtonTitle: "Send",
                textInputPlaceholder: notification.responsePlaceholder
            ))
        } else if notification.hasActionButton {
            actions.append(UNNotificationAction(
                identifier: UserNotificationActionIdentifier.actionButton,
                title: notification.actionButtonTitle.isEmpty ? "Show" : notification.actionButtonTitle
            ))
        }
        for action in notification.additionalActions {
            actions.append(UNNotificationAction(
                identifier: "\(UserNotificationSemantics.actionPrefix)\(action.identifier)",
                title: action.title
            ))
        }

        let categoryDescription = actions.map { "\($0.identifier)\u{0}\($0.title)" }
            .joined(separator: "\u{1}") + "\u{2}\(notification.responsePlaceholder)"
        let digest = SHA256.hash(data: Data(categoryDescription.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let id = "\(UserNotificationSemantics.categoryPrefix)\(digest)"
        let category = UNNotificationCategory(
            identifier: id,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        categoriesLock.lock()
        categories[id] = category
        let registeredCategories = Set(categories.values)
        categoriesLock.unlock()
        UNUserNotificationCenter.current().setNotificationCategories(registeredCategories)
        return id
    }

    private func attachment(for notification: UserNotification) throws -> UNNotificationAttachment? {
        guard let imageData = notification.contentImageData else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cosmichammer-notify-\(UUID().uuidString).png")
        try imageData.write(to: url)
        return try UNNotificationAttachment(
            identifier: "contentImage", url: url, options: nil
        )
    }

    /// Request authorization lazily before the first add; a missing/denied
    /// permission must not crash the host — the add call reports the error.
    private func add(_ notification: UserNotification, trigger: UNNotificationTrigger?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("notify: authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("notify: authorization denied by user")
            }
            let content = self.makeContent(notification)
            if let attachment = try? self.attachment(for: notification) {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(
                identifier: notification.identifier, content: content, trigger: trigger
            )
            center.add(request) { error in
                if let error {
                    NSLog("notify: failed to deliver notification: %@", error.localizedDescription)
                }
            }
        }
    }

    func deliverUserNotification(_ notification: UserNotification) {
        add(notification, trigger: nil)
    }

    func scheduleUserNotification(_ notification: UserNotification) {
        guard let date = notification.deliveryDate else {
            // No delivery date: deliver immediately.
            add(notification, trigger: nil)
            return
        }
        var components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        components.timeZone = Calendar.current.timeZone
        add(notification, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    func removeDeliveredUserNotification(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func removeScheduledUserNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func removeAllDeliveredUserNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func deliveredUserNotifications() -> [UserNotification] {
        // UNUserNotificationCenter delegate methods are main-queue; mirror the
        // synchronous NS-era contract by blocking the current (main) thread on
        // the async UN query.
        let center = UNUserNotificationCenter.current()
        var notes: [UserNotification] = []
        if Thread.isMainThread {
            let semaphore = DispatchSemaphore(value: 0)
            center.getDeliveredNotifications { delivered in
                notes = delivered.map { ProductionNotification.note(from: $0) }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.0)
        } else {
            let group = DispatchGroup()
            group.enter()
            center.getDeliveredNotifications { delivered in
                notes = delivered.map { ProductionNotification.note(from: $0) }
                group.leave()
            }
            group.wait()
        }
        return notes
    }

    func scheduledUserNotifications() -> [UserNotification] {
        let center = UNUserNotificationCenter.current()
        var notes: [UserNotification] = []
        if Thread.isMainThread {
            let semaphore = DispatchSemaphore(value: 0)
            center.getPendingNotificationRequests { requests in
                notes = requests.map { ProductionNotification.note(fromPending: $0) }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.0)
        } else {
            let group = DispatchGroup()
            group.enter()
            center.getPendingNotificationRequests { requests in
                notes = requests.map { ProductionNotification.note(fromPending: $0) }
                group.leave()
            }
            group.wait()
        }
        return notes
    }

    func presentNotification(_ notification: UserNotification) -> Bool {
        // The foreground presentation decision is made by the shared
        // HSModuleNotificationManager.willPresent delegate, which honors
        // KEY_ALWAYSPRESENT from the content userInfo.
        true
    }

    func activateNotification(identifier: String, actionIdentifier: String?, userText: String?) {
        // Production activations come from the real UN center through the
        // shared delegate; there is no way to synthesize them here.
    }

    // MARK: UNNotification -> UserNotification mapping

    static func note(from notification: UNNotification) -> UserNotification {
        let content = notification.request.content
        let actions = snapshotActions(from: content.userInfo)
        // UNNotificationSound has no name getter, so the original sound name is
        // carried in the record snapshot via userInfo and restored on read.
        var soundName: String?
        if content.sound != nil {
            soundName = content.userInfo[KEY_SOUNDNAME] as? String
                ?? (content.userInfo["MJNotification"] != nil ? "default" : nil) ?? "DefaultSoundName"
        }
        var note = UserNotification(
            identifier: notification.request.identifier,
            title: content.title,
            subtitle: content.subtitle,
            informativeText: content.body,
            soundName: soundName,
            hasActionButton: snapshotBool(KEY_HASACTIONBUTTON, from: content.userInfo),
            actionButtonTitle: content.userInfo[KEY_ACTIONBUTTON_TITLE] as? String ?? "Show",
            otherButtonTitle: "",
            hasReplyButton: snapshotBool(KEY_HASREPLYBUTTON, from: content.userInfo),
            isDelivered: true,
            isPresented: false,
            actualDeliveryDate: notification.date,
            additionalActions: actions,
            userInfo: content.userInfo as? [String: Any] ?? [:]
        )
        if let response = content.userInfo[KEY_RESPONSE] as? String {
            note.response = response
        }
        if let activation = content.userInfo[KEY_ACTIVATIONTYPE] as? Int ?? (content.userInfo[KEY_ACTIVATIONTYPE] as? NSNumber)?.intValue {
            note.activationType = activation
        }
        if let additional = content.userInfo[KEY_ADDITIONALACTIVATION] as? String {
            note.additionalActivationAction = additional
        }
        if let placeholder = content.userInfo[KEY_RESPONSEPLACEHOLDER] as? String {
            note.responsePlaceholder = placeholder
        }
        return note
    }

    static func note(fromPending request: UNNotificationRequest) -> UserNotification {
        let content = request.content
        let actions = snapshotActions(from: content.userInfo)
        var soundName: String?
        if content.sound != nil {
            soundName = content.userInfo[KEY_SOUNDNAME] as? String
                ?? (content.userInfo["MJNotification"] != nil ? "default" : nil) ?? "DefaultSoundName"
        }
        return UserNotification(
            identifier: request.identifier,
            title: content.title,
            subtitle: content.subtitle,
            informativeText: content.body,
            soundName: soundName,
            hasActionButton: snapshotBool(KEY_HASACTIONBUTTON, from: content.userInfo),
            actionButtonTitle: content.userInfo[KEY_ACTIONBUTTON_TITLE] as? String ?? "Show",
            otherButtonTitle: "",
            hasReplyButton: snapshotBool(KEY_HASREPLYBUTTON, from: content.userInfo),
            additionalActions: actions,
            userInfo: content.userInfo as? [String: Any] ?? [:]
        )
    }

    private static func snapshotBool(_ key: String, from userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[key] as? NSNumber)?.boolValue ?? false
    }

    private static func snapshotActions(from userInfo: [AnyHashable: Any]) -> [(identifier: String, title: String)] {
        guard let stored = userInfo[KEY_ADDITIONALACTIONS] as? [[String: String]] else { return [] }
        return stored.compactMap { action in
            guard let identifier = action["identifier"], let title = action["title"] else { return nil }
            return (identifier: identifier, title: title)
        }
    }
}
