import Foundation

public protocol LoginItemProtocol: AnyObject {
    func isLoginItemEnabled() -> Bool
    func setLoginItemEnabled(_ enabled: Bool) -> Bool
    func loginItemBundleID() -> String?
}
