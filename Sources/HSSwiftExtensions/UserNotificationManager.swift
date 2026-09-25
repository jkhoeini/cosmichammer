import Foundation
import HSDSTCore
import UserNotifications

@objc(MJUserNotificationManager)
public final class MJUserNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    @objc public static let sharedManager: MJUserNotificationManager = {
        let manager = MJUserNotificationManager()
        return manager
    }()

    private var callbacks: [String: () -> Void] = [:]
    private let callbacksLock = NSLock()
    private var authorizationRequested = false
    /// False when UNUserNotificationCenter.current() is unavailable (no bundle
    /// proxy, e.g. the SPM test runner); real UN delivery is skipped.
    private var centerAvailable = true

    /// Become the process-wide UNUserNotificationCenter delegate. Called at
    /// process boot (AppDelegate) and lazily before the first notification is
    /// added. UN has a single delegate slot; installing here is idempotent.
    ///
    /// UNUserNotificationCenter.current() raises NSInternalInconsistencyException
    /// from inside dispatch_once when the process has no bundle proxy (e.g. the
    /// SPM test runner) — dispatch_once terminates on ObjC exceptions, so the
    /// throw cannot be caught. Probe the bundle instead: a real app always has
    /// a bundle identifier.
    public func installAsDelegateIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else {
            centerAvailable = false
            NSLog("MJUserNotificationManager: no bundle proxy; UNUserNotificationCenter unavailable")
            return
        }
        guard let error: String = catchingObjCException({
            let center = UNUserNotificationCenter.current()
            if !(center.delegate === self) {
                center.delegate = self
            }
        }) else {
            centerAvailable = true
            return
        }
        centerAvailable = false
        NSLog("MJUserNotificationManager: UNUserNotificationCenter unavailable: %@", error)
    }

    /// Request notification authorization lazily before the first add.
    private func requestAuthorizationIfNeeded() {
        installAsDelegateIfNeeded()
        guard !authorizationRequested else { return }
        authorizationRequested = true
        // The delegate install above already caught a missing-bundle proxy; the
        // requestAuthorization call itself is safe once current() succeeded.
        if centerAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    NSLog("MJUserNotificationManager: authorization failed: %@", error.localizedDescription)
                } else if !granted {
                    NSLog("MJUserNotificationManager: notification authorization denied")
                }
            }
        }
    }

    @objc public func sendNotification(_ title: String, handler: @escaping () -> Void) {
        let identifier = ProcessInfo.processInfo.globallyUniqueString
        callbacksLock.lock()
        callbacks[identifier] = handler
        callbacksLock.unlock()

        if let notification = environmentGetGlobalOrNil()?.notification {
            // DST/simulated path: route through the NotificationProtocol so
            // tests never touch the real UN center.
            var note = UserNotification(identifier: identifier, title: title)
            note.soundName = "default"
            note.userInfo = ["MJNotification": identifier]
            notification.deliverUserNotification(note)
        } else {
            requestAuthorizationIfNeeded()
            if centerAvailable {
                let content = UNMutableNotificationContent()
                content.title = title
                content.sound = .default
                content.userInfo = ["MJNotification": identifier]
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        NSLog("MJUserNotificationManager: failed to deliver notification: %@", error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate (process-wide delegate)

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let identifier = response.notification.request.identifier
        if content.userInfo[KEY_ID] != nil {
            // hs.notify notification: route through the notify module's handler.
            HSModuleNotificationManager.shared.handleActivationResponse(response)
            completionHandler()
            return
        }
        // MJNotification (core console-open) or foreign: fire the registered callback.
        callbacksLock.lock()
        let callback = callbacks.removeValue(forKey: identifier)
        callbacksLock.unlock()
        if let callback {
            if centerAvailable {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            } else if let notification = environmentGetGlobalOrNil()?.notification {
                notification.removeDeliveredUserNotification(identifier: identifier)
            }
            callback()
        }
        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        if content.userInfo[KEY_ID] != nil {
            // hs.notify notification: honor the module's alwaysPresent decision.
            let present = HSModuleNotificationManager.shared.presentationDecision(
                identifier: notification.request.identifier,
                userInfo: content.userInfo,
                deliveryDate: notification.date
            )
            completionHandler(present ? [.banner, .sound] : [])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// Called when an MJNotification response comes in outside the delegate
    /// path (e.g. forwarded by tests). Removes the notification and fires the
    /// registered callback.
    func handleResponse(identifier: String) {
        callbacksLock.lock()
        let callback = callbacks.removeValue(forKey: identifier)
        callbacksLock.unlock()
        guard let callback else { return }
        if let notification = environmentGetGlobalOrNil()?.notification {
            notification.removeDeliveredUserNotification(identifier: identifier)
        } else if centerAvailable {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        callback()
    }
}
