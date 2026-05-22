import Cocoa

private var statusItem: NSStatusItem?
private var menuItemMenu: NSMenu?

@_cdecl("MJMenuIconSetup")
func MJMenuIconSetup(_ menu: NSMenu) {
    menuItemMenu = menu
    reflectMenuDefaults()
}

@_cdecl("MJMenuIconVisible")
func MJMenuIconVisible() -> Bool {
    UserDefaults.standard.bool(forKey: "MJShowMenuIconKey")
}

@_cdecl("MJMenuIconSetVisible")
func MJMenuIconSetVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: "MJShowMenuIconKey")
    reflectMenuDefaults()
}

private func reflectMenuDefaults() {
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
