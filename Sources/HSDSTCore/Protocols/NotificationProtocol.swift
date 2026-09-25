import Foundation

public typealias NotificationObserverToken = AnyObject

/// Action identifiers shared by the production UN delegate and the DST
/// simulator so both compute hs.notify activation types identically.
public enum UserNotificationActionIdentifier {
    /// User tapped the notification body (UNNotificationDefaultActionIdentifier).
    public static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
    /// User dismissed the notification (UNNotificationDismissActionIdentifier).
    public static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"
    /// hs.notify primary action button (maps to activationTypes.actionButtonClicked).
    public static let actionButton = "hs.notify.action"
    /// hs.notify reply text-input action (maps to activationTypes.replied).
    public static let reply = "hs.notify.reply"
}

public enum UserNotificationSemantics {
    public static let alwaysPresentKey = "alwaysPresent"
    public static let actionPrefix = "hs.notify."
    public static let categoryPrefix = "hs.notify.category."

    public static func activationType(actionIdentifier: String?, categoryIdentifier: String?) -> Int {
        switch actionIdentifier {
        case nil, "", UserNotificationActionIdentifier.defaultAction:
            return 1
        case UserNotificationActionIdentifier.dismissAction:
            return 0
        case UserNotificationActionIdentifier.actionButton:
            return 2
        case UserNotificationActionIdentifier.reply:
            return 3
        default:
            guard let actionIdentifier,
                  actionIdentifier.hasPrefix(actionPrefix),
                  categoryIdentifier?.hasPrefix(categoryPrefix) == true else { return 1 }
            return 4
        }
    }
}

public struct UserNotification {
    public var identifier: String
    public var title: String
    public var subtitle: String
    public var informativeText: String
    public var soundName: String?
    public var hasActionButton: Bool
    public var actionButtonTitle: String
    public var otherButtonTitle: String
    public var hasReplyButton: Bool
    public var isDelivered: Bool
    public var isPresented: Bool
    public var actualDeliveryDate: Date?
    public var additionalActions: [(identifier: String, title: String)]
    public var userInfo: [String: Any]
    // Activation/response state recorded by the delegate path (0 = none,
    // 1 = contentsClicked, 2 = actionButtonClicked, 3 = replied,
    // 4 = additionalActionClicked; see hs.notify.activationTypes).
    public var activationType: Int
    public var response: String?
    public var additionalActivationAction: String?
    public var responsePlaceholder: String
    public var deliveryDate: Date?
    // PNG payload for the hs.notify contentImage (delivered as a UN attachment).
    public var contentImageData: Data?

    public init(identifier: String = UUID().uuidString,
                title: String = "", subtitle: String = "",
                informativeText: String = "", soundName: String? = nil,
                hasActionButton: Bool = true, actionButtonTitle: String = "Show",
                otherButtonTitle: String = "Close", hasReplyButton: Bool = false,
                isDelivered: Bool = false, isPresented: Bool = false,
                actualDeliveryDate: Date? = nil,
                additionalActions: [(identifier: String, title: String)] = [],
                userInfo: [String: Any] = [:],
                activationType: Int = 0,
                response: String? = nil,
                additionalActivationAction: String? = nil,
                responsePlaceholder: String = "",
                deliveryDate: Date? = nil,
                contentImageData: Data? = nil) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.informativeText = informativeText
        self.soundName = soundName
        self.hasActionButton = hasActionButton
        self.actionButtonTitle = actionButtonTitle
        self.otherButtonTitle = otherButtonTitle
        self.hasReplyButton = hasReplyButton
        self.isDelivered = isDelivered
        self.isPresented = isPresented
        self.actualDeliveryDate = actualDeliveryDate
        self.additionalActions = additionalActions
        self.userInfo = userInfo
        self.activationType = activationType
        self.response = response
        self.additionalActivationAction = additionalActivationAction
        self.responsePlaceholder = responsePlaceholder
        self.deliveryDate = deliveryDate
        self.contentImageData = contentImageData
    }
}

public protocol NotificationProtocol: AnyObject {
    func addObserver(name: String, object: AnyObject?,
                     handler: @escaping ([String: Any]) -> Void) -> any NotificationObserverToken
    func removeObserver(_ token: any NotificationObserverToken)
    func post(name: String, object: AnyObject?, userInfo: [String: Any]?)

    func addDistributedObserver(name: String?, object: String?,
                                handler: @escaping (_ name: String, _ object: String?, _ userInfo: [String: Any]?) -> Void) -> any NotificationObserverToken
    func postDistributed(name: String, object: String?, userInfo: [String: Any]?)

    func addWorkspaceObserver(name: String, object: AnyObject?,
                              handler: @escaping ([String: Any]) -> Void) -> any NotificationObserverToken

    func deliverUserNotification(_ notification: UserNotification)
    func scheduleUserNotification(_ notification: UserNotification)
    func removeDeliveredUserNotification(identifier: String)
    func removeScheduledUserNotification(identifier: String)
    func removeAllDeliveredUserNotifications()
    func deliveredUserNotifications() -> [UserNotification]
    func scheduledUserNotifications() -> [UserNotification]

    /// UN willPresent equivalent. Returns true when the notification should be
    /// shown while the app is frontmost.
    func presentNotification(_ notification: UserNotification) -> Bool
    /// Test hook: fire a didReceive-like activation for a delivered
    /// notification without touching the real OS notification center.
    func activateNotification(identifier: String, actionIdentifier: String?, userText: String?)
}
