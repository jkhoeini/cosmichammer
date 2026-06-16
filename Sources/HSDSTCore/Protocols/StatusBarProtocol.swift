import Foundation

public struct StatusItemInfo: Sendable {
    public var id: UInt64
    public var title: String?
    public var toolTip: String?
    public var isVisible: Bool
    public var length: Double
    public var autosaveName: String?
    public var imagePosition: Int  // 0=noImage, 1=imageOnly, 2=imageLeft, 3=imageRight, 4=imageBelow, 5=imageAbove, 6=imageOverlaps, 7=imageLeading, 8=imageTrailing
    public var hasImage: Bool
    public var menuID: UInt64?

    public init(id: UInt64 = 0, title: String? = nil, toolTip: String? = nil,
                isVisible: Bool = true, length: Double = -1,
                autosaveName: String? = nil, imagePosition: Int = 0,
                hasImage: Bool = false, menuID: UInt64? = nil) {
        self.id = id
        self.title = title
        self.toolTip = toolTip
        self.isVisible = isVisible
        self.length = length
        self.autosaveName = autosaveName
        self.imagePosition = imagePosition
        self.hasImage = hasImage
        self.menuID = menuID
    }
}

public struct MenuItemInfo: Sendable {
    public var id: UInt64
    public var title: String
    public var keyEquivalent: String
    public var keyEquivalentModifierMask: UInt
    public var isEnabled: Bool
    public var state: Int  // 0=off, 1=on, -1=mixed
    public var toolTip: String?
    public var indentationLevel: Int
    public var isSeparator: Bool
    public var hasSubmenu: Bool
    public var submenuID: UInt64?
    public var hasImage: Bool
    public var tag: Int

    public init(id: UInt64 = 0, title: String = "", keyEquivalent: String = "",
                keyEquivalentModifierMask: UInt = 0, isEnabled: Bool = true,
                state: Int = 0, toolTip: String? = nil, indentationLevel: Int = 0,
                isSeparator: Bool = false, hasSubmenu: Bool = false,
                submenuID: UInt64? = nil, hasImage: Bool = false, tag: Int = 0) {
        self.id = id
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentModifierMask = keyEquivalentModifierMask
        self.isEnabled = isEnabled
        self.state = state
        self.toolTip = toolTip
        self.indentationLevel = indentationLevel
        self.isSeparator = isSeparator
        self.hasSubmenu = hasSubmenu
        self.submenuID = submenuID
        self.hasImage = hasImage
        self.tag = tag
    }
}

public struct MenuInfo: Sendable {
    public var id: UInt64
    public var title: String
    public var itemCount: Int
    public var autoenablesItems: Bool

    public init(id: UInt64 = 0, title: String = "", itemCount: Int = 0,
                autoenablesItems: Bool = true) {
        self.id = id
        self.title = title
        self.itemCount = itemCount
        self.autoenablesItems = autoenablesItems
    }
}

public protocol StatusBarProtocol: AnyObject {
    // Status item management
    func createStatusItem(length: Double) -> UInt64
    func removeStatusItem(itemID: UInt64) -> Bool
    func statusItemInfo(itemID: UInt64) -> StatusItemInfo?
    func setStatusItemTitle(itemID: UInt64, title: String?) -> Bool
    func setStatusItemImage(itemID: UInt64, imageData: Data?) -> Bool
    func setStatusItemToolTip(itemID: UInt64, toolTip: String?) -> Bool
    func setStatusItemImagePosition(itemID: UInt64, position: Int) -> Bool
    func setStatusItemVisible(itemID: UInt64, visible: Bool) -> Bool
    func setStatusItemMenu(itemID: UInt64, menuID: UInt64?) -> Bool
    func setStatusItemAutosaveName(itemID: UInt64, name: String?) -> Bool
    func statusItemFrame(itemID: UInt64) -> (x: Double, y: Double, width: Double, height: Double)?

    // Menu management
    func createMenu(title: String) -> UInt64
    func destroyMenu(menuID: UInt64) -> Bool
    func menuInfo(menuID: UInt64) -> MenuInfo?
    func setMenuAutoenablesItems(menuID: UInt64, enabled: Bool) -> Bool
    func popUpMenu(menuID: UInt64, atLocation: (x: Double, y: Double)) -> Bool

    // Menu item management
    func addMenuItem(menuID: UInt64, title: String, keyEquivalent: String) -> UInt64?
    func addMenuSeparator(menuID: UInt64) -> UInt64?
    func removeMenuItem(menuID: UInt64, itemID: UInt64) -> Bool
    func menuItemInfo(itemID: UInt64) -> MenuItemInfo?
    func setMenuItemTitle(itemID: UInt64, title: String) -> Bool
    func setMenuItemEnabled(itemID: UInt64, enabled: Bool) -> Bool
    func setMenuItemState(itemID: UInt64, state: Int) -> Bool
    func setMenuItemImage(itemID: UInt64, imageData: Data?) -> Bool
    func setMenuItemToolTip(itemID: UInt64, toolTip: String?) -> Bool
    func setMenuItemIndentationLevel(itemID: UInt64, level: Int) -> Bool
    func setMenuItemKeyEquivalent(itemID: UInt64, key: String, modifierMask: UInt) -> Bool
    func setMenuItemSubmenu(itemID: UInt64, submenuID: UInt64?) -> Bool
    func setMenuItemTag(itemID: UInt64, tag: Int) -> Bool
    func setMenuItemCallback(itemID: UInt64, callback: @escaping () -> Void) -> Bool
}
