import Foundation
import ServiceManagement

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
        NSLog("MJAutoLaunch: %@", error as NSError)
    }
}
