import Cocoa
import HSDSTCore

private var statusItem: NSStatusItem?
private var menuItemMenu: NSMenu?

@_cdecl("MJMenuIconSetup")
func MJMenuIconSetup(_ menu: NSMenu) {
    menuItemMenu = menu
    reflectMenuDefaults()
}

@_cdecl("MJMenuIconVisible")
func MJMenuIconVisible() -> Bool {
    if let env = environmentGetGlobalOrNil() {
        return env.settings.bool(forKey: "MJShowMenuIconKey")
    }
    return UserDefaults.standard.bool(forKey: "MJShowMenuIconKey")
}

@_cdecl("MJMenuIconSetVisible")
func MJMenuIconSetVisible(_ visible: Bool) {
    if let env = environmentGetGlobalOrNil() {
        env.settings.set(visible, forKey: "MJShowMenuIconKey")
    } else {
        UserDefaults.standard.set(visible, forKey: "MJShowMenuIconKey")
    }
    reflectMenuDefaults()
}

private func reflectMenuDefaults() {
    if MJMenuIconVisible() {
        let item: NSStatusItem
        if let existingItem = statusItem {
            item = existingItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
        }

        if let icon = NSImage(named: "statusicon") {
            icon.isTemplate = true
            item.button?.image = icon
        }
        item.menu = menuItemMenu
    } else {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}

func MJMenuIconStatusItemIdentityForTesting() -> ObjectIdentifier? {
    statusItem.map(ObjectIdentifier.init)
}

func MJMenuIconResetForTesting() {
    if let item = statusItem {
        NSStatusBar.system.removeStatusItem(item)
    }
    statusItem = nil
    menuItemMenu = nil
}
