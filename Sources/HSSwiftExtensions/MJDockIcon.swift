import Cocoa

@_cdecl("MJDockIconSetup")
func MJDockIconSetup() {
    reflectDockDefaults()
}

@_cdecl("MJDockIconVisible")
func MJDockIconVisible() -> Bool {
    UserDefaults.standard.bool(forKey: "MJShowDockIconKey")
}

@_cdecl("MJDockIconSetVisible")
func MJDockIconSetVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: "MJShowDockIconKey")
    reflectDockDefaults()
}

@_cdecl("HSOpenConsoleOnDockClickEnabled")
func HSOpenConsoleOnDockClickEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: "HSOpenConsoleOnDockClickKey")
}

@_cdecl("HSOpenConsoleOnDockClickSetEnabled")
func HSOpenConsoleOnDockClickSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "HSOpenConsoleOnDockClickKey")
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
