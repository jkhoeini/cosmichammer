import Cocoa

// MARK: - Dock Icon

/// Set up the dock icon visibility from stored defaults.
@objc func MJDockIconSetup() {
    reflectDefaults()
}

/// Returns whether the dock icon is currently configured to be visible.
@objc func MJDockIconVisible() -> Bool {
    UserDefaults.standard.bool(forKey: "MJShowDockIconKey")
}

/// Sets the dock icon visibility and applies the change immediately.
@objc func MJDockIconSetVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: "MJShowDockIconKey")
    reflectDefaults()
}

// MARK: - Open Console on Dock Click

/// Returns whether opening the console on dock icon click is enabled.
@objc func HSOpenConsoleOnDockClickEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: "HSOpenConsoleOnDockClickKey")
}

/// Sets whether opening the console on dock icon click is enabled.
@objc func HSOpenConsoleOnDockClickSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "HSOpenConsoleOnDockClickKey")
}

// MARK: - Private

private func reflectDefaults() {
    let app = NSApplication.shared
    let currentPolicy = app.activationPolicy
    let targetPolicy: NSApplication.ActivationPolicy = MJDockIconVisible() ? .regular : .accessory

    guard currentPolicy != targetPolicy else {
        // No need to do anything, we already have the policy we want
        return
    }

    app.setActivationPolicy(targetPolicy)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        app.unhide(nil)
        app.activate()
    }
}
