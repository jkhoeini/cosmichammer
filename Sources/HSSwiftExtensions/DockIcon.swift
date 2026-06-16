import Cocoa
import HSDSTCore

@_cdecl("MJDockIconSetup")
func MJDockIconSetup() {
    reflectDockDefaults()
}

@_cdecl("MJDockIconVisible")
func MJDockIconVisible() -> Bool {
    if let env = environmentGetGlobalOrNil() {
        return env.settings.bool(forKey: "MJShowDockIconKey")
    }
    return UserDefaults.standard.bool(forKey: "MJShowDockIconKey")
}

@_cdecl("MJDockIconSetVisible")
func MJDockIconSetVisible(_ visible: Bool) {
    if let env = environmentGetGlobalOrNil() {
        env.settings.set(visible, forKey: "MJShowDockIconKey")
    } else {
        UserDefaults.standard.set(visible, forKey: "MJShowDockIconKey")
    }
    reflectDockDefaults()
}

@_cdecl("HSOpenConsoleOnDockClickEnabled")
func HSOpenConsoleOnDockClickEnabled() -> Bool {
    if let env = environmentGetGlobalOrNil() {
        return env.settings.bool(forKey: "HSOpenConsoleOnDockClickKey")
    }
    return UserDefaults.standard.bool(forKey: "HSOpenConsoleOnDockClickKey")
}

@_cdecl("HSOpenConsoleOnDockClickSetEnabled")
func HSOpenConsoleOnDockClickSetEnabled(_ enabled: Bool) {
    if let env = environmentGetGlobalOrNil() {
        env.settings.set(enabled, forKey: "HSOpenConsoleOnDockClickKey")
    } else {
        UserDefaults.standard.set(enabled, forKey: "HSOpenConsoleOnDockClickKey")
    }
}

private func reflectDockDefaults() {
    let app = NSApplication.shared
    let currentPolicy = app.activationPolicy()
    let targetPolicy: NSApplication.ActivationPolicy = MJDockIconVisible() ? .regular : .accessory

    guard currentPolicy != targetPolicy else { return }

    app.setActivationPolicy(targetPolicy)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        app.unhide(nil)
        app.activate()
    }
}
