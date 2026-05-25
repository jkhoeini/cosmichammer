import Foundation
import ServiceManagement
import os.log

@_cdecl("MJAutoLaunchGet")
func MJAutoLaunchGet() -> Bool {
    SMAppService.mainApp.status == .enabled
}

@_cdecl("MJAutoLaunchSet")
func MJAutoLaunchSet(_ opensAtLogin: Bool) {
    let service = SMAppService.mainApp
    do {
        if opensAtLogin {
            try service.register()
        } else {
            try service.unregister()
        }
    } catch {
        os_log(.error, "MJAutoLaunch: %{public}s", String(describing: error))
    }
}
