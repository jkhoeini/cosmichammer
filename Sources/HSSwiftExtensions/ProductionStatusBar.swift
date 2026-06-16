import Foundation
import HSDSTCore

final class ProductionStatusBar: StatusBarProtocol {
    func createStatusItem(length: Double) -> UInt64 { 0 }
    func removeStatusItem(itemID: UInt64) -> Bool { false }
    func statusItemInfo(itemID: UInt64) -> StatusItemInfo? { nil }
    func setStatusItemTitle(itemID: UInt64, title: String?) -> Bool { false }
    func setStatusItemImage(itemID: UInt64, imageData: Data?) -> Bool { false }
    func setStatusItemToolTip(itemID: UInt64, toolTip: String?) -> Bool { false }
    func setStatusItemImagePosition(itemID: UInt64, position: Int) -> Bool { false }
    func setStatusItemVisible(itemID: UInt64, visible: Bool) -> Bool { false }
    func setStatusItemMenu(itemID: UInt64, menuID: UInt64?) -> Bool { false }
    func setStatusItemAutosaveName(itemID: UInt64, name: String?) -> Bool { false }
    func statusItemFrame(itemID: UInt64) -> (x: Double, y: Double, width: Double, height: Double)? { nil }

    func createMenu(title: String) -> UInt64 { 0 }
    func destroyMenu(menuID: UInt64) -> Bool { false }
    func menuInfo(menuID: UInt64) -> MenuInfo? { nil }
    func setMenuAutoenablesItems(menuID: UInt64, enabled: Bool) -> Bool { false }
    func popUpMenu(menuID: UInt64, atLocation: (x: Double, y: Double)) -> Bool { false }

    func addMenuItem(menuID: UInt64, title: String, keyEquivalent: String) -> UInt64? { nil }
    func addMenuSeparator(menuID: UInt64) -> UInt64? { nil }
    func removeMenuItem(menuID: UInt64, itemID: UInt64) -> Bool { false }
    func menuItemInfo(itemID: UInt64) -> MenuItemInfo? { nil }
    func setMenuItemTitle(itemID: UInt64, title: String) -> Bool { false }
    func setMenuItemEnabled(itemID: UInt64, enabled: Bool) -> Bool { false }
    func setMenuItemState(itemID: UInt64, state: Int) -> Bool { false }
    func setMenuItemImage(itemID: UInt64, imageData: Data?) -> Bool { false }
    func setMenuItemToolTip(itemID: UInt64, toolTip: String?) -> Bool { false }
    func setMenuItemIndentationLevel(itemID: UInt64, level: Int) -> Bool { false }
    func setMenuItemKeyEquivalent(itemID: UInt64, key: String, modifierMask: UInt) -> Bool { false }
    func setMenuItemSubmenu(itemID: UInt64, submenuID: UInt64?) -> Bool { false }
    func setMenuItemTag(itemID: UInt64, tag: Int) -> Bool { false }
    func setMenuItemCallback(itemID: UInt64, callback: @escaping () -> Void) -> Bool { false }
}
