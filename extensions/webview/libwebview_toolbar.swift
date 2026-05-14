import Foundation
import Cocoa
import LuaSkin

private let USERDATA_TB_TAG = "hs.webview.toolbar"
private var refTable: Int32 = LUA_NOREF

private var identifiersInUse: NSMutableArray!

// @encode is a compiler directive which may give different answers on different architectures,
// so instead lets capture the value with the same method we use for testing later on...
private var boolEncodingType: UnsafePointer<CChar>!

// Can't have "static" or "constant" dynamic NSObjects like NSArray, so define in lua_open
private var builtinToolbarItems: [String]!
private var automaticallyIncluded: [String]!
private var keysToKeepFromDefinitionDictionary: [String]!

// MARK: - Forward declarations for external types

@objc protocol MJConsoleWindowControllerProtocol: NSObjectProtocol {
    @objc static func singleton() -> NSWindowController
}

// MARK: - HSToolbarSearchField

private class HSToolbarSearchField: NSSearchField {
    weak var toolbarItem: NSToolbarItem?
    var releaseOnCallback: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    private func commonInit() {
        sendsWholeSearchString = true
        sendsSearchStringImmediately = false
        sizeToFit()

        toolbarItem = nil
        releaseOnCallback = false

        (cell as? NSSearchFieldCell)?.searchMenuTemplate = createCoreSearchFieldMenu()
    }

    @objc func searchCallback(_ sender: NSMenuItem) {
        stringValue = sender.title
        (toolbarItem?.toolbar as? HSToolbar)?.performCallback(self)
    }
}

// MARK: - HSToolbar

private class HSToolbar: NSToolbar, NSToolbarDelegate {
    var selfRef: Int32 = LUA_NOREF
    var callbackRef: Int32 = LUA_NOREF
    var notifyToolbarChanges: Bool = false
    var toolbarStyleValue: NSWindow.ToolbarStyle = .automatic
    weak var windowUsingToolbar: NSWindow?
    let allowedIdentifiers = NSMutableOrderedSet()
    let defaultIdentifiers = NSMutableOrderedSet()
    let selectableIdentifiers = NSMutableOrderedSet()
    let itemDefDictionary = NSMutableDictionary()
    let fnRefDictionary = NSMutableDictionary()
    let enabledDictionary = NSMutableDictionary()

    convenience init?(identifier: String, itemTableIndex idx: Int32, state L: OpaquePointer!) {
        self.init(identifier: NSToolbar.Identifier(identifier))

        toolbarStyleValue = .automatic
        callbackRef = LUA_NOREF
        selfRef = LUA_NOREF
        windowUsingToolbar = nil
        notifyToolbarChanges = false

        allowedIdentifiers.addObjects(from: automaticallyIncluded)

        if idx != LUA_NOREF {
            let skin = LuaSkin.shared(withState: L)!
            let count = luaL_len(L, idx)
            var index: lua_Integer = 0
            var isGood = true

            let absIdx = lua_absindex(L, idx)
            while isGood && (index < count) {
                if lua_rawgeti(L, absIdx, index + 1) == LUA_TTABLE {
                    isGood = addToolbarDefinition(atIndex: -1, withState: L)
                } else {
                    skin.logWarn(String(format: "%s:not a table at index %lld in toolbar %@",
                                        USERDATA_TB_TAG, index + 1, identifier as NSString))
                    isGood = false
                }
                lua_pop(L, 1)
                index += 1
            }

            if !isGood {
                skin.logError(String(format: "%s:malformed toolbar items encountered", USERDATA_TB_TAG))
                return nil
            }
        }

        allowsUserCustomization = false
        if responds(to: Selector(("setAllowsExtensionItems:"))) {
            allowsExtensionItems = false
        }
        autosavesConfiguration = false
        delegate = self
    }

    convenience init?(copy original: HSToolbar, state L: OpaquePointer!) {
        let skin = LuaSkin.shared(withState: L)!
        self.init(identifier: original.identifier)

        selfRef = LUA_NOREF
        callbackRef = LUA_NOREF
        if original.callbackRef != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: original.callbackRef)
            callbackRef = skin.luaRef(refTable)
        }

        // Share the same ordered sets (matches ObjC behavior — direct assignment)
        for obj in original.allowedIdentifiers { allowedIdentifiers.add(obj) }
        for obj in original.defaultIdentifiers { defaultIdentifiers.add(obj) }
        for obj in original.selectableIdentifiers { selectableIdentifiers.add(obj) }
        notifyToolbarChanges = original.notifyToolbarChanges
        windowUsingToolbar = nil

        toolbarStyleValue = original.toolbarStyleValue

        allowsUserCustomization = original.allowsUserCustomization
        if responds(to: Selector(("setAllowsExtensionItems:"))) {
            allowsExtensionItems = original.allowsExtensionItems
        }
        autosavesConfiguration = original.autosavesConfiguration

        // Share item definitions (matches ObjC — direct assignment)
        for (key, value) in original.itemDefDictionary {
            itemDefDictionary[key] = value
        }
        // Deep copy enabled dictionary
        for (key, value) in original.enabledDictionary {
            enabledDictionary[key] = (value as? NSObject)?.copy()
        }
        // Deep copy fn refs
        for (key, value) in original.fnRefDictionary {
            guard let key = key as? String else { continue }
            var theRef = (value as? NSNumber)?.int32Value ?? LUA_NOREF
            if theRef != LUA_NOREF {
                skin.pushLuaRef(refTable, ref: theRef)
                theRef = skin.luaRef(refTable)
            }
            fnRefDictionary[key] = NSNumber(value: theRef)
        }

        delegate = self
    }

    @objc func performCallback(_ sender: Any) {
        var searchText: String?
        var item: NSToolbarItem?
        var argCount: Int32 = 3

        if let toolbarItem = sender as? NSToolbarItem {
            item = toolbarItem
        } else if let searchField = sender as? HSToolbarSearchField {
            searchText = searchField.stringValue
            item = searchField.toolbarItem
            argCount += 1
            if searchField.releaseOnCallback {
                DispatchQueue.main.async {
                    searchField.window?.makeFirstResponder(searchField.window?.contentView)
                }
            }
        } else {
            LuaSkin.logError(String(format: "%s:Unknown object sent to callback:%@",
                                     USERDATA_TB_TAG, String(describing: sender)))
            return
        }

        guard let item = item else { return }

        let theFnRef = fnRefDictionary[item.itemIdentifier.rawValue] as? NSNumber
        let itemFnRef = theFnRef?.int32Value ?? LUA_NOREF
        let fnRef = (itemFnRef != LUA_NOREF) ? itemFnRef : callbackRef
        if fnRef != LUA_NOREF {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if fnRef != LUA_NOREF {
                    let ourWindow = self.windowUsingToolbar
                    let skin = LuaSkin.shared(withState: nil)!
                    let L = skin.L!
                    _lua_stackguard_entry(L)
                    skin.pushLuaRef(refTable, ref: fnRef)
                    skin.pushNSObject(self)
                    if let ourWindow = ourWindow {
                        if let consoleClass = NSClassFromString("MJConsoleWindowController") as? NSObjectProtocol {
                            let singleton = consoleClass.perform(Selector(("singleton")))?.takeUnretainedValue() as? NSWindowController
                            if let consoleWindow = singleton?.window, ourWindow.isEqual(consoleWindow) {
                                lua_pushstring(L, "console")
                            } else if ourWindow.windowController != nil {
                                skin.pushNSObject(ourWindow.windowController!, withOptions: LS_NSDescribeUnknownTypes)
                            } else {
                                skin.pushNSObject(ourWindow, withOptions: LS_NSDescribeUnknownTypes)
                            }
                        } else {
                            skin.pushNSObject(ourWindow, withOptions: LS_NSDescribeUnknownTypes)
                        }
                    } else {
                        lua_pushstring(L, "** no window attached")
                    }
                    skin.pushNSObject(item.itemIdentifier.rawValue as NSString)
                    if argCount == 4 { skin.pushNSObject(searchText as NSString?) }
                    skin.protectedCallAndError("hs.webview.toolbar item callback (\(item.itemIdentifier.rawValue))",
                                               nargs: argCount, nresults: 0)
                    _lua_stackguard_exit(L)
                }
            }
        }
    }

    func validateToolbarItem(_ theItem: NSToolbarItem) -> Bool {
        if let val = enabledDictionary[theItem.itemIdentifier.rawValue] as? NSNumber {
            return val.boolValue
        }
        return true
    }

    func isAttachedToWindow() -> Bool {
        guard let ourWindow = windowUsingToolbar else { return false }
        let attached = isEqual(ourWindow.toolbar)
        if !attached { windowUsingToolbar = nil }
        return attached
    }

    // MARK: - Item definition parsing

    func addToolbarDefinition(atIndex idx: Int32, withState L: OpaquePointer!) -> Bool {
        let skin = LuaSkin.shared(withState: L)!
        let absIdx = lua_absindex(L, idx)

        var identifier: String?
        if lua_getfield(L, absIdx, "id") == LUA_TSTRING {
            identifier = skin.toNSObject(atIndex: -1) as? String
        }
        lua_pop(L, 1)

        guard let identifier = identifier else {
            skin.logWarn(String(format: "%s:id must be present, and it must be a string", USERDATA_TB_TAG))
            return false
        }
        if itemDefDictionary[identifier] != nil {
            skin.logWarn(String(format: "%s:identifier %@ must be unique or a system defined item",
                                USERDATA_TB_TAG, identifier as NSString))
            return false
        }

        let selectable = (lua_getfield(L, absIdx, "selectable") == LUA_TBOOLEAN) ? (lua_toboolean(L, -1) != 0) : false
        let allowedAlone = (lua_getfield(L, absIdx, "allowedAlone") == LUA_TBOOLEAN) ? (lua_toboolean(L, -1) != 0) : true
        let included = (lua_getfield(L, absIdx, "default") == LUA_TBOOLEAN) ? (lua_toboolean(L, -1) != 0) : allowedAlone
        lua_pop(L, 3)

        enabledDictionary[identifier] = NSNumber(value: true)

        if !(builtinToolbarItems.contains(identifier)) {
            let toolbarItem = NSMutableDictionary()
            var isGroup = false

            lua_pushnil(L)
            while lua_next(L, absIdx) != 0 {
                if lua_type(L, -2) == LUA_TSTRING {
                    let keyName = skin.toNSObject(atIndex: -2) as! String
                    if !(keysToKeepFromDefinitionDictionary.contains(keyName)) {
                        if lua_type(L, -1) != LUA_TFUNCTION {
                            toolbarItem[keyName] = skin.toNSObject(atIndex: -1)
                            if keyName == "groupMembers" { isGroup = true }
                        } else if keyName == "fn" {
                            lua_pushvalue(L, -1)
                            fnRefDictionary[identifier] = NSNumber(value: skin.luaRef(refTable))
                        }
                    }
                } else {
                    skin.logWarn(String(format: "%s:non-string keys not allowed for toolbar item %@ definition",
                                        USERDATA_TB_TAG, identifier as NSString))
                    lua_pop(L, 2)
                    return false
                }
                lua_pop(L, 1)
            }

            if toolbarItem["label"] == nil && !isGroup { toolbarItem["label"] = identifier }
            if selectable { selectableIdentifiers.add(identifier) }
            itemDefDictionary[identifier] = toolbarItem
        }

        if !allowedIdentifiers.contains(identifier) && allowedAlone {
            allowedIdentifiers.add(identifier)
        }
        if included {
            defaultIdentifiers.add(identifier)
        }

        return true
    }

    func fillinNewToolbarItem(_ item: NSToolbarItem) {
        let skin = LuaSkin.shared(withState: nil)!
        updateToolbarItem(item,
                          withDictionary: itemDefDictionary[item.itemIdentifier.rawValue] as? NSMutableDictionary,
                          inGroup: false,
                          withState: skin.L)
    }

    func updateToolbarItem(_ item: NSToolbarItem,
                           withDictionary itemDefinition: NSMutableDictionary?,
                           withState L: OpaquePointer!) {
        updateToolbarItem(item, withDictionary: itemDefinition, inGroup: false, withState: L)
    }

    func updateToolbarItem(_ item: NSToolbarItem,
                           withDictionary itemDefinition: NSMutableDictionary?,
                           inGroup: Bool,
                           withState L: OpaquePointer!) {
        guard let itemDefinition = itemDefinition else { return }
        let skin = LuaSkin.shared(withState: L)!
        var itemView = item.view as? HSToolbarSearchField
        let identifier = item.itemIdentifier.rawValue

        if itemDefinition.count == 0 {
            if item.label.isEmpty { item.label = identifier }
            return
        }

        // Handle searchfield first
        if let keyValue = itemDefinition["searchfield"] {
            if let numVal = keyValue as? NSNumber, strcmp(boolEncodingType, numVal.objCType) == 0 {
                if numVal.boolValue {
                    if !(itemView is HSToolbarSearchField) {
                        if itemView == nil {
                            let newField = HSToolbarSearchField()
                            newField.toolbarItem = item
                            newField.target = self
                            newField.action = #selector(performCallback(_:))
                            item.view = newField
                            itemView = newField
                            if !inGroup {
                                item.minSize = newField.frame.size
                                item.maxSize = newField.frame.size
                            }
                        } else {
                            skin.logWarn(String(format: "%s:view for toolbar item %@ is not our searchfield... cowardly avoiding replacement",
                                                USERDATA_TB_TAG, identifier as NSString))
                        }
                    }
                } else {
                    if let existing = itemView {
                        if !(existing is HSToolbarSearchField) {
                            skin.logWarn(String(format: "%s:view for toolbar item %@ is not our searchfield... cowardly avoiding removal",
                                                USERDATA_TB_TAG, identifier as NSString))
                        } else {
                            item.view = nil
                            itemView = nil
                        }
                    }
                }
            } else {
                skin.logWarn(String(format: "%s:searchfield for %@ must be a boolean", USERDATA_TB_TAG, identifier as NSString))
                itemDefinition.removeObject(forKey: "searchfield")
            }
        }

        // Handle searchPredefinedMenuTitle
        if let keyValue = itemDefinition["searchPredefinedMenuTitle"] {
            if (keyValue is String) || (keyValue is NSNumber && strcmp(boolEncodingType, (keyValue as! NSNumber).objCType) == 0) {
                if itemDefinition !== itemDefDictionary[identifier] as? NSMutableDictionary && itemDefinition["searchPredefinedSearches"] == nil {
                    itemDefinition["searchPredefinedSearches"] = (itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedSearches"]
                }
            } else {
                skin.logWarn(String(format: "%s:searchPredefinedMenuTitle for %@ must be a string or a boolean",
                                    USERDATA_TB_TAG, identifier as NSString))
                itemDefinition.removeObject(forKey: "searchPredefinedMenuTitle")
            }
        }

        for keyName in (itemDefinition.allKeys as! [String]) {
            let keyValue = itemDefinition[keyName]!

            if keyName == "enable" {
                if let numVal = keyValue as? NSNumber, strcmp(boolEncodingType, numVal.objCType) == 0 {
                    enabledDictionary[identifier] = itemDefinition[keyName]
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be a boolean",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "fn" {
                if let existingRef = fnRefDictionary[identifier] as? NSNumber, existingRef.int32Value != LUA_NOREF {
                    skin.luaUnref(refTable, ref: existingRef.int32Value)
                }
                skin.pushLuaRef(refTable, ref: (itemDefinition[keyName] as! NSNumber).int32Value)
                fnRefDictionary[identifier] = NSNumber(value: skin.luaRef(refTable))
            } else if keyName == "label" {
                if let strVal = keyValue as? String {
                    item.label = strVal
                    item.paletteLabel = strVal
                } else {
                    if let numVal = keyValue as? NSNumber, !numVal.boolValue {
                        if let group = item as? NSToolbarItemGroup {
                            // This is the only way to switch a grouped set's individual labels back on
                            group.label = "" // set to empty since Swift won't allow nil
                            group.paletteLabel = ""
                        } else {
                            item.label = ""
                            item.paletteLabel = identifier
                        }
                    } else {
                        skin.logWarn(String(format: "%s:%@ for %@ must be a string, or false to clear",
                                            USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "tooltip" {
                if let strVal = keyValue as? String {
                    item.toolTip = strVal
                } else {
                    if let numVal = keyValue as? NSNumber, !numVal.boolValue {
                        item.toolTip = nil
                    } else {
                        skin.logWarn(String(format: "%s:%@ for %@ must be a string, or false to clear",
                                            USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "priority" {
                if let numVal = keyValue as? NSNumber {
                    item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: numVal.intValue)
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be an integer",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "tag" {
                if let numVal = keyValue as? NSNumber {
                    item.tag = numVal.intValue
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be an integer",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "image" {
                if let imgVal = keyValue as? NSImage {
                    item.image = imgVal
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be an hs.image object",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "groupMembers" {
                if item is NSToolbarItemGroup && !inGroup {
                    if let members = keyValue as? [Any] {
                        var allGood = true
                        for lineItem in members {
                            if !(lineItem is String) { allGood = false; break }
                        }
                        if allGood {
                            let groupItem = item as! NSToolbarItemGroup
                            var newSubitems: [NSToolbarItem] = []
                            let oldSubitems = groupItem.subitems
                            var updateViews: [NSToolbarItem] = []

                            for memberIdentifier in (members as! [String]) {
                                let existingIndex = oldSubitems.firstIndex { $0.itemIdentifier.rawValue == memberIdentifier }
                                let memberItem: NSToolbarItem
                                if let idx = existingIndex {
                                    memberItem = oldSubitems[idx]
                                } else {
                                    memberItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(memberIdentifier))
                                    memberItem.target = self
                                    memberItem.action = #selector(performCallback(_:))
                                    memberItem.isEnabled = (enabledDictionary[memberIdentifier] as? NSNumber)?.boolValue ?? true
                                    updateToolbarItem(memberItem,
                                                      withDictionary: itemDefDictionary[memberIdentifier] as? NSMutableDictionary,
                                                      inGroup: true,
                                                      withState: L)
                                    if memberItem.view is HSToolbarSearchField {
                                        updateViews.append(memberItem)
                                    }
                                }
                                newSubitems.append(memberItem)
                            }

                            groupItem.subitems = newSubitems

                            // NSToolbarItemGroup is dumb...
                            // size of a sub-item's view needs to be adjusted *after* adding them to the group
                            for tmpItem in updateViews {
                                let tmpItemDictionary = itemDefDictionary[tmpItem.itemIdentifier.rawValue] as? NSDictionary
                                let searchView = tmpItem.view as! HSToolbarSearchField
                                var searchFieldFrame = searchView.frame
                                if let w = tmpItemDictionary?["searchWidth"] as? NSNumber {
                                    searchFieldFrame.size.width = CGFloat(w.doubleValue)
                                }
                                tmpItem.minSize = searchFieldFrame.size
                                tmpItem.maxSize = searchFieldFrame.size
                            }

                            // *and* it internally calculates the itemGroup's size wrong
                            var minSize = NSSize.zero
                            var maxSize = NSSize.zero
                            for tmpItem in groupItem.subitems {
                                minSize.width += tmpItem.minSize.width
                                minSize.height = max(minSize.height, tmpItem.minSize.height)
                                maxSize.width += tmpItem.maxSize.width
                                maxSize.height = max(maxSize.height, tmpItem.maxSize.height)
                            }
                            item.minSize = minSize
                            item.maxSize = maxSize
                        } else {
                            skin.logWarn(String(format: "%s:%@ for %@ must be an array of strings",
                                                USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                            itemDefinition.removeObject(forKey: keyName)
                        }
                    } else {
                        skin.logWarn(String(format: "%s:%@ for %@ must be an array",
                                            USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    }
                } else {
                    if inGroup {
                        skin.logWarn(String(format: "%s:%@ is in a group and cannot contain group members. Remove item from it's group first.",
                                            USERDATA_TB_TAG, identifier as NSString))
                    } else {
                        skin.logWarn(String(format: "%s:cannot change currently visible toolbar item %@ type. Remove item from toolbar first.",
                                            USERDATA_TB_TAG, identifier as NSString))
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchWidth" && itemView is HSToolbarSearchField {
                if let numVal = keyValue as? NSNumber {
                    if !inGroup {
                        var fieldFrame = itemView!.frame
                        fieldFrame.size.width = CGFloat(numVal.doubleValue)
                        item.minSize = fieldFrame.size
                        item.maxSize = fieldFrame.size
                    }
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be a number",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchReleaseFocusOnCallback" && itemView is HSToolbarSearchField {
                if let numVal = keyValue as? NSNumber, strcmp(boolEncodingType, numVal.objCType) == 0 {
                    itemView!.releaseOnCallback = numVal.boolValue
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be a boolean",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchText" && itemView is HSToolbarSearchField {
                if let strVal = keyValue as? String {
                    itemView!.stringValue = strVal
                } else if let numVal = keyValue as? NSNumber {
                    itemView!.stringValue = numVal.stringValue
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be a string",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchPredefinedSearches" && itemView is HSToolbarSearchField {
                if let arr = keyValue as? [Any] {
                    var allGood = true
                    for lineItem in arr { if !(lineItem is String) { allGood = false; break } }
                    if allGood {
                        var searchMenu = createCoreSearchFieldMenu()
                        let predefinedSearchMenu = NSMenu(title: "Predefined Search Menu")
                        for menuItemText in (arr as! [String]) {
                            let newMenuItem = NSMenuItem(title: menuItemText,
                                                         action: #selector(HSToolbarSearchField.searchCallback(_:)),
                                                         keyEquivalent: "")
                            newMenuItem.target = itemView
                            predefinedSearchMenu.addItem(newMenuItem)
                        }

                        var menuName: String? = "Predefined Searches"
                        let checkForTitle = itemDefinition["searchPredefinedMenuTitle"]
                            ?? (itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedMenuTitle"]

                        if let checkForTitle = checkForTitle {
                            if let numVal = checkForTitle as? NSNumber, strcmp(boolEncodingType, numVal.objCType) == 0 {
                                if !numVal.boolValue { menuName = nil }
                            } else if let strVal = checkForTitle as? String {
                                menuName = strVal
                            }
                        }

                        if let menuName = menuName {
                            let predefinedSearches = NSMenuItem(title: menuName, action: nil, keyEquivalent: "")
                            predefinedSearches.submenu = predefinedSearchMenu
                            searchMenu.insertItem(predefinedSearches, at: 0)
                            searchMenu.insertItem(.separator(), at: 1)
                        } else {
                            searchMenu = predefinedSearchMenu
                        }
                        (itemView!.cell as? NSSearchFieldCell)?.searchMenuTemplate = searchMenu
                    } else {
                        skin.logWarn(String(format: "%s:%@ for %@ must be an array of strings",
                                            USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                        itemDefinition.removeObject(forKey: keyName)
                    }
                } else {
                    if let numVal = keyValue as? NSNumber, !numVal.boolValue {
                        let searchMenu = createCoreSearchFieldMenu()
                        (itemView!.cell as? NSSearchFieldCell)?.searchMenuTemplate = searchMenu
                    } else {
                        skin.logWarn(String(format: "%s:%@ for %@ must be an array, or false to remove",
                                            USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistoryLimit" && itemView is HSToolbarSearchField {
                if let numVal = keyValue as? NSNumber {
                    (itemView!.cell as? NSSearchFieldCell)?.maximumRecents = numVal.intValue
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be an integer",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistory" && itemView is HSToolbarSearchField {
                if let arr = keyValue as? [Any] {
                    var allGood = true
                    for lineItem in arr { if !(lineItem is String) { allGood = false; break } }
                    if allGood {
                        (itemView!.cell as? NSSearchFieldCell)?.recentSearches = (arr as! [String])
                    } else {
                        skin.logWarn(String(format: "%s:%@ for %@ must be an array of strings",
                                            USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                        itemDefinition.removeObject(forKey: keyName)
                    }
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be an array",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistoryAutosaveName" && itemView is HSToolbarSearchField {
                if let strVal = keyValue as? String {
                    (itemView!.cell as? NSSearchFieldCell)?.recentsAutosaveName = NSSearchFieldCell.RecentsAutosaveName(strVal)
                    _ = (itemView!.cell as? NSSearchFieldCell)?.recentSearches // force load
                } else if let numVal = keyValue as? NSNumber {
                    (itemView!.cell as? NSSearchFieldCell)?.recentsAutosaveName = NSSearchFieldCell.RecentsAutosaveName(numVal.stringValue)
                    _ = (itemView!.cell as? NSSearchFieldCell)?.recentSearches // force load
                } else {
                    skin.logWarn(String(format: "%s:%@ for %@ must be a string",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName != "searchfield" && keyName != "searchPredefinedMenuTitle" {
                skin.logVerbose(String(format: "%s:%@ is not a valid field for %@; ignoring",
                                        USERDATA_TB_TAG, keyName as NSString, identifier as NSString))
                itemDefinition.removeObject(forKey: keyName)
            }
        }

        // If we weren't sent the actual item's full dictionary, then this must be an update
        if itemDefDictionary[identifier] as? NSMutableDictionary !== itemDefinition {
            (itemDefDictionary[identifier] as? NSMutableDictionary)?.addEntries(from: itemDefinition as! [AnyHashable: Any])
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let itemDefinition = itemDefDictionary[itemIdentifier.rawValue] as? NSDictionary else {
            return nil
        }

        let toolbarItem: NSToolbarItem
        if let members = itemDefinition["groupMembers"], members is NSArray {
            toolbarItem = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
        } else {
            toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            toolbarItem.target = toolbar
            toolbarItem.action = #selector(performCallback(_:))
        }
        toolbarItem.isEnabled = flag ? validateToolbarItem(toolbarItem) : true
        fillinNewToolbarItem(toolbarItem)
        return toolbarItem
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return (allowedIdentifiers.array as! [String]).map { NSToolbarItem.Identifier($0) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return (defaultIdentifiers.array as! [String]).map { NSToolbarItem.Identifier($0) }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return (selectableIdentifiers.array as! [String]).map { NSToolbarItem.Identifier($0) }
    }

    func toolbarWillAddItem(_ notification: Notification) {
        if notifyToolbarChanges && (callbackRef != LUA_NOREF) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.callbackRef != LUA_NOREF else { return }
                let ourWindow = self.windowUsingToolbar
                let skin = LuaSkin.shared(withState: nil)!
                let L = skin.L!
                _lua_stackguard_entry(L)
                skin.pushLuaRef(refTable, ref: self.callbackRef)
                skin.pushNSObject(self)
                self.pushWindowOrConsole(ourWindow, skin: skin, L: L)
                if let addedItem = notification.userInfo?["item"] as? NSToolbarItem {
                    skin.pushNSObject(addedItem.itemIdentifier.rawValue as NSString)
                }
                lua_pushstring(L, "add")
                skin.protectedCallAndError("hs.webview.toolbar toolbar item addition callback",
                                           nargs: 4, nresults: 0)
                _lua_stackguard_exit(L)
            }
        }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        if notifyToolbarChanges && (callbackRef != LUA_NOREF) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.callbackRef != LUA_NOREF else { return }
                let ourWindow = self.windowUsingToolbar
                let skin = LuaSkin.shared(withState: nil)!
                let L = skin.L!
                _lua_stackguard_entry(L)
                skin.pushLuaRef(refTable, ref: self.callbackRef)
                skin.pushNSObject(self)
                self.pushWindowOrConsole(ourWindow, skin: skin, L: L)
                if let removedItem = notification.userInfo?["item"] as? NSToolbarItem {
                    skin.pushNSObject(removedItem.itemIdentifier.rawValue as NSString)
                }
                lua_pushstring(L, "remove")
                skin.protectedCallAndError("hs.webview.toolbar toolbar item removal callback",
                                           nargs: 4, nresults: 0)
                _lua_stackguard_exit(L)
            }
        }
    }

    // Helper to push the window or "console" string
    private func pushWindowOrConsole(_ ourWindow: NSWindow?, skin: LuaSkin, L: OpaquePointer) {
        if let ourWindow = ourWindow {
            if let consoleClass = NSClassFromString("MJConsoleWindowController") as? NSObjectProtocol {
                let singleton = consoleClass.perform(Selector(("singleton")))?.takeUnretainedValue() as? NSWindowController
                if let consoleWindow = singleton?.window, ourWindow.isEqual(consoleWindow) {
                    lua_pushstring(L, "console")
                    return
                }
            }
            if ourWindow.windowController != nil {
                skin.pushNSObject(ourWindow.windowController!, withOptions: LS_NSDescribeUnknownTypes)
            } else {
                skin.pushNSObject(ourWindow, withOptions: LS_NSDescribeUnknownTypes)
            }
        } else {
            lua_pushstring(L, "** no window attached")
        }
    }
}

// MARK: - Support Functions

private func createCoreSearchFieldMenu() -> NSMenu {
    let searchMenu = NSMenu(title: "Search Menu")
    searchMenu.autoenablesItems = true

    let recentsTitleItem = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
    recentsTitleItem.tag = Int(NSSearchFieldCell.recentsTitleMenuItemTag)
    searchMenu.insertItem(recentsTitleItem, at: 0)

    let norecentsTitleItem = NSMenuItem(title: "No recent searches", action: nil, keyEquivalent: "")
    norecentsTitleItem.tag = Int(NSSearchFieldCell.noRecentsMenuItemTag)
    searchMenu.insertItem(norecentsTitleItem, at: 1)

    let recentsItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
    recentsItem.tag = Int(NSSearchFieldCell.recentsMenuItemTag)
    searchMenu.insertItem(recentsItem, at: 2)

    searchMenu.insertItem(.separator(), at: 3)

    let clearItem = NSMenuItem(title: "Clear", action: nil, keyEquivalent: "")
    clearItem.tag = Int(NSSearchFieldCell.clearRecentsMenuItemTag)
    searchMenu.insertItem(clearItem, at: 4)

    return searchMenu
}

// Helper to get HSToolbar from userdata
private func getToolbarFromUD(_ L: OpaquePointer!, _ idx: Int32) -> HSToolbar {
    let ptr = luaL_checkudata(L, idx, USERDATA_TB_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    return Unmanaged<HSToolbar>.fromOpaque(ptr.pointee!).takeUnretainedValue()
}

// Helper to get a raw NSWindow from a userdata tag (for hs.webview or hs.chooser)
private func getWindowFromUserdata(_ L: OpaquePointer!, _ idx: Int32, _ tag: String) -> NSWindow? {
    guard let ptr = luaL_checkudata(L, idx, tag) else { return nil }
    let bound = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = bound.pointee else { return nil }
    return Unmanaged<NSWindow>.fromOpaque(rawPtr).takeUnretainedValue()
}

private func getControllerFromUserdata(_ L: OpaquePointer!, _ idx: Int32, _ tag: String) -> NSWindowController? {
    guard let ptr = luaL_checkudata(L, idx, tag) else { return nil }
    let bound = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = bound.pointee else { return nil }
    return Unmanaged<NSWindowController>.fromOpaque(rawPtr).takeUnretainedValue()
}

// MARK: - Module Functions

/// hs.webview.toolbar.new(toolbarName, [toolbarTable]) -> toolbarObject
/// Constructor
/// Creates a new toolbar for a webview, chooser, or the console.
///
/// Parameters:
///  * toolbarName  - a string specifying the name for this toolbar
///  * toolbarTable - an optional table describing possible items for the toolbar
///
/// Returns:
///  * a toolbarObject
///
/// Notes:
///  * Toolbar names must be unique, but a toolbar may be copied with [hs.webview.toolbar:copy](#copy) if you wish to attach it to multiple windows (webview, chooser, or console).
///  * See [hs.webview.toolbar:addItems](#addItems) for a description of the format for `toolbarTable`
private func newHSToolbar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let identifier = skin.toNSObject(atIndex: 1) as! String

    let idx: Int32 = (lua_gettop(L) == 2) ? 2 : LUA_NOREF

    if !(identifiersInUse.contains(identifier)) {
        if let toolbar = HSToolbar(identifier: identifier, itemTableIndex: idx, state: L) {
            skin.pushNSObject(toolbar)
        } else {
            lua_pushnil(L)
        }
    } else {
        return luaL_argerror(L, 1, "identifier already in use")
    }
    return 1
}

/// hs.webview.toolbar.uniqueName(toolbarName) -> boolean
/// Function
/// Checks to see is a toolbar name is already in use
///
/// Parameters:
///  * toolbarName  - a string specifying the name of a toolbar
///
/// Returns:
///  * `true` if the name is unique otherwise `false`
private func uniqueName(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let identifier = skin.toNSObject(atIndex: 1) as! String
    lua_pushboolean(L, !(identifiersInUse.contains(identifier)) ? 1 : 0)
    return 1
}

/// hs.webview.toolbar.attachToolbar([obj1], [obj2]) -> obj1
/// Function
/// Get or attach/detach a toolbar to the webview, chooser, or console.
///
/// Parameters:
///  * obj1 - An optional toolbarObject
///  * obj2 - An optional toolbarObject
///   * if no arguments are present, this function returns the current toolbarObject for the Hammerspoon console, or nil if one is not attached.
///   * if one argument is provided and it is a toolbarObject or nil, this function will attach or detach a toolbarObject to/from the Hammerspoon console.
///   * if one argument is provided and it is an hs.webview or hs.chooser object, this function will return the current toolbarObject for the object, or nil if one is not attached.
///   * if two arguments are provided and the first is an hs.webview or hs.chooser object and the second is a toolbarObject or nil, this function will attach or detach a toolbarObject to/from the object.
///
/// Returns:
///  * if the function is used to attach/detach a toolbar, then the first object provided (the target) will be returned ; if this function is used to get the current toolbar object for a webview, chooser, or console, then the toolbarObject or nil will be returned.
///
/// Notes:
///  * This function is not expected to be used directly (though it can be) -- it is added to the `hs.webview` and `hs.chooser` object metatables so that it may be invoked as `hs.webview:attachedToolbar([toolbarObject | nil])`/`hs.chooser:attachedToolbar([toolbarObject | nil])` and to the `hs.console` module so that it may be invoked as `hs.console.toolbar([toolbarObject | nil])`.
///
///  * If the toolbar is currently attached to another window when this function is called, it will be detached from the original window and attached to the new one specified by this function.
private func attachToolbar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    var theWindow: NSWindow?
    var newToolbar: HSToolbar?
    var setToolbar = true
    var isChooser = false

    let top = lua_gettop(L)

    func getConsoleWindow() -> NSWindow? {
        guard let consoleClass = NSClassFromString("MJConsoleWindowController") as? NSObjectProtocol else { return nil }
        let singleton = consoleClass.perform(Selector(("singleton")))?.takeUnretainedValue() as? NSWindowController
        return singleton?.window
    }

    // hs.console
    if top == 0 {
        theWindow = getConsoleWindow()
        newToolbar = nil
        setToolbar = false
    } else if top == 1 && lua_type(L, 1) == LUA_TNIL {
        theWindow = getConsoleWindow()
        newToolbar = nil
        setToolbar = true
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, USERDATA_TB_TAG) != nil {
        theWindow = getConsoleWindow()
        newToolbar = skin.toNSObject(atIndex: 1) as? HSToolbar
        setToolbar = true

    // hs.webview
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        newToolbar = nil
        setToolbar = false
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil && lua_type(L, 2) == LUA_TNIL {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        newToolbar = nil
        setToolbar = true
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil && lua_type(L, 2) == LUA_TUSERDATA && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        newToolbar = skin.toNSObject(atIndex: 2) as? HSToolbar
        setToolbar = true

    // hs.chooser
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.chooser") != nil {
        let controller = getControllerFromUserdata(L, 1, "hs.chooser")
        theWindow = controller?.window
        newToolbar = nil
        setToolbar = false
        isChooser = true
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.chooser") != nil && lua_type(L, 2) == LUA_TNIL {
        let controller = getControllerFromUserdata(L, 1, "hs.chooser")
        theWindow = controller?.window
        newToolbar = nil
        setToolbar = true
        isChooser = true
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.chooser") != nil && lua_type(L, 2) == LUA_TUSERDATA && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        let controller = getControllerFromUserdata(L, 1, "hs.chooser")
        theWindow = controller?.window
        newToolbar = skin.toNSObject(atIndex: 2) as? HSToolbar
        setToolbar = true
        isChooser = true

    } else {
        return luaL_error(L, "%s:attachToolbar requires an optional window target object and an %s object or nil",
                          USERDATA_TB_TAG, USERDATA_TB_TAG)
    }

    let oldToolbar = theWindow?.toolbar as? HSToolbar

    if setToolbar {
        if let old = oldToolbar {
            old.isVisible = false
            theWindow?.toolbar = nil
            if isChooser {
                theWindow?.styleMask = [.fullSizeContentView, .nonactivatingPanel]
                theWindow?.isMovable = true
            }
            old.windowUsingToolbar = nil
        }
        if let newToolbar = newToolbar {
            if let existingWindow = newToolbar.windowUsingToolbar {
                existingWindow.toolbar = nil
            }
            if isChooser {
                theWindow?.styleMask = [.titled, .nonactivatingPanel]
                theWindow?.isMovable = false
            }
            theWindow?.toolbar = newToolbar
            newToolbar.windowUsingToolbar = theWindow
            newToolbar.isVisible = true

            theWindow?.toolbarStyle = newToolbar.toolbarStyleValue
        }
        lua_pushvalue(L, 1)
    } else {
        if let old = oldToolbar {
            skin.pushNSObject(old)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

// MARK: - Module Methods

/// hs.webview.toolbar:inTitleBar([state]) -> toolbarObject | boolean
/// Function
/// Get or set whether or not the toolbar appears in the containing window's titlebar, similar to Safari.
///
/// Parameters:
///  * `state` - an optional boolean specifying whether or not the toolbar should appear in the window's titlebar.
///
/// Returns:
///  * if a parameter is specified, returns the toolbar object, otherwise the current value.
///
/// Notes:
///  * When this value is true, the toolbar, when visible, will appear in the window's title bar similar to the toolbar as seen in applications like Safari.  In this state, the toolbar will set the display of the toolbar items to icons without labels, ignoring changes made with [hs.webview.toolbar:displayMode](#displayMode).
///
/// * This method is only valid when the toolbar is attached to a webview, chooser, or the console.
private func toolbar_inTitleBar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let theWindow = toolbar.windowUsingToolbar

    if lua_gettop(L) == 1 {
        if let theWindow = theWindow {
            lua_pushboolean(L, theWindow.titleVisibility == .hidden ? 1 : 0)
        } else {
            lua_pushboolean(L, 0)
        }
    } else {
        if let theWindow = theWindow {
            theWindow.titleVisibility = lua_toboolean(L, 2) != 0 ? .hidden : .visible
        } else {
            skin.logWarn(String(format: "%s:inTitleBar - requires the toolbar to be attached before using",
                                USERDATA_TB_TAG))
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview.toolbar:isAttached() -> boolean
/// Method
/// Returns a boolean indicating whether or not the toolbar is currently attached to a window.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean indicating whether or not the toolbar is currently attached to a window.
private func isAttachedToWindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    lua_pushboolean(L, toolbar.isAttachedToWindow() ? 1 : 0)
    return 1
}

/// hs.webview.toolbar:copy() -> toolbarObject
/// Method
/// Returns a copy of the toolbar object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a copy of the toolbar which can be attached to another window (webview, chooser, or console).
private func copyToolbar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let oldToolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if let newToolbar = HSToolbar(copy: oldToolbar, state: L) {
        skin.pushNSObject(newToolbar)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.webview.toolbar:setCallback(fn) -> toolbarObject
/// Method
/// Sets or removes the global callback function for the toolbar.
///
/// Parameters:
///  * fn - a function to set as the global callback for the toolbar, or nil to remove the global callback. The function should expect three (four, if the item is a `searchfield` or `notifyOnChange` is true) arguments and return none: the toolbar object, "console" or the webview/chooser object the toolbar is attached to, and the toolbar item identifier that was clicked.
///
/// Returns:
///  * the toolbar object.
///
/// Notes:
///  * the global callback function is invoked for a toolbar button item that does not have a specific function assigned directly to it.
///  * if [hs.webview.toolbar:notifyOnChange](#notifyOnChange) is set to true, then this callback function will also be invoked when a toolbar item is added or removed from the toolbar either programmatically with [hs.webview.toolbar:insertItem](#insertItem) and [hs.webview.toolbar:removeItem](#removeItem) or under user control with [hs.webview.toolbar:customizePanel](#customizePanel) and the callback function will receive a string of "add" or "remove" as a fourth argument.
private func setCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar

    toolbar.callbackRef = skin.luaUnref(refTable, ref: toolbar.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        toolbar.callbackRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.toolbar:savedSettings() -> table
/// Method
/// Returns a table containing the settings which will be saved for the toolbar if [hs.webview.toolbar:autosaves](#autosaves) is true.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing the toolbar settings
///
/// Notes:
///  * If the toolbar is set to autosave, then a user-defaults entry is created in org.hammerspoon.Hammerspoon domain with the key "NSToolbar Configuration XXX" where XXX is the toolbar identifier specified when the toolbar was created.
///  * This method is provided if you do not wish for changes to the toolbar to be autosaved for every change, but may wish to save it programmatically under specific conditions.
private func configurationDictionary(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    skin.pushNSObject(toolbar.configurationDictionary as NSDictionary)
    return 1
}

/// hs.webview.toolbar:separator([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the toolbar shows a separator between the toolbar and the main window contents.
///
/// Parameters:
///  * an optional boolean value to enable or disable the separator.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
private func showsBaselineSeparator(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if lua_gettop(L) != 1 {
        toolbar.showsBaselineSeparator = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.showsBaselineSeparator ? 1 : 0)
    }
    return 1
}

/// hs.webview.toolbar:visible([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the toolbar is currently visible in the window it is attached to.
///
/// Parameters:
///  * an optional boolean value to show or hide the toolbar.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
private func visible(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if lua_gettop(L) != 1 {
        toolbar.isVisible = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.isVisible ? 1 : 0)
    }
    return 1
}

/// hs.webview.toolbar:notifyOnChange([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the global callback function is invoked when a toolbar item is added or removed from the toolbar.
///
/// Parameters:
///  * an optional boolean value to enable or disable invoking the global callback for toolbar changes.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
private func notifyWhenToolbarChanges(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if lua_gettop(L) != 1 {
        toolbar.notifyToolbarChanges = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.notifyToolbarChanges ? 1 : 0)
    }
    return 1
}

/// hs.webview.toolbar:insertItem(id, index) -> toolbarObject
/// Method
/// Insert or move the toolbar item to the index position specified
///
/// Parameters:
///  * id    - the string identifier of the toolbar item
///  * index - the numerical position where the toolbar item should be inserted/moved to.
///
/// Returns:
///  * the toolbar object
///
/// Notes:
///  * the toolbar position must be between 1 and the number of currently active toolbar items.
private func insertItemAtIndex(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING, LS_TNUMBER, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let identifier = skin.toNSObject(atIndex: 2) as! String
    var index = Int(luaL_checkinteger(L, 3))

    if toolbar.itemDefDictionary[identifier] == nil {
        return luaL_error(L, "toolbar item %s does not exist", identifier)
    }
    if index < 1 || index > toolbar.items.count + 1 {
        return luaL_error(L, "index out of bounds")
    }
    if !toolbar.allowedIdentifiers.contains(identifier) {
        return luaL_error(L, "%s is not allowed outside of its group", identifier)
    }

    let itemIdentifiers = toolbar.items.map { $0.itemIdentifier.rawValue }
    if let itemIndex = itemIdentifiers.firstIndex(of: identifier) {
        if !toolbar.items[itemIndex].allowsDuplicatesInToolbar {
            toolbar.removeItem(at: itemIndex)
            if index > toolbar.items.count + 1 { index -= 1 }
        }
    }

    toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(identifier), at: index - 1)
    lua_pushvalue(L, 1)
    return 1
}

// NOTE: wrapped and documented in toolbar.lua
private func removeItemAtIndex(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TNUMBER, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let index = Int(luaL_checkinteger(L, 2))

    if index < 1 || index > toolbar.items.count + 1 {
        return luaL_error(L, "index out of bounds")
    }
    toolbar.removeItem(at: index - 1)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.toolbar:sizeMode([size]) -> toolbarObject
/// Method
/// Get or set the toolbar's size.
///
/// Parameters:
///  * size - an optional string to set the size of the toolbar to "default", "regular", or "small".
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
private func sizeMode(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar

    if lua_gettop(L) == 2 {
        let size = skin.toNSObject(atIndex: 2) as! String
        switch size {
        case "default": toolbar.sizeMode = .default
        case "regular": toolbar.sizeMode = .regular
        case "small":   toolbar.sizeMode = .small
        default:        return luaL_error(L, "invalid sizeMode:%s", size)
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.sizeMode {
        case .default: skin.pushNSObject("default" as NSString)
        case .regular: skin.pushNSObject("regular" as NSString)
        case .small:   skin.pushNSObject("small" as NSString)
        @unknown default:
            skin.pushNSObject(String(format: "** unrecognized sizeMode (%tu)", toolbar.sizeMode.rawValue) as NSString)
        }
    }
    return 1
}

/// hs.webview.toolbar:displayMode([mode]) -> toolbarObject
/// Method
/// Get or set the toolbar's display mode.
///
/// Parameters:
///  * mode - an optional string to set the size of the toolbar to "default", "label", "icon", or "both".
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
private func displayMode(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar

    if lua_gettop(L) == 2 {
        let mode = skin.toNSObject(atIndex: 2) as! String
        switch mode {
        case "default": toolbar.displayMode = .default
        case "label":   toolbar.displayMode = .labelOnly
        case "icon":    toolbar.displayMode = .iconOnly
        case "both":    toolbar.displayMode = .iconAndLabel
        default:        return luaL_error(L, "invalid displayMode:%s", mode)
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.displayMode {
        case .default:      skin.pushNSObject("default" as NSString)
        case .labelOnly:    skin.pushNSObject("label" as NSString)
        case .iconOnly:     skin.pushNSObject("icon" as NSString)
        case .iconAndLabel: skin.pushNSObject("both" as NSString)
        @unknown default:
            skin.pushNSObject(String(format: "** unrecognized displayMode (%tu)", toolbar.displayMode.rawValue) as NSString)
        }
    }
    return 1
}

/// hs.webview.toolbar:toolbarStyle([style]) -> toolbarObject
/// Method
/// Get or set the toolbar's style.
///
/// Parameters:
///  * style - an optional string to set the style of the toolbar to "automatic", "expanded", "preference", "unified", or "unifiedCompact".
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * This is only available for macOS 11.0+. Will return `nil` if getting on an earlier version of macOS.
///  * `automatic` - A style indicating that the system determines the toolbar's appearance and location.
///  * `expanded` - A style indicating that the toolbar appears below the window title.
///  * `preference` - A style indicating that the toolbar appears below the window title with toolbar items centered in the toolbar.
///  * `unified` - A style indicating that the toolbar appears next to the window title.
///  * `unifiedCompact` - A style indicating that the toolbar appears next to the window title and with reduced margins to allow more focus on the window's contents.
private func toolbarStyle(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar

    if lua_gettop(L) == 2 {
        let style = skin.toNSObject(atIndex: 2) as! String
        switch style {
        case "automatic":      toolbar.toolbarStyleValue = .automatic
        case "expanded":       toolbar.toolbarStyleValue = .expanded
        case "preference":     toolbar.toolbarStyleValue = .preference
        case "unified":        toolbar.toolbarStyleValue = .unified
        case "unifiedCompact": toolbar.toolbarStyleValue = .unifiedCompact
        default:               return luaL_error(L, "invalid toolbarStyle: '%s'", style)
        }
        if let win = toolbar.windowUsingToolbar {
            win.toolbarStyle = toolbar.toolbarStyleValue
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.toolbarStyleValue {
        case .automatic:      skin.pushNSObject("automatic" as NSString)
        case .expanded:       skin.pushNSObject("expanded" as NSString)
        case .preference:     skin.pushNSObject("preference" as NSString)
        case .unified:        skin.pushNSObject("unified" as NSString)
        case .unifiedCompact: skin.pushNSObject("unifiedCompact" as NSString)
        @unknown default:
            skin.pushNSObject(String(format: "** unrecognized toolbarStyle (%tu)", toolbar.toolbarStyleValue.rawValue) as NSString)
        }
    }
    return 1
}

/// hs.webview.toolbar:modifyItem(table) -> toolbarObject
/// Method
/// Modify the toolbar item specified by the "id" key in the table argument.
///
/// Parameters:
///  * a table containing an "id" key and the attributes to change for the toolbar item.
///
/// Returns:
///  * the toolbarObject
///
/// Notes:
///  * You cannot change a toolbar item's `id`
///  * For a list of the possible toolbar item attribute keys, see [hs.webview.toolbar:addItems](#addItems).
private func modifyToolbarItem(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TTABLE, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let identifier: String

    if lua_getfield(L, 2, "id") == LUA_TSTRING {
        identifier = skin.toNSObject(atIndex: -1) as! String
        if toolbar.itemDefDictionary[identifier] == nil {
            return luaL_error(L, "toolbar item %s does not exist", identifier)
        }
        if builtinToolbarItems.contains(identifier) {
            return luaL_error(L, "cannot modify a built-in toolbar item definition")
        }
    } else {
        return luaL_error(L, "id must be present, and it must be a string")
    }
    lua_pop(L, 1)

    // not stored in itemDefinition, so handle specially
    if lua_getfield(L, 2, "selectable") == LUA_TBOOLEAN {
        if lua_toboolean(L, -1) != 0 {
            toolbar.selectableIdentifiers.add(identifier)
        } else {
            if toolbar.selectedItemIdentifier?.rawValue == identifier { toolbar.selectedItemIdentifier = nil }
            toolbar.selectableIdentifiers.remove(identifier)
        }
    }
    lua_pop(L, 1)

    if lua_getfield(L, 2, "allowedAlone") == LUA_TBOOLEAN {
        if lua_toboolean(L, -1) != 0 {
            toolbar.allowedIdentifiers.add(identifier)
        } else {
            toolbar.allowedIdentifiers.remove(identifier)
            toolbar.defaultIdentifiers.remove(identifier)
            if let itemIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == identifier }) {
                toolbar.removeItem(at: itemIndex)
            }
        }
    }
    lua_pop(L, 1)

    if lua_getfield(L, 2, "default") == LUA_TBOOLEAN {
        if lua_toboolean(L, -1) != 0 {
            toolbar.defaultIdentifiers.add(identifier)
        } else {
            toolbar.defaultIdentifiers.remove(identifier)
        }
    }
    lua_pop(L, 1)

    let newDict = NSMutableDictionary()
    lua_pushnil(L)
    while lua_next(L, 2) != 0 {
        if lua_type(L, -2) == LUA_TSTRING {
            let keyName = skin.toNSObject(atIndex: -2) as! String
            if !keysToKeepFromDefinitionDictionary.contains(keyName) {
                if lua_type(L, -1) != LUA_TFUNCTION {
                    newDict[keyName] = skin.toNSObject(atIndex: -1)
                } else if keyName == "fn" {
                    lua_pushvalue(L, -1)
                    toolbar.fnRefDictionary[identifier] = NSNumber(value: skin.luaRef(refTable))
                }
            }
        } else {
            return luaL_error(L, "non-string keys not allowed in toolbar item definition %s ", identifier)
        }
        lua_pop(L, 1)
    }

    if newDict.count > 0 {
        var handled = false
        for item in toolbar.items {
            if item.itemIdentifier.rawValue == identifier {
                toolbar.updateToolbarItem(item, withDictionary: newDict, withState: L)
                handled = true
            } else if let group = item as? NSToolbarItemGroup {
                for subItem in group.subitems {
                    if subItem.itemIdentifier.rawValue == identifier {
                        toolbar.updateToolbarItem(subItem, withDictionary: newDict, withState: L)
                        handled = true
                    }
                    if handled { break }
                }
            }
            if handled { break }
        }
        if !handled {
            if lua_getfield(L, 2, "groupMembers") == LUA_TBOOLEAN && lua_toboolean(L, -1) == 0 {
                newDict.removeObject(forKey: "groupMembers")
                (toolbar.itemDefDictionary[identifier] as? NSMutableDictionary)?.removeObject(forKey: "groupMembers")
            }
            lua_pop(L, 1)
            (toolbar.itemDefDictionary[identifier] as? NSMutableDictionary)?.addEntries(from: newDict as! [AnyHashable: Any])
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

// NOTE: wrapped and documented in toolbar.lua
private func addToolbarItems(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TTABLE, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar

    let count = luaL_len(L, 2)
    var index: lua_Integer = 0
    var isGood = true

    while isGood && (index < count) {
        if lua_rawgeti(L, 2, index + 1) == LUA_TTABLE {
            isGood = toolbar.addToolbarDefinition(atIndex: -1, withState: L)
        } else {
            skin.logWarn(String(format: "%s:addItems - not a table at index %lld", USERDATA_TB_TAG, index + 1))
            isGood = false
        }
        lua_pop(L, 1)
        index += 1
    }

    if !isGood {
        return luaL_error(L, "%s:addItems - malformed toolbar items encountered", USERDATA_TB_TAG)
    } else {
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview.toolbar:deleteItem(identifier) -> toolbarObject
/// Method
/// Deletes the toolbar item specified completely from the toolbar, removing it first, if the toolbar item is currently active.
///
/// Parameters:
///  * `identifier` - the toolbar item's identifier
///
/// Returns:
///  * the toolbar object
///
/// Notes:
///  * This method completely removes the toolbar item from the toolbar's definition dictionary, thus removing it from active use in the toolbar as well as removing it from the customization panel, if supported.  If you only want to remove a toolbar item from the active toolbar, consider [hs.webview.toolbar:removeItem](#removeItem).
private func deleteToolbarItem(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let identifier = skin.toNSObject(atIndex: 2) as! String

    if toolbar.itemDefDictionary[identifier] == nil {
        return luaL_error(L, "toolbar item %s does not exist", identifier)
    }

    if let itemIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == identifier }) {
        toolbar.removeItem(at: itemIndex)
    }
    toolbar.itemDefDictionary.removeObject(forKey: identifier)
    toolbar.fnRefDictionary.removeObject(forKey: identifier)
    toolbar.enabledDictionary.removeObject(forKey: identifier)
    toolbar.allowedIdentifiers.remove(identifier)
    toolbar.defaultIdentifiers.remove(identifier)
    toolbar.selectableIdentifiers.remove(identifier)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.toolbar:itemDetails(id) -> table
/// Method
/// Returns a table containing details about the specified toolbar item
///
/// Parameters:
///  * id - a string identifier specifying the toolbar item
///
/// Returns:
///  * a table containing the toolbar item definition
///
/// Notes:
///  * For a list of the most of the possible toolbar item attribute keys, see [hs.webview.toolbar:addItems](#addItems).
///  * The table will also include `privateCallback` which will be a boolean indicating whether or not this toolbar item has a private callback function assigned (true) or uses the toolbar's general callback function (false).
///  * The returned table may also contain the following keys, if the item is currently assigned to a toolbar:
///    * `toolbar`  - the toolbar object the item belongs to
///    * `subItems` - if the toolbar item is actually a group, this will contain a table with basic information about the members of the group.  If you wish to get the full details for each sub-member, you may iterate on the identifiers provided in `groupMembers`.
private func detailsForItemIdentifier(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let identifier = skin.toNSObject(atIndex: 2) as! String

    if toolbar.itemDefDictionary[identifier] == nil {
        return luaL_error(L, "toolbar item %s does not exist", identifier)
    }

    var ourItem: NSToolbarItem?
    for item in toolbar.items {
        if identifier == item.itemIdentifier.rawValue {
            ourItem = item
            break
        } else if let group = item as? NSToolbarItemGroup {
            for subItem in group.subitems {
                if identifier == subItem.itemIdentifier.rawValue {
                    ourItem = subItem
                    break
                }
            }
            if ourItem != nil { break }
        }
    }
    if ourItem == nil { ourItem = toolbar.itemDefDictionary[identifier] as? NSToolbarItem }
    skin.pushNSObject(ourItem)
    lua_pushboolean(L, toolbar.selectableIdentifiers.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "selectable")
    lua_pushboolean(L, toolbar.defaultIdentifiers.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "default")
    lua_pushboolean(L, toolbar.allowedIdentifiers.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "allowedAlone")
    let fnRef = toolbar.fnRefDictionary[identifier] as? NSNumber
    lua_pushboolean(L, (fnRef != nil && fnRef!.int32Value != LUA_NOREF) ? 1 : 0)
    lua_setfield(L, -2, "privateCallback")
    if ourItem is NSToolbarItem {
        skin.pushNSObject((toolbar.itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedMenuTitle"] as? NSObject)
        lua_setfield(L, -2, "searchPredefinedMenuTitle")
        skin.pushNSObject((toolbar.itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedSearches"] as? NSObject)
        lua_setfield(L, -2, "searchPredefinedSearches")
        skin.pushNSObject((toolbar.itemDefDictionary[identifier] as? NSDictionary)?["groupMembers"] as? NSObject)
        lua_setfield(L, -2, "groupMembers")
    }
    return 1
}

/// hs.webview.toolbar:allowedItems() -> array
/// Method
/// Returns an array of all toolbar item identifiers defined for this toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table as an array of all toolbar item identifiers defined for this toolbar.  See also [hs.webview.toolbar:items](#items) and [hs.webview.toolbar:visibleItems](#visibleItems).
private func allowedToolbarItems(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    skin.pushNSObject(toolbar.allowedIdentifiers.array as NSArray)
    return 1
}

/// hs.webview.toolbar:items() -> array
/// Method
/// Returns an array of the toolbar item identifiers currently assigned to the toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table as an array of the currently active (assigned) toolbar item identifiers.  Toolbar items which are in the overflow menu *are* included in this array.  See also [hs.webview.toolbar:visibleItems](#visibleItems) and [hs.webview.toolbar:allowedItems](#allowedItems).
private func toolbarItems(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    skin.pushNSObject(toolbar.items.map { $0.itemIdentifier.rawValue } as NSArray)
    return 1
}

/// hs.webview.toolbar:visibleItems() -> array
/// Method
/// Returns an array of the currently visible toolbar item identifiers.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table as an array of the currently visible toolbar item identifiers.  Toolbar items which are in the overflow menu are *not* included in this array.  See also [hs.webview.toolbar:items](#items) and [hs.webview.toolbar:allowedItems](#allowedItems).
private func visibleToolbarItems(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    skin.pushNSObject((toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue } as NSArray)
    return 1
}

/// hs.webview.toolbar:selectedItem([item]) -> toolbarObject | item
/// Method
/// Get or set the selected toolbar item
///
/// Parameters:
///  * item - an optional id for the toolbar item to show as selected, or an explicit nil if you wish for no toolbar item to be selected.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * Only toolbar items which were defined as `selectable` when created with [hs.webview.toolbar.new](#new) can be selected with this method.
private func selectedToolbarItem(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if lua_gettop(L) == 2 {
        var identifier: String?
        if lua_type(L, 2) == LUA_TSTRING {
            identifier = skin.toNSObject(atIndex: 2) as? String
            if let identifier = identifier, toolbar.itemDefDictionary[identifier] == nil {
                return luaL_error(L, "toolbar item %s does not exist", identifier)
            }
        }
        toolbar.selectedItemIdentifier = identifier.map { NSToolbarItem.Identifier($0) }
        lua_pushvalue(L, 1)
    } else {
        if let selected = toolbar.selectedItemIdentifier {
            skin.pushNSObject(selected.rawValue as NSString)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.webview.toolbar:selectSearchField([identifier]) -> toolbarObject | false
/// Method
/// Programmatically focus the search field for keyboard input.
///
/// Parameters:
///  * identifier - an optional string specifying the id of the specific search field to focus.  If this parameter is not provided, this method attempts to focus the first active searchfield found in the toolbar
///
/// Returns:
///  * if the searchfield can be found and is currently in the toolbar, returns the toolbarObject; otherwise returns false.
///
/// Notes:
///  * if there is current text in the searchfield, it will be selected so that any subsequent typing by the user will replace the current value in the searchfield.
private func toolbar_selectSearchField(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    let targetID: String? = (lua_gettop(L) == 2) ? (skin.toNSObject(atIndex: 2) as? String) : nil
    var targetItem: NSToolbarItem?
    for item in (toolbar.visibleItems ?? []) {
        if let targetID = targetID, targetID != item.itemIdentifier.rawValue { continue }
        if item.view is HSToolbarSearchField {
            targetItem = item
            break
        }
    }
    if let targetItem = targetItem {
        (targetItem.view as? HSToolbarSearchField)?.selectText(nil)
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.webview.toolbar:identifier() -> identifier
/// Method
/// The identifier for this toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The identifier for this toolbar.
private func toolbarIdentifier(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    skin.pushNSObject(toolbar.identifier.rawValue as NSString)
    return 1
}

/// hs.webview.toolbar:customizePanel() -> toolbarObject
/// Method
/// Opens the toolbar customization panel.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the toolbar object
private func customizeToolbar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    toolbar.runCustomizationPalette(toolbar)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.toolbar:isCustomizing() -> bool
/// Method
/// Indicates whether or not the customization panel is currently open for the toolbar.
///
/// Parameters:
///  * None
///
/// Returns:
///  * true or false indicating whether or not the customization panel is open for the toolbar
private func toolbarIsCustomizing(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    lua_pushboolean(L, toolbar.customizationPaletteIsRunning ? 1 : 0)
    return 1
}

/// hs.webview.toolbar:canCustomize([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the user is allowed to customize the toolbar with the Customization Panel.
///
/// Parameters:
///  * an optional boolean value indicating whether or not the user is allowed to customize the toolbar.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * the customization panel can be pulled up by right-clicking on the toolbar or by invoking [hs.webview.toolbar:customizePanel](#customizePanel).
private func toolbarCanCustomize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, toolbar.allowsUserCustomization ? 1 : 0)
    } else {
        toolbar.allowsUserCustomization = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview.toolbar:autosaves([bool]) -> toolbarObject | bool
/// Method
/// Get or set whether or not the toolbar autosaves changes made to the toolbar.
///
/// Parameters:
///  * an optional boolean value indicating whether or not changes made to the visible toolbar items or their order is automatically saved.
///
/// Returns:
///  * if an argument is provided, returns the toolbar object; otherwise returns the current value
///
/// Notes:
///  * If the toolbar is set to autosave, then a user-defaults entry is created in org.hammerspoon.Hammerspoon domain with the key "NSToolbar Configuration XXX" where XXX is the toolbar identifier specified when the toolbar was created.
///  * The information saved for the toolbar consists of the following:
///    * the default item identifiers that are displayed when the toolbar is first created or when the user drags the default set from the customization panel.
///    * the current display mode (icon, text, both)
///    * the current size mode (regular, small)
///    * whether or not the toolbar is currently visible
///    * the currently shown identifiers and their order
/// * Note that the labels, icons, callback functions, etc. are not saved -- these are determined at toolbar creation time, by the [hs.webview.toolbar:addItems](#addItems), or by the [hs.webview.toolbar:modifyItem](#modifyItem) method and can differ between invocations of toolbars with the same identifier and button identifiers.
private func toolbarCanAutosave(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(atIndex: 1) as! HSToolbar
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, toolbar.autosavesConfiguration ? 1 : 0)
    } else {
        toolbar.autosavesConfiguration = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

// MARK: - Module Constants

/// hs.webview.toolbar.systemToolbarItems
/// Constant
/// An array containing string identifiers for supported system defined toolbar items.
///
/// Currently supported identifiers include:
///  * NSToolbarSpaceItem         - represents a space approximately the size of a toolbar item
///  * NSToolbarFlexibleSpaceItem - represents a space that stretches to fill available space in the toolbar
private func systemToolbarItems(_ L: OpaquePointer!) -> Int32 {
    LuaSkin.shared(withState: L)!.pushNSObject(automaticallyIncluded as NSArray)
    return 1
}

/// hs.webview.toolbar.itemPriorities
/// Constant
/// A table containing some pre-defined toolbar item priority values for use when determining item order in the toolbar.
///
/// Defined keys are:
///  * standard - the default priority for an item which does not set or change its priority
///  * low      - a low priority value
///  * high     - a high priority value
///  * user     - the priority of an item which the user has added or moved with the customization panel
private func toolbarItemPriorities(_ L: OpaquePointer!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NSToolbarItem.VisibilityPriority.standard.rawValue))
    lua_setfield(L, -2, "standard")
    lua_pushinteger(L, lua_Integer(NSToolbarItem.VisibilityPriority.low.rawValue))
    lua_setfield(L, -2, "low")
    lua_pushinteger(L, lua_Integer(NSToolbarItem.VisibilityPriority.high.rawValue))
    lua_setfield(L, -2, "high")
    lua_pushinteger(L, lua_Integer(NSToolbarItem.VisibilityPriority.user.rawValue))
    lua_setfield(L, -2, "user")
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSToolbar(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let value = obj as! HSToolbar
    if value.selfRef == LUA_NOREF {
        let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
        luaL_getmetatable(L, USERDATA_TB_TAG)
        lua_setmetatable(L, -2)
        value.selfRef = skin.luaRef(refTable)
        identifiersInUse.add(value.identifier.rawValue)
    }

    skin.pushLuaRef(refTable, ref: value.selfRef)
    return 1
}

private func toHSToolbarFromLua(_ L: OpaquePointer!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.shared(withState: L)!
    if luaL_testudata(L, idx, USERDATA_TB_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TB_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        let value = Unmanaged<HSToolbar>.fromOpaque(ptr.pointee!).takeUnretainedValue()
        // since this function is called every time a toolbar function/method is called, we
        // can keep the window reference valid by checking here...
        _ = value.isAttachedToWindow()
        return value
    } else {
        skin.logError(String(format: "expected %s object, found %s",
                             USERDATA_TB_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

private func pushNSToolbarItem(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let value = obj as! NSToolbarItem
    lua_newtable(L)
    skin.pushNSObject(value.itemIdentifier.rawValue as NSString)
    lua_setfield(L, -2, "id")
    skin.pushNSObject(value.label as NSString)
    lua_setfield(L, -2, "label")
    skin.pushNSObject(value.toolTip as NSString?)
    lua_setfield(L, -2, "tooltip")
    skin.pushNSObject(value.image)
    lua_setfield(L, -2, "image")
    lua_pushinteger(L, lua_Integer(value.visibilityPriority.rawValue))
    lua_setfield(L, -2, "priority")
    lua_pushboolean(L, value.isEnabled ? 1 : 0)
    lua_setfield(L, -2, "enable")
    lua_pushinteger(L, lua_Integer(value.tag))
    lua_setfield(L, -2, "tag")

    if let group = obj as? NSToolbarItemGroup {
        skin.pushNSObject(group.subitems as NSArray)
        lua_setfield(L, -2, "subitems")
    }

    if value.toolbar is HSToolbar {
        skin.pushNSObject(value.toolbar!)
        lua_setfield(L, -2, "toolbar")

        if let searchField = value.view as? HSToolbarSearchField {
            lua_pushnumber(L, lua_Number(value.maxSize.width))
            lua_setfield(L, -2, "searchWidth")
            skin.pushNSObject(searchField.stringValue as NSString)
            lua_setfield(L, -2, "searchText")
            lua_pushboolean(L, searchField.releaseOnCallback ? 1 : 0)
            lua_setfield(L, -2, "searchReleaseFocusOnCallback")
            lua_pushinteger(L, lua_Integer((searchField.cell as? NSSearchFieldCell)?.maximumRecents ?? 0))
            lua_setfield(L, -2, "searchHistoryLimit")
            skin.pushNSObject(((searchField.cell as? NSSearchFieldCell)?.recentSearches ?? []) as NSArray)
            lua_setfield(L, -2, "searchHistory")
            skin.pushNSObject(((searchField.cell as? NSSearchFieldCell)?.recentsAutosaveName?.rawValue ?? "") as NSString)
            lua_setfield(L, -2, "searchHistoryAutosaveName")
        }
    }
    return 1
}

// MARK: - Hammerspoon/Lua Infrastructure

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let obj = skin.luaObject(atIndex: 1, toClass: "HSToolbar") as! HSToolbar
    let title = obj.identifier.rawValue
    skin.pushNSObject(String(format: "%s: %@ (%p)", USERDATA_TB_TAG, title as NSString, lua_topointer(L, 1)!) as NSString)
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TB_TAG) != nil && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)!
        let obj1 = skin.luaObject(atIndex: 1, toClass: "HSToolbar") as? HSToolbar
        let obj2 = skin.luaObject(atIndex: 2, toClass: "HSToolbar") as? HSToolbar
        lua_pushboolean(L, (obj1 != nil && obj2 != nil && obj1!.isEqual(obj2!)) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.webview.toolbar:delete() -> none
/// Method
/// Deletes the toolbar, removing it from its window if it is currently attached.
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let ptr = luaL_checkudata(L, 1, USERDATA_TB_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)

    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<HSToolbar>.fromOpaque(rawPtr).takeRetainedValue()

        for (_, fnRef) in obj.fnRefDictionary {
            if let num = fnRef as? NSNumber {
                skin.luaUnref(refTable, ref: num.int32Value)
            }
        }

        let ourWindow = obj.windowUsingToolbar
        if let ourWindow = ourWindow, ourWindow.toolbar?.isEqual(obj) == true {
            ourWindow.toolbar = nil
        }

        obj.callbackRef = skin.luaUnref(refTable, ref: obj.callbackRef)
        obj.selfRef = skin.luaUnref(refTable, ref: obj.selfRef)
        obj.delegate = nil

        let identifierIndex = identifiersInUse.index(of: obj.identifier.rawValue)
        if identifierIndex != NSNotFound {
            identifiersInUse.removeObject(at: identifierIndex)
        }

        ptr.pointee = nil
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    identifiersInUse?.removeAllObjects()
    identifiersInUse = nil
    return 0
}

// MARK: - luaL_Reg tables

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_addItems"), func: addToolbarItems),
    luaL_Reg(name: strdup("_removeItemAtIndex"), func: removeItemAtIndex),
    luaL_Reg(name: strdup("deleteItem"), func: deleteToolbarItem),
    luaL_Reg(name: strdup("delete"), func: userdata_gc),
    luaL_Reg(name: strdup("copyToolbar"), func: copyToolbar),
    luaL_Reg(name: strdup("isAttached"), func: isAttachedToWindow),
    luaL_Reg(name: strdup("savedSettings"), func: configurationDictionary),
    luaL_Reg(name: strdup("inTitleBar"), func: toolbar_inTitleBar),

    luaL_Reg(name: strdup("identifier"), func: toolbarIdentifier),
    luaL_Reg(name: strdup("setCallback"), func: setCallback),
    luaL_Reg(name: strdup("displayMode"), func: displayMode),
    luaL_Reg(name: strdup("toolbarStyle"), func: toolbarStyle),
    luaL_Reg(name: strdup("sizeMode"), func: sizeMode),
    luaL_Reg(name: strdup("visible"), func: visible),
    luaL_Reg(name: strdup("autosaves"), func: toolbarCanAutosave),
    luaL_Reg(name: strdup("separator"), func: showsBaselineSeparator),

    luaL_Reg(name: strdup("modifyItem"), func: modifyToolbarItem),
    luaL_Reg(name: strdup("insertItem"), func: insertItemAtIndex),
    luaL_Reg(name: strdup("selectSearchField"), func: toolbar_selectSearchField),

    luaL_Reg(name: strdup("items"), func: toolbarItems),
    luaL_Reg(name: strdup("visibleItems"), func: visibleToolbarItems),
    luaL_Reg(name: strdup("selectedItem"), func: selectedToolbarItem),
    luaL_Reg(name: strdup("allowedItems"), func: allowedToolbarItems),
    luaL_Reg(name: strdup("itemDetails"), func: detailsForItemIdentifier),

    luaL_Reg(name: strdup("notifyOnChange"), func: notifyWhenToolbarChanges),
    luaL_Reg(name: strdup("customizePanel"), func: customizeToolbar),
    luaL_Reg(name: strdup("isCustomizing"), func: toolbarIsCustomizing),
    luaL_Reg(name: strdup("canCustomize"), func: toolbarCanCustomize),

    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: newHSToolbar),
    luaL_Reg(name: strdup("attachToolbar"), func: attachToolbar),
    luaL_Reg(name: strdup("uniqueName"), func: uniqueName),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwebviewtoolbar")
public func luaopen_hs_libwebviewtoolbar(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary(withObject: USERDATA_TB_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    // see comment at top re @encode
    boolEncodingType = (NSNumber(value: true) as NSNumber).objCType

    builtinToolbarItems = [
        NSToolbarItem.Identifier.space.rawValue,
        NSToolbarItem.Identifier.flexibleSpace.rawValue,
        NSToolbarItem.Identifier.showColors.rawValue,
        NSToolbarItem.Identifier.showFonts.rawValue,
        NSToolbarItem.Identifier.print.rawValue,
        "NSToolbarSeparatorItem",      // deprecated
        "NSToolbarCustomizeToolbarItem", // deprecated
    ]
    automaticallyIncluded = [
        NSToolbarItem.Identifier.space.rawValue,
        NSToolbarItem.Identifier.flexibleSpace.rawValue,
    ]

    keysToKeepFromDefinitionDictionary = ["id", "default", "selectable", "allowedAlone"]

    identifiersInUse = NSMutableArray()

    systemToolbarItems(L)
    lua_setfield(L, -2, "systemToolbarItems")
    toolbarItemPriorities(L)
    lua_setfield(L, -2, "itemPriorities")

    skin.registerPushNSHelper(pushHSToolbar, forClass: "HSToolbar")
    skin.registerLuaObjectHelper(toHSToolbarFromLua, forClass: "HSToolbar",
                                 withUserdataMapping: USERDATA_TB_TAG)
    skin.registerPushNSHelper(pushNSToolbarItem, forClass: "NSToolbarItem")

    return 1
}
