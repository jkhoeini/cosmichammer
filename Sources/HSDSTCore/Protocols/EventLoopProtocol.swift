import Foundation

public protocol EventLoopProtocol: AnyObject {
    func async(_ block: @escaping () -> Void)
    func after(seconds: TimeInterval, block: @escaping () -> Void)
    func drain()
}
