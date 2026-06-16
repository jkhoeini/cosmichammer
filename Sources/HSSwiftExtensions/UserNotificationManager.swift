import Cocoa
import UserNotifications
import HSDSTCore

@objc(MJUserNotificationManager)
public class MJUserNotificationManager: NSObject {

    @objc public static let sharedManager: MJUserNotificationManager = {
        let manager = MJUserNotificationManager()
        return manager
    }()

    private var callbacks: [String: () -> Void] = [:]

    @objc public func sendNotification(_ title: String, handler: @escaping () -> Void) {
        let identifier = ProcessInfo.processInfo.globallyUniqueString
        callbacks[identifier] = handler

        if let notification = environmentGetGlobalOrNil()?.notification {
            var note = UserNotification(identifier: identifier, title: title)
            note.soundName = "default"
            note.userInfo = ["MJNotification": identifier]
            notification.deliverUserNotification(note)
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            content.sound = .default
            content.userInfo = ["MJNotification": identifier]
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("MJUserNotificationManager: failed to deliver notification: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Called by the shared HSModuleNotificationManager delegate when a
    /// MJNotification response comes in.  The hs.notify delegate checks for
    /// "MJNotification" in userInfo and forwards here.
    func handleResponse(identifier: String) {
        if let notification = environmentGetGlobalOrNil()?.notification {
            notification.removeDeliveredUserNotification(identifier: identifier)
        } else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        if let callback = callbacks[identifier] {
            callback()
        }
        callbacks.removeValue(forKey: identifier)
    }
}
