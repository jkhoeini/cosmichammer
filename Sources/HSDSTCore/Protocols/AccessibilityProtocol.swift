import Foundation

public struct AccessibilityElement: Sendable {
    public var elementID: UInt64
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var frame: (x: Double, y: Double, width: Double, height: Double)
    public var pid: Int32
    public var children: [UInt64]
    public var parent: UInt64?
    public var attributes: [String: String]

    public init(elementID: UInt64, role: String, subrole: String? = nil,
                title: String? = nil, value: String? = nil,
                frame: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 0, 0),
                pid: Int32 = 0, children: [UInt64] = [], parent: UInt64? = nil,
                attributes: [String: String] = [:]) {
        self.elementID = elementID
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.frame = frame
        self.pid = pid
        self.children = children
        self.parent = parent
        self.attributes = attributes
    }
}

public protocol AccessibilityProtocol: AnyObject {
    func isAccessibilityEnabled() -> Bool
    func createElement(forPID pid: Int32) -> UInt64?
    func getAttributeValue(element: UInt64, attribute: String) -> String?
    func setAttributeValue(element: UInt64, attribute: String, value: String) -> Bool
    func performAction(element: UInt64, action: String) -> Bool
    func getChildren(element: UInt64) -> [UInt64]
    func getParent(element: UInt64) -> UInt64?
    func elementAtPosition(x: Double, y: Double) -> UInt64?
    func observerCreate(pid: Int32, callback: @escaping (UInt64, UInt64, String) -> Void) -> UInt64?
    func observerAddNotification(observer: UInt64, element: UInt64, notification: String) -> Bool
    func observerRemoveNotification(observer: UInt64, element: UInt64, notification: String) -> Bool
    func getRole(element: UInt64) -> String?
    func getTitle(element: UInt64) -> String?
    func getFrame(element: UInt64) -> (x: Double, y: Double, width: Double, height: Double)?
    func getSystemWideElement() -> UInt64
}
