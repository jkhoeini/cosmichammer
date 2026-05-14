import Foundation
import ServiceManagement

@objc func MJAutoLaunchGet() -> Bool {
    SMAppService.mainApp.status == .enabled
}

@objc func MJAutoLaunchSet(_ opensAtLogin: Bool) {
    let service = SMAppService.mainApp
    do {
        if opensAtLogin {
            try service.register()
        } else {
            try service.unregister()
        }
    } catch {
        NSLog("MJAutoLaunch: %@", error as NSError)
    }
}
