import Foundation
import HSDSTCore

public final class SimulatedStatusBar: StatusBarProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    private var nextID: UInt64 = 1

    public var statusItems: [UInt64: StatusItemInfo] = [:]
    public var statusItemImages: [UInt64: Data] = [:]
    public var menus: [UInt64: MenuInfo] = [:]
    public var menuItems: [UInt64: MenuItemInfo] = [:]
    public var menuItemImages: [UInt64: Data] = [:]
    public var menuContents: [UInt64: [UInt64]] = [:]  // menuID -> [menuItemID]
    public var menuItemCallbacks: [UInt64: () -> Void] = [:]
    public var popUpHistory: [(menuID: UInt64, location: (x: Double, y: Double))] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    private func allocateID() -> UInt64 {
        let id = nextID
        nextID += 1
        return id
    }

    // MARK: - Status item management

    public func createStatusItem(length: Double) -> UInt64 {
        let id = allocateID()
        statusItems[id] = StatusItemInfo(id: id, length: length)
        return id
    }

    public func removeStatusItem(itemID: UInt64) -> Bool {
        guard statusItems.removeValue(forKey: itemID) != nil else { return false }
        statusItemImages.removeValue(forKey: itemID)
        return true
    }

    public func statusItemInfo(itemID: UInt64) -> StatusItemInfo? {
        statusItems[itemID]
    }

    public func setStatusItemTitle(itemID: UInt64, title: String?) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        info.title = title
        statusItems[itemID] = info
        return true
    }

    public func setStatusItemImage(itemID: UInt64, imageData: Data?) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        if let data = imageData {
            statusItemImages[itemID] = data
            info.hasImage = true
        } else {
            statusItemImages.removeValue(forKey: itemID)
            info.hasImage = false
        }
        statusItems[itemID] = info
        return true
    }

    public func setStatusItemToolTip(itemID: UInt64, toolTip: String?) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        info.toolTip = toolTip
        statusItems[itemID] = info
        return true
    }

    public func setStatusItemImagePosition(itemID: UInt64, position: Int) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        info.imagePosition = position
        statusItems[itemID] = info
        return true
    }

    public func setStatusItemVisible(itemID: UInt64, visible: Bool) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        info.isVisible = visible
        statusItems[itemID] = info
        return true
    }

    public func setStatusItemMenu(itemID: UInt64, menuID: UInt64?) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        if let mid = menuID, menus[mid] == nil { return false }
        info.menuID = menuID
        statusItems[itemID] = info
        return true
    }

    public func setStatusItemAutosaveName(itemID: UInt64, name: String?) -> Bool {
        guard var info = statusItems[itemID] else { return false }
        info.autosaveName = name
        statusItems[itemID] = info
        return true
    }

    public func statusItemFrame(itemID: UInt64) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard statusItems[itemID] != nil else { return nil }
        return (x: 100, y: 0, width: 30, height: 22)
    }

    // MARK: - Menu management

    public func createMenu(title: String) -> UInt64 {
        let id = allocateID()
        menus[id] = MenuInfo(id: id, title: title)
        menuContents[id] = []
        return id
    }

    public func destroyMenu(menuID: UInt64) -> Bool {
        guard menus.removeValue(forKey: menuID) != nil else { return false }
        if let items = menuContents.removeValue(forKey: menuID) {
            for itemID in items {
                menuItems.removeValue(forKey: itemID)
                menuItemImages.removeValue(forKey: itemID)
                menuItemCallbacks.removeValue(forKey: itemID)
            }
        }
        return true
    }

    public func menuInfo(menuID: UInt64) -> MenuInfo? {
        guard var info = menus[menuID] else { return nil }
        info.itemCount = menuContents[menuID]?.count ?? 0
        return info
    }

    public func setMenuAutoenablesItems(menuID: UInt64, enabled: Bool) -> Bool {
        guard var info = menus[menuID] else { return false }
        info.autoenablesItems = enabled
        menus[menuID] = info
        return true
    }

    public func popUpMenu(menuID: UInt64, atLocation location: (x: Double, y: Double)) -> Bool {
        guard menus[menuID] != nil else { return false }
        popUpHistory.append((menuID: menuID, location: location))
        return true
    }

    // MARK: - Menu item management

    public func addMenuItem(menuID: UInt64, title: String, keyEquivalent: String) -> UInt64? {
        guard menus[menuID] != nil else { return nil }
        let id = allocateID()
        menuItems[id] = MenuItemInfo(id: id, title: title, keyEquivalent: keyEquivalent)
        menuContents[menuID, default: []].append(id)
        return id
    }

    public func addMenuSeparator(menuID: UInt64) -> UInt64? {
        guard menus[menuID] != nil else { return nil }
        let id = allocateID()
        menuItems[id] = MenuItemInfo(id: id, isSeparator: true)
        menuContents[menuID, default: []].append(id)
        return id
    }

    public func removeMenuItem(menuID: UInt64, itemID: UInt64) -> Bool {
        guard var items = menuContents[menuID],
              let idx = items.firstIndex(of: itemID) else { return false }
        items.remove(at: idx)
        menuContents[menuID] = items
        menuItems.removeValue(forKey: itemID)
        menuItemImages.removeValue(forKey: itemID)
        menuItemCallbacks.removeValue(forKey: itemID)
        return true
    }

    public func menuItemInfo(itemID: UInt64) -> MenuItemInfo? {
        menuItems[itemID]
    }

    public func setMenuItemTitle(itemID: UInt64, title: String) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.title = title
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemEnabled(itemID: UInt64, enabled: Bool) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.isEnabled = enabled
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemState(itemID: UInt64, state: Int) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.state = state
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemImage(itemID: UInt64, imageData: Data?) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        if let data = imageData {
            menuItemImages[itemID] = data
            info.hasImage = true
        } else {
            menuItemImages.removeValue(forKey: itemID)
            info.hasImage = false
        }
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemToolTip(itemID: UInt64, toolTip: String?) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.toolTip = toolTip
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemIndentationLevel(itemID: UInt64, level: Int) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.indentationLevel = level
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemKeyEquivalent(itemID: UInt64, key: String, modifierMask: UInt) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.keyEquivalent = key
        info.keyEquivalentModifierMask = modifierMask
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemSubmenu(itemID: UInt64, submenuID: UInt64?) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        if let sid = submenuID, menus[sid] == nil { return false }
        info.hasSubmenu = submenuID != nil
        info.submenuID = submenuID
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemTag(itemID: UInt64, tag: Int) -> Bool {
        guard var info = menuItems[itemID] else { return false }
        info.tag = tag
        menuItems[itemID] = info
        return true
    }

    public func setMenuItemCallback(itemID: UInt64, callback: @escaping () -> Void) -> Bool {
        guard menuItems[itemID] != nil else { return false }
        menuItemCallbacks[itemID] = callback
        return true
    }

    // MARK: - Test helpers

    /// Simulate clicking a menu item.
    public func clickMenuItem(itemID: UInt64) {
        menuItemCallbacks[itemID]?()
    }
}
