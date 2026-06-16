import Foundation
import HSDSTCore

public final class SimulatedLoginItem: LoginItemProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var loginItemEnabled: Bool = false
    public var bundleID: String? = "com.cosmichammer.app"
    public var setLoginItemCalls: [Bool] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func isLoginItemEnabled() -> Bool {
        loginItemEnabled
    }

    public func setLoginItemEnabled(_ enabled: Bool) -> Bool {
        setLoginItemCalls.append(enabled)
        loginItemEnabled = enabled
        return true
    }

    public func loginItemBundleID() -> String? {
        bundleID
    }
}
