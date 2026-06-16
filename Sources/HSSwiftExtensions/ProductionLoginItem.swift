import Foundation
import HSDSTCore
import ServiceManagement
import os.log

final class ProductionLoginItem: LoginItemProtocol {
    func isLoginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLoginItemEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return true
        } catch {
            os_log(.error, "ProductionLoginItem: %{public}s", String(describing: error))
            return false
        }
    }

    func loginItemBundleID() -> String? {
        Bundle.main.bundleIdentifier
    }
}
