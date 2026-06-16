import Foundation

public typealias NotificationObserverToken = AnyObject

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

    public init(identifier: String = UUID().uuidString,
                title: String = "", subtitle: String = "",
                informativeText: String = "", soundName: String? = nil,
                hasActionButton: Bool = true, actionButtonTitle: String = "Show",
                otherButtonTitle: String = "Close", hasReplyButton: Bool = false,
                isDelivered: Bool = false, isPresented: Bool = false,
                actualDeliveryDate: Date? = nil,
                additionalActions: [(identifier: String, title: String)] = [],
                userInfo: [String: Any] = [:]) {
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
}
