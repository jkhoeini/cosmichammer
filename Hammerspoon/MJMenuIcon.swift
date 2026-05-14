import Cocoa

private var statusItem: NSStatusItem?
private var menuItemMenu: NSMenu?

/// Set up the menu bar icon with the given menu.
@objc func MJMenuIconSetup(_ menu: NSMenu) {
    menuItemMenu = menu
    reflectDefaults()
}

/// Whether the menu bar icon is currently visible (per user defaults).
@objc func MJMenuIconVisible() -> Bool {
    UserDefaults.standard.bool(forKey: "MJShowMenuIconKey")
}

/// Show or hide the menu bar icon and persist the choice.
@objc func MJMenuIconSetVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: "MJShowMenuIconKey")
    reflectDefaults()
}

private func reflectDefaults() {
    if MJMenuIconVisible() {
        guard let icon = NSImage(named: "statusicon") else { return }
        icon.isTemplate = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = icon
        item.menu = menuItemMenu
        statusItem = item
    } else {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}
