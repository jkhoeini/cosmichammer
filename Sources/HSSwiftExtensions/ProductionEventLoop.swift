import Foundation
import HSDSTCore

final class ProductionEventLoop: EventLoopProtocol {
    func async(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    func after(seconds: TimeInterval, block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    func drain() {}
}
