import Cocoa
import UserNotifications

@objc(MJUserNotificationManager)
public class MJUserNotificationManager: NSObject {

    @objc public static let sharedManager: MJUserNotificationManager = {
        let manager = MJUserNotificationManager()
        return manager
    }()

    private var callbacks: [String: () -> Void] = [:]

    @objc public func sendNotification(_ title: String, handler: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default

        let identifier = ProcessInfo.processInfo.globallyUniqueString
        content.userInfo = ["MJNotification": identifier]
        callbacks[identifier] = handler

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            if let error = error {
                NSLog("MJUserNotificationManager: failed to deliver notification: %@", error.localizedDescription)
            }
        }
    }

    /// Called by the shared HSModuleNotificationManager delegate when a
    /// MJNotification response comes in.  The hs.notify delegate checks for
    /// "MJNotification" in userInfo and forwards here.
    func handleResponse(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        if let callback = callbacks[identifier] {
            callback()
        }
        callbacks.removeValue(forKey: identifier)
    }
}
