import Cocoa

@objc(MJUserNotificationManager)
public class MJUserNotificationManager: NSObject, NSUserNotificationCenterDelegate {

    @objc public static let sharedManager: MJUserNotificationManager = {
        let manager = MJUserNotificationManager()
        NSUserNotificationCenter.default.delegate = manager
        return manager
    }()

    private var callbacks: [NSUserNotification: () -> Void] = [:]

    @objc public func sendNotification(_ title: String, handler: @escaping () -> Void) {
        let note = NSUserNotification()
        note.title = title
        callbacks[note] = handler
        NSUserNotificationCenter.default.deliver(note)
    }

    public func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        NSUserNotificationCenter.default.removeDeliveredNotification(notification)

        if let callback = callbacks[notification] {
            callback()
        }
        callbacks.removeValue(forKey: notification)
    }

    public func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }
}
