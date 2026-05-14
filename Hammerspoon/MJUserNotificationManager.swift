import Cocoa

/// Manages delivery and activation callbacks for user notifications.
@objcMembers
class MJUserNotificationManager: NSObject, NSUserNotificationCenterDelegate {

    /// Shared singleton instance.
    static let sharedManager: MJUserNotificationManager = {
        let manager = MJUserNotificationManager()
        NSUserNotificationCenter.default.delegate = manager
        return manager
    }()

    private var callbacks: [NSUserNotification: () -> Void] = [:]

    /// Post a notification with the given title and invoke `handler` when the user clicks it.
    func sendNotification(_ title: String, handler: @escaping () -> Void) {
        let note = NSUserNotification()
        note.title = title
        callbacks[note] = handler
        NSUserNotificationCenter.default.deliver(note)
    }

    // MARK: - NSUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        NSUserNotificationCenter.default.removeDeliveredNotification(notification)

        if let callback = callbacks[notification] {
            callback()
        }
        callbacks.removeValue(forKey: notification)
    }

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }
}
