import Foundation
import ServiceManagement
import os.log
import HSDSTCore

@_cdecl("MJAutoLaunchGet")
func MJAutoLaunchGet() -> Bool {
    if let env = environmentGetGlobalOrNil() {
        return env.loginItem.isLoginItemEnabled()
    }
    return SMAppService.mainApp.status == .enabled
}

@_cdecl("MJAutoLaunchSet")
func MJAutoLaunchSet(_ opensAtLogin: Bool) {
    if let env = environmentGetGlobalOrNil() {
        _ = env.loginItem.setLoginItemEnabled(opensAtLogin)
        return
    }
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
