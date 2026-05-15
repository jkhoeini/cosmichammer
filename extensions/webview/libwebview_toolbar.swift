import Cocoa
import LuaSkin

private let USERDATA_TB_TAG = "hs.webview.toolbar"
private var refTable: Int32 = LUA_NOREF
private var identifiersInUse = NSMutableArray()
private var boolEncodingType: UnsafePointer<CChar>!
private var builtinToolbarItems: [String] = []
private var automaticallyIncluded: [String] = []
private var keysToKeepFromDefinitionDictionary: [String] = []

// MARK: - Helper: get toolbar from userdata

private func getToolbar(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSToolbar {
    let ptr = luaL_checkudata(L, idx, USERDATA_TB_TAG)!
    return Unmanaged<HSToolbar>.fromOpaque(
        ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()
}

// MARK: - Helper: get window from other userdata types

private func getWindowFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: String) -> NSWindow? {
    guard let ptr = luaL_checkudata(L, idx, tag) else { return nil }
    let raw = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    return Unmanaged<NSWindow>.fromOpaque(raw).takeUnretainedValue()
}

private func getWindowControllerFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: String) -> NSWindowController? {
    guard let ptr = luaL_checkudata(L, idx, tag) else { return nil }
    let raw = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    return Unmanaged<NSWindowController>.fromOpaque(raw).takeUnretainedValue()
}

// MARK: - Helper: get console window via MJConsoleWindowController

private func consoleWindow() -> NSWindow? {
    guard let cls = NSClassFromString("MJConsoleWindowController") as? NSObject.Type else { return nil }
    let singleton = (cls as AnyObject).perform(Selector(("singleton")))?.takeUnretainedValue() as? NSWindowController
    return singleton?.window
}

// MARK: - Search field menu

private func createCoreSearchFieldMenu() -> NSMenu {
    let searchMenu = NSMenu(title: "Search Menu")
    searchMenu.autoenablesItems = true

    let recentsTitleItem = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
    recentsTitleItem.tag = Int(NSSearchField.recentsTitleMenuItemTag)
    searchMenu.insertItem(recentsTitleItem, at: 0)

    let norecentsTitleItem = NSMenuItem(title: "No recent searches", action: nil, keyEquivalent: "")
    norecentsTitleItem.tag = Int(NSSearchField.noRecentsMenuItemTag)
    searchMenu.insertItem(norecentsTitleItem, at: 1)

    let recentsItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
    recentsItem.tag = Int(NSSearchField.recentsMenuItemTag)
    searchMenu.insertItem(recentsItem, at: 2)

    searchMenu.insertItem(.separator(), at: 3)

    let clearItem = NSMenuItem(title: "Clear", action: nil, keyEquivalent: "")
    clearItem.tag = Int(NSSearchField.clearRecentsMenuItemTag)
    searchMenu.insertItem(clearItem, at: 4)

    return searchMenu
}

// MARK: - Helper: check if value is boolean-typed NSNumber

private func isBoolNumber(_ value: Any?) -> Bool {
    guard let num = value as? NSNumber else { return false }
    return strcmp(boolEncodingType, num.objCType) == 0
}

// MARK: - HSToolbarSearchField

@objc class HSToolbarSearchField: NSSearchField {
    @objc weak var toolbarItem: NSToolbarItem?
    @objc var releaseOnCallback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
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

@objc class HSToolbar: NSToolbar, NSToolbarDelegate {
    @objc var selfRef: Int32 = LUA_NOREF
    @objc var callbackRef: Int32 = LUA_NOREF
    @objc var notifyToolbarChanges = false
    @objc var toolbarStyle_: NSInteger = NSWindow.ToolbarStyle.automatic.rawValue
    @objc weak var windowUsingToolbar: NSWindow?
    @objc let allowedIdentifiers_ = NSMutableOrderedSet()
    @objc let defaultIdentifiers = NSMutableOrderedSet()
    @objc let selectableIdentifiers_ = NSMutableOrderedSet()
    @objc let itemDefDictionary = NSMutableDictionary()
    @objc let fnRefDictionary = NSMutableDictionary()
    @objc let enabledDictionary = NSMutableDictionary()

    @objc init?(identifier: String, itemTableIndex idx: Int32, state L: UnsafeMutablePointer<lua_State>!) {
        super.init(identifier: NSToolbar.Identifier(identifier))
        allowedIdentifiers_.addObjects(from: automaticallyIncluded)
        toolbarStyle_ = NSWindow.ToolbarStyle.automatic.rawValue
        callbackRef = LUA_NOREF
        selfRef = LUA_NOREF
        windowUsingToolbar = nil
        notifyToolbarChanges = false

        if idx != LUA_NOREF {
            let skin = LuaSkin.skin(with: L)
            let count = luaL_len(L, idx)
            var index: lua_Integer = 0
            var isGood = true

            let absIdx = lua_absindex(L, idx)
            while isGood && index < count {
                if lua_rawgeti(L, absIdx, index + 1) == LUA_TTABLE {
                    isGood = addToolbarDefinition(at: -1, state: L)
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):not a table at index \(index + 1) in toolbar \(identifier)")
                    isGood = false
                }
                lua_pop(L, 1)
                index += 1
            }

            if !isGood {
                skin.logError("\(USERDATA_TB_TAG):malformed toolbar items encountered")
                return nil
            }
        }

        allowsUserCustomization = false
        if responds(to: Selector(("setAllowsExtensionItems:"))) {
            setValue(false, forKey: "allowsExtensionItems")
        }
        autosavesConfiguration = false
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc init?(copy original: HSToolbar, state L: UnsafeMutablePointer<lua_State>!) {
        let skin = LuaSkin.skin(with: L)
        super.init(identifier: original.identifier)
        selfRef = LUA_NOREF
        callbackRef = LUA_NOREF
        if original.callbackRef != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: original.callbackRef)
            callbackRef = skin.luaRef(refTable)
        }
        for obj in original.allowedIdentifiers_ { allowedIdentifiers_.add(obj) }
        for obj in original.defaultIdentifiers { defaultIdentifiers.add(obj) }
        for obj in original.selectableIdentifiers_ { selectableIdentifiers_.add(obj) }
        notifyToolbarChanges = original.notifyToolbarChanges
        windowUsingToolbar = nil
        toolbarStyle_ = original.toolbarStyle_

        allowsUserCustomization = original.allowsUserCustomization
        if responds(to: Selector(("setAllowsExtensionItems:"))) {
            setValue(original.value(forKey: "allowsExtensionItems"), forKey: "allowsExtensionItems")
        }
        autosavesConfiguration = original.autosavesConfiguration

        for (k, v) in original.itemDefDictionary { itemDefDictionary[k] = v }
        let copiedEnabled = NSDictionary(dictionary: original.enabledDictionary as! [AnyHashable: Any], copyItems: true)
        for (k, v) in copiedEnabled { enabledDictionary[k] = v }

        for (key, value) in original.fnRefDictionary {
            guard let key = key as? String, let numVal = value as? NSNumber else { continue }
            var theRef = numVal.int32Value
            if theRef != LUA_NOREF {
                skin.pushLuaRef(refTable, ref: theRef)
                theRef = skin.luaRef(refTable)
            }
            fnRefDictionary[key] = NSNumber(value: theRef)
        }

        delegate = self
    }

    @objc func performCallback(_ sender: Any) {
        var searchText: String? = nil
        var item: NSToolbarItem? = nil
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
            LuaSkin.skin(with: nil).logError("\(USERDATA_TB_TAG):Unknown object sent to callback:\(sender)")
            return
        }

        let theFnRef = fnRefDictionary[item?.itemIdentifier.rawValue ?? ""] as? NSNumber
        let itemFnRef = theFnRef?.int32Value ?? LUA_NOREF
        let fnRef = (itemFnRef != LUA_NOREF) ? itemFnRef : callbackRef
        if fnRef != LUA_NOREF {
            let capturedSelf = self
            DispatchQueue.main.async { [weak self] in
                guard fnRef != LUA_NOREF else { return }
                let skin = LuaSkin.skin(with: nil)
                let L = skin.l!
                skin.pushLuaRef(refTable, ref: fnRef)
                skin.pushNSObject(capturedSelf)
                if let ourWindow = self?.windowUsingToolbar {
                    if ourWindow == consoleWindow() {
                        lua_pushstring(L, "console")
                    } else if ourWindow.windowController != nil {
                        skin.pushNSObject(ourWindow.windowController, withOptions: UInt(LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue))
                    } else {
                        skin.pushNSObject(ourWindow, withOptions: UInt(LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue))
                    }
                } else {
                    lua_pushstring(L, "** no window attached")
                }
                skin.pushNSObject(item?.itemIdentifier.rawValue)
                if argCount == 4 { skin.pushNSObject(searchText) }
                skin.protectedCallAndError("hs.webview.toolbar item callback (\(item?.itemIdentifier.rawValue ?? "?"))", nargs: argCount, nresults: 0)
            }
        }
    }

    func validateToolbarItem(_ theItem: NSToolbarItem) -> Bool {
        if let val = enabledDictionary[theItem.itemIdentifier.rawValue] as? NSNumber {
            return val.boolValue
        }
        return true
    }

    @objc var isAttached: Bool {
        guard let ourWindow = windowUsingToolbar else { return false }
        let attached = (ourWindow.toolbar as? HSToolbar) === self
        if !attached { windowUsingToolbar = nil }
        return attached
    }

    // MARK: - Definition management

    @objc func addToolbarDefinition(at idx: Int32, state L: UnsafeMutablePointer<lua_State>!) -> Bool {
        let skin = LuaSkin.skin(with: L)
        let absIdx = lua_absindex(L, idx)

        var identifier: String? = nil
        if lua_getfield(L, absIdx, "id") == LUA_TSTRING {
            identifier = skin.toNSObject(at: -1) as? String
        }
        lua_pop(L, 1)

        guard let identifier = identifier else {
            skin.logWarn("\(USERDATA_TB_TAG):id must be present, and it must be a string")
            return false
        }
        if itemDefDictionary[identifier] != nil {
            skin.logWarn("\(USERDATA_TB_TAG):identifier \(identifier) must be unique or a system defined item")
            return false
        }

        let selectable = (lua_getfield(L, absIdx, "selectable") == LUA_TBOOLEAN) ? (lua_toboolean(L, -1) != 0) : false
        let allowedAlone = (lua_getfield(L, absIdx, "allowedAlone") == LUA_TBOOLEAN) ? (lua_toboolean(L, -1) != 0) : true
        let included = (lua_getfield(L, absIdx, "default") == LUA_TBOOLEAN) ? (lua_toboolean(L, -1) != 0) : allowedAlone
        lua_pop(L, 3)

        enabledDictionary[identifier] = NSNumber(value: true)

        if !builtinToolbarItems.contains(identifier) {
            let toolbarItem = NSMutableDictionary()

            lua_pushnil(L)
            while lua_next(L, absIdx) != 0 {
                if lua_type(L, -2) == LUA_TSTRING {
                    let keyName = skin.toNSObject(at: -2) as? String ?? ""
                    if !keysToKeepFromDefinitionDictionary.contains(keyName) {
                        if lua_type(L, -1) != LUA_TFUNCTION {
                            toolbarItem[keyName] = skin.toNSObject(at: -1)
                        } else if keyName == "fn" {
                            lua_pushvalue(L, -1)
                            fnRefDictionary[identifier] = NSNumber(value: skin.luaRef(refTable))
                        }
                    }
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):non-string keys not allowed for toolbar item \(identifier) definition")
                    lua_pop(L, 2)
                    return false
                }
                lua_pop(L, 1)
            }

            if toolbarItem["label"] == nil && toolbarItem["groupMembers"] == nil {
                toolbarItem["label"] = identifier
            }
            if selectable { selectableIdentifiers_.add(identifier) }
            itemDefDictionary[identifier] = toolbarItem
        }

        if !allowedIdentifiers_.contains(identifier) && allowedAlone {
            allowedIdentifiers_.add(identifier)
        }
        if included {
            defaultIdentifiers.add(identifier)
        }

        return true
    }

    @objc func fillinNewToolbarItem(_ item: NSToolbarItem) {
        let skin = LuaSkin.skin(with: nil)
        updateToolbarItem(item, with: itemDefDictionary[item.itemIdentifier.rawValue] as? NSMutableDictionary ?? NSMutableDictionary(), inGroup: false, state: skin.l)
    }

    @objc func updateToolbarItem(_ item: NSToolbarItem, with itemDefinition: NSMutableDictionary, state L: UnsafeMutablePointer<lua_State>!) {
        updateToolbarItem(item, with: itemDefinition, inGroup: false, state: L)
    }

    @objc func updateToolbarItem(_ item: NSToolbarItem, with itemDefinition: NSMutableDictionary, inGroup: Bool, state L: UnsafeMutablePointer<lua_State>!) {
        let skin = LuaSkin.skin(with: L)
        var itemView = item.view as? HSToolbarSearchField
        let identifier = item.itemIdentifier.rawValue

        if itemDefinition.count == 0 {
            if item.label.isEmpty { item.label = identifier }
            return
        }

        // Handle searchfield first
        if let keyValue = itemDefinition["searchfield"] {
            if isBoolNumber(keyValue) {
                if (keyValue as! NSNumber).boolValue {
                    if !(itemView is HSToolbarSearchField) {
                        if itemView == nil {
                            let sf = HSToolbarSearchField()
                            sf.toolbarItem = item
                            sf.target = self
                            sf.action = #selector(performCallback(_:))
                            item.view = sf
                            itemView = sf
                            if !inGroup {
                                item.minSize = sf.frame.size
                                item.maxSize = sf.frame.size
                            }
                        } else {
                            skin.logWarn("\(USERDATA_TB_TAG):view for toolbar item \(identifier) is not our searchfield... cowardly avoiding replacement")
                        }
                    }
                } else {
                    if itemView != nil {
                        if !(itemView is HSToolbarSearchField) {
                            skin.logWarn("\(USERDATA_TB_TAG):view for toolbar item \(identifier) is not our searchfield... cowardly avoiding removal")
                        } else {
                            item.view = nil
                            itemView = nil
                        }
                    }
                }
            } else {
                skin.logWarn("\(USERDATA_TB_TAG):searchfield for \(identifier) must be a boolean")
                itemDefinition.removeObject(forKey: "searchfield")
            }
        }

        // searchPredefinedMenuTitle validation
        if let keyValue = itemDefinition["searchPredefinedMenuTitle"] {
            if keyValue is String || isBoolNumber(keyValue) {
                if itemDefinition !== itemDefDictionary[identifier] as? NSMutableDictionary && itemDefinition["searchPredefinedSearches"] == nil {
                    itemDefinition["searchPredefinedSearches"] = (itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedSearches"]
                }
            } else {
                skin.logWarn("\(USERDATA_TB_TAG):searchPredefinedMenuTitle for \(identifier) must be a string or a boolean")
                itemDefinition.removeObject(forKey: "searchPredefinedMenuTitle")
            }
        }

        for keyName in (itemDefinition.allKeys as? [String]) ?? [] {
            let keyValue = itemDefinition[keyName]!

            if keyName == "enable" {
                if isBoolNumber(keyValue) {
                    enabledDictionary[identifier] = keyValue
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a boolean")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "fn" {
                if let existing = fnRefDictionary[identifier] as? NSNumber, existing.int32Value != LUA_NOREF {
                    skin.luaUnref(refTable, ref: existing.int32Value)
                }
                skin.pushLuaRef(refTable, ref: (keyValue as! NSNumber).int32Value)
                fnRefDictionary[identifier] = NSNumber(value: skin.luaRef(refTable))
            } else if keyName == "label" {
                if let str = keyValue as? String {
                    item.label = str
                    item.paletteLabel = str
                } else if let num = keyValue as? NSNumber, !num.boolValue {
                    if item is NSToolbarItemGroup {
                        item.label = ""
                        item.paletteLabel = ""
                    } else {
                        item.label = ""
                        item.paletteLabel = identifier
                    }
                    itemDefinition.removeObject(forKey: keyName)
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string, or false to clear")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "tooltip" {
                if let str = keyValue as? String {
                    item.toolTip = str
                } else {
                    if let num = keyValue as? NSNumber, !num.boolValue {
                        item.toolTip = nil
                    } else {
                        skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string, or false to clear")
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "priority" {
                if let num = keyValue as? NSNumber {
                    item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: num.intValue)
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an integer")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "tag" {
                if let num = keyValue as? NSNumber {
                    item.tag = num.intValue
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an integer")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "image" {
                if let img = keyValue as? NSImage {
                    item.image = img
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an hs.image object")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "groupMembers" {
                if item is NSToolbarItemGroup && !inGroup {
                    if let members = keyValue as? [String] {
                        let group = item as! NSToolbarItemGroup
                        let oldSubitems = group.subitems
                        var newSubitems = [NSToolbarItem]()
                        var updateViews = [NSToolbarItem]()

                        for memberIdentifier in members {
                            let existingIndex = oldSubitems.firstIndex { $0.itemIdentifier.rawValue == memberIdentifier }
                            let memberItem: NSToolbarItem
                            if let idx = existingIndex {
                                memberItem = oldSubitems[idx]
                            } else {
                                memberItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(memberIdentifier))
                                memberItem.target = self
                                memberItem.action = #selector(performCallback(_:))
                                memberItem.isEnabled = (enabledDictionary[memberIdentifier] as? NSNumber)?.boolValue ?? true
                                updateToolbarItem(memberItem, with: itemDefDictionary[memberIdentifier] as? NSMutableDictionary ?? NSMutableDictionary(), inGroup: true, state: L)
                                if memberItem.view is HSToolbarSearchField {
                                    updateViews.append(memberItem)
                                }
                            }
                            newSubitems.append(memberItem)
                        }

                        group.subitems = newSubitems

                        for tmpItem in updateViews {
                            let tmpItemDictionary = itemDefDictionary[tmpItem.itemIdentifier.rawValue] as? NSDictionary
                            if let searchView = tmpItem.view as? HSToolbarSearchField {
                                var searchFieldFrame = searchView.frame
                                if let w = (tmpItemDictionary?["searchWidth"] as? NSNumber)?.doubleValue {
                                    searchFieldFrame.size.width = CGFloat(w)
                                }
                                tmpItem.minSize = searchFieldFrame.size
                                tmpItem.maxSize = searchFieldFrame.size
                            }
                        }

                        var minSize = NSSize.zero
                        var maxSize = NSSize.zero
                        for tmpItem in group.subitems {
                            minSize.width += tmpItem.minSize.width
                            minSize.height = max(minSize.height, tmpItem.minSize.height)
                            maxSize.width += tmpItem.maxSize.width
                            maxSize.height = max(maxSize.height, tmpItem.maxSize.height)
                        }
                        item.minSize = minSize
                        item.maxSize = maxSize
                    } else {
                        skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an array of strings")
                        itemDefinition.removeObject(forKey: keyName)
                    }
                } else {
                    if inGroup {
                        skin.logWarn("\(USERDATA_TB_TAG):\(identifier) is in a group and cannot contain group members. Remove item from its group first.")
                    } else {
                        skin.logWarn("\(USERDATA_TB_TAG):cannot change currently visible toolbar item \(identifier) type. Remove item from toolbar first.")
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchWidth", itemView is HSToolbarSearchField {
                if let num = keyValue as? NSNumber {
                    if !inGroup {
                        var fieldFrame = itemView!.frame
                        fieldFrame.size.width = CGFloat(num.doubleValue)
                        item.minSize = fieldFrame.size
                        item.maxSize = fieldFrame.size
                    }
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a number")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchReleaseFocusOnCallback", let sf = itemView {
                if isBoolNumber(keyValue) {
                    sf.releaseOnCallback = (keyValue as! NSNumber).boolValue
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a boolean")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchText", itemView is HSToolbarSearchField {
                if let str = keyValue as? String {
                    itemView!.stringValue = str
                } else if let num = keyValue as? NSNumber {
                    itemView!.stringValue = num.stringValue
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchPredefinedSearches", itemView is HSToolbarSearchField {
                if let arr = keyValue as? [String] {
                    let searchMenu = createCoreSearchFieldMenu()
                    let predefinedSearchMenu = NSMenu(title: "Predefined Search Menu")
                    for menuItemText in arr {
                        let newMenuItem = NSMenuItem(title: menuItemText, action: #selector(HSToolbarSearchField.searchCallback(_:)), keyEquivalent: "")
                        newMenuItem.target = itemView
                        predefinedSearchMenu.addItem(newMenuItem)
                    }

                    var menuName: String? = "Predefined Searches"
                    let checkForTitle = itemDefinition["searchPredefinedMenuTitle"] ?? (itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedMenuTitle"]
                    if let check = checkForTitle {
                        if isBoolNumber(check) {
                            if !(check as! NSNumber).boolValue { menuName = nil }
                        } else if let str = check as? String {
                            menuName = str
                        }
                    }

                    if let menuName = menuName {
                        let predefinedSearches = NSMenuItem(title: menuName, action: nil, keyEquivalent: "")
                        predefinedSearches.submenu = predefinedSearchMenu
                        searchMenu.insertItem(predefinedSearches, at: 0)
                        searchMenu.insertItem(.separator(), at: 1)
                        (itemView!.cell as? NSSearchFieldCell)?.searchMenuTemplate = searchMenu
                    } else {
                        (itemView!.cell as? NSSearchFieldCell)?.searchMenuTemplate = predefinedSearchMenu
                    }
                } else {
                    if let num = keyValue as? NSNumber, !num.boolValue {
                        (itemView!.cell as? NSSearchFieldCell)?.searchMenuTemplate = createCoreSearchFieldMenu()
                    } else {
                        skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an array, or false to remove")
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistoryLimit", itemView is HSToolbarSearchField {
                if let num = keyValue as? NSNumber {
                    (itemView!.cell as? NSSearchFieldCell)?.maximumRecents = num.intValue
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an integer")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistory", itemView is HSToolbarSearchField {
                if let arr = keyValue as? [String] {
                    (itemView!.cell as? NSSearchFieldCell)?.recentSearches = arr
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an array of strings")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistoryAutosaveName", itemView is HSToolbarSearchField {
                if let str = keyValue as? String {
                    (itemView!.cell as? NSSearchFieldCell)?.recentsAutosaveName = str
                    _ = (itemView!.cell as? NSSearchFieldCell)?.recentSearches
                } else if let num = keyValue as? NSNumber {
                    (itemView!.cell as? NSSearchFieldCell)?.recentsAutosaveName = num.stringValue
                    _ = (itemView!.cell as? NSSearchFieldCell)?.recentSearches
                } else {
                    skin.logWarn("\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName != "searchfield" && keyName != "searchPredefinedMenuTitle" {
                skin.logVerbose("\(USERDATA_TB_TAG):\(keyName) is not a valid field for \(identifier); ignoring")
                itemDefinition.removeObject(forKey: keyName)
            }
        }

        if (itemDefDictionary[identifier] as AnyObject) !== (itemDefinition as AnyObject) {
            for (k, v) in itemDefinition { (itemDefDictionary[identifier] as? NSMutableDictionary)?[k] = v }
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let identifier = itemIdentifier.rawValue
        guard let itemDefinition = itemDefDictionary[identifier] as? NSDictionary else { return nil }

        let toolbarItem: NSToolbarItem
        if let groupMembers = itemDefinition["groupMembers"] as? [Any] {
            _ = groupMembers
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
        return (allowedIdentifiers_.array as? [String] ?? []).map { NSToolbarItem.Identifier($0) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return (defaultIdentifiers.array as? [String] ?? []).map { NSToolbarItem.Identifier($0) }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return (selectableIdentifiers_.array as? [String] ?? []).map { NSToolbarItem.Identifier($0) }
    }

    private func pushWindowContext(_ skin: LuaSkin, _ L: UnsafeMutablePointer<lua_State>) {
        if let ourWindow = windowUsingToolbar {
            if ourWindow == consoleWindow() {
                lua_pushstring(L, "console")
            } else if ourWindow.windowController != nil {
                skin.pushNSObject(ourWindow.windowController, withOptions: UInt(LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue))
            } else {
                skin.pushNSObject(ourWindow, withOptions: UInt(LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue))
            }
        } else {
            lua_pushstring(L, "** no window attached")
        }
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard notifyToolbarChanges && callbackRef != LUA_NOREF else { return }
        let capturedSelf = self
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.callbackRef != LUA_NOREF else { return }
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            skin.pushLuaRef(refTable, ref: self.callbackRef)
            skin.pushNSObject(capturedSelf)
            self.pushWindowContext(skin, L)
            let itemId = (notification.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier.rawValue ?? ""
            skin.pushNSObject(itemId)
            lua_pushstring(L, "add")
            skin.protectedCallAndError("hs.webview.toolbar toolbar item addition callback (\(itemId))", nargs: 4, nresults: 0)
        }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard notifyToolbarChanges && callbackRef != LUA_NOREF else { return }
        let capturedSelf = self
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.callbackRef != LUA_NOREF else { return }
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            skin.pushLuaRef(refTable, ref: self.callbackRef)
            skin.pushNSObject(capturedSelf)
            self.pushWindowContext(skin, L)
            let itemId = (notification.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier.rawValue ?? ""
            skin.pushNSObject(itemId)
            lua_pushstring(L, "remove")
            skin.protectedCallAndError("hs.webview.toolbar toolbar item removal callback (\(itemId))", nargs: 4, nresults: 0)
        }
    }
}

// MARK: - Module Functions

private func toolbar_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let identifier = skin.toNSObject(at: 1) as! String

    let idx: Int32 = (lua_gettop(L) == 2) ? 2 : LUA_NOREF

    if identifiersInUse.contains(identifier) {
        return luaL_argerror(L, 1, "identifier already in use")
    }

    if let toolbar = HSToolbar(identifier: identifier, itemTableIndex: idx, state: L) {
        skin.pushNSObject(toolbar)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func toolbar_uniqueName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let identifier = skin.toNSObject(at: 1) as! String
    lua_pushboolean(L, !identifiersInUse.contains(identifier) ? 1 : 0)
    return 1
}

private func toolbar_attachToolbar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    var theWindow: NSWindow?
    var newToolbar: HSToolbar?
    var setToolbar = true
    var isChooser = false
    let top = lua_gettop(L)

    if top == 0 {
        theWindow = consoleWindow()
        newToolbar = nil
        setToolbar = false
    } else if top == 1 && lua_type(L, 1) == LUA_TNIL {
        theWindow = consoleWindow()
        newToolbar = nil
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, USERDATA_TB_TAG) != nil {
        theWindow = consoleWindow()
        newToolbar = skin.toNSObject(at: 1) as? HSToolbar
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        setToolbar = false
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil && lua_type(L, 2) == LUA_TNIL {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil && lua_type(L, 2) == LUA_TUSERDATA && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        newToolbar = skin.toNSObject(at: 2) as? HSToolbar
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.chooser") != nil {
        let controller = getWindowControllerFromUserdata(L, 1, "hs.chooser")
        theWindow = controller?.window
        setToolbar = false
        isChooser = true
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.chooser") != nil && lua_type(L, 2) == LUA_TNIL {
        let controller = getWindowControllerFromUserdata(L, 1, "hs.chooser")
        theWindow = controller?.window
        isChooser = true
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.chooser") != nil && lua_type(L, 2) == LUA_TUSERDATA && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        let controller = getWindowControllerFromUserdata(L, 1, "hs.chooser")
        theWindow = controller?.window
        newToolbar = skin.toNSObject(at: 2) as? HSToolbar
        isChooser = true
    } else {
        return luaL_error(L, "\(USERDATA_TB_TAG):attachToolbar requires an optional window target object and an \(USERDATA_TB_TAG) object or nil")
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
        if let new = newToolbar {
            if let existingWindow = new.windowUsingToolbar {
                existingWindow.toolbar = nil
            }
            if isChooser {
                theWindow?.styleMask = [.titled, .nonactivatingPanel]
                theWindow?.isMovable = false
            }
            theWindow?.toolbar = new
            new.windowUsingToolbar = theWindow
            new.isVisible = true
            theWindow?.toolbarStyle = NSWindow.ToolbarStyle(rawValue: Int(new.toolbarStyle_)) ?? .automatic
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

// MARK: - Userdata Methods

private func toolbar_inTitleBar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    let theWindow = toolbar.windowUsingToolbar
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, theWindow?.titleVisibility == .hidden ? 1 : 0)
    } else {
        if let win = theWindow {
            win.titleVisibility = lua_toboolean(L, 2) != 0 ? .hidden : .visible
        } else {
            skin.logWarn("\(USERDATA_TB_TAG):inTitleBar - requires the toolbar to be attached before using")
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

private func toolbar_isAttached(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    lua_pushboolean(L, toolbar.isAttached ? 1 : 0)
    return 1
}

private func toolbar_copy(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let oldToolbar = skin.toNSObject(at: 1) as! HSToolbar
    if let newToolbar = HSToolbar(copy: oldToolbar, state: L) {
        skin.pushNSObject(newToolbar)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func toolbar_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    toolbar.callbackRef = skin.luaUnref(refTable, ref: toolbar.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        toolbar.callbackRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_savedSettings(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    skin.pushNSObject(toolbar.configuration)
    return 1
}

private func toolbar_separator(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) != 1 {
        toolbar.showsBaselineSeparator = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.showsBaselineSeparator ? 1 : 0)
    }
    return 1
}

private func toolbar_visible(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) != 1 {
        toolbar.isVisible = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.isVisible ? 1 : 0)
    }
    return 1
}

private func toolbar_notifyOnChange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) != 1 {
        toolbar.notifyToolbarChanges = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.notifyToolbarChanges ? 1 : 0)
    }
    return 1
}

private func toolbar_insertItem(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING, LS_TNUMBER, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    let identifier = skin.toNSObject(at: 2) as! String
    var index = lua_tointeger(L, 3)

    guard toolbar.itemDefDictionary[identifier] != nil else {
        return luaL_error(L, "toolbar item \(identifier) does not exist")
    }
    guard index >= 1 && index <= Int64(toolbar.items.count + 1) else {
        return luaL_error(L, "index out of bounds")
    }
    guard toolbar.allowedIdentifiers_.contains(identifier) else {
        return luaL_error(L, "\(identifier) is not allowed outside of its group")
    }

    let ids = toolbar.items.map { $0.itemIdentifier.rawValue }
    if let existingIndex = ids.firstIndex(of: identifier) {
        if !toolbar.items[existingIndex].allowsDuplicatesInToolbar {
            toolbar.removeItem(at: existingIndex)
            if index > Int64(toolbar.items.count + 1) { index -= 1 }
        }
    }

    toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(identifier), at: Int(index - 1))
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_removeItem(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TNUMBER, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    let index = luaL_checkinteger(L, 2)
    guard index >= 1 && index <= Int64(toolbar.items.count + 1) else {
        return luaL_error(L, "index out of bounds")
    }
    toolbar.removeItem(at: Int(index - 1))
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_sizeMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) == 2 {
        let size = skin.toNSObject(at: 2) as! String
        switch size {
        case "default": toolbar.sizeMode = .default
        case "regular": toolbar.sizeMode = .regular
        case "small":   toolbar.sizeMode = .small
        default: return luaL_error(L, "invalid sizeMode:\(size)")
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.sizeMode {
        case .default: skin.pushNSObject("default")
        case .regular: skin.pushNSObject("regular")
        case .small:   skin.pushNSObject("small")
        default: skin.pushNSObject("** unrecognized sizeMode (\(toolbar.sizeMode.rawValue))")
        }
    }
    return 1
}

private func toolbar_displayMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) == 2 {
        let mode = skin.toNSObject(at: 2) as! String
        switch mode {
        case "default": toolbar.displayMode = .default
        case "label":   toolbar.displayMode = .labelOnly
        case "icon":    toolbar.displayMode = .iconOnly
        case "both":    toolbar.displayMode = .iconAndLabel
        default: return luaL_error(L, "invalid displayMode:\(mode)")
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.displayMode {
        case .default:      skin.pushNSObject("default")
        case .labelOnly:    skin.pushNSObject("label")
        case .iconOnly:     skin.pushNSObject("icon")
        case .iconAndLabel: skin.pushNSObject("both")
        default: skin.pushNSObject("** unrecognized displayMode (\(toolbar.displayMode.rawValue))")
        }
    }
    return 1
}

private func toolbar_toolbarStyle(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) == 2 {
        let style = skin.toNSObject(at: 2) as! String
        switch style {
        case "automatic":      toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.automatic.rawValue)
        case "expanded":       toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.expanded.rawValue)
        case "preference":     toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.preference.rawValue)
        case "unified":        toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.unified.rawValue)
        case "unifiedCompact": toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.unifiedCompact.rawValue)
        default: return luaL_error(L, "invalid toolbarStyle: '\(style)'")
        }
        if let win = toolbar.windowUsingToolbar {
            win.toolbarStyle = NSWindow.ToolbarStyle(rawValue: Int(toolbar.toolbarStyle_)) ?? .automatic
        }
        lua_pushvalue(L, 1)
    } else {
        let style = NSWindow.ToolbarStyle(rawValue: Int(toolbar.toolbarStyle_)) ?? .automatic
        switch style {
        case .automatic:      skin.pushNSObject("automatic")
        case .expanded:       skin.pushNSObject("expanded")
        case .preference:     skin.pushNSObject("preference")
        case .unified:        skin.pushNSObject("unified")
        case .unifiedCompact: skin.pushNSObject("unifiedCompact")
        default: skin.pushNSObject("** unrecognized toolbarStyle (\(toolbar.toolbarStyle_))")
        }
    }
    return 1
}

private func toolbar_modifyItem(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TTABLE, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar

    guard lua_getfield(L, 2, "id") == LUA_TSTRING else {
        lua_pop(L, 1)
        return luaL_error(L, "id must be present, and it must be a string")
    }
    let identifier = skin.toNSObject(at: -1) as! String
    lua_pop(L, 1)

    guard toolbar.itemDefDictionary[identifier] != nil else {
        return luaL_error(L, "toolbar item \(identifier) does not exist")
    }
    if builtinToolbarItems.contains(identifier) {
        return luaL_error(L, "cannot modify a built-in toolbar item definition")
    }

    if lua_getfield(L, 2, "selectable") == LUA_TBOOLEAN {
        if lua_toboolean(L, -1) != 0 {
            toolbar.selectableIdentifiers_.add(identifier)
        } else {
            if toolbar.selectedItemIdentifier?.rawValue == identifier { toolbar.selectedItemIdentifier = nil }
            toolbar.selectableIdentifiers_.remove(identifier)
        }
    }
    lua_pop(L, 1)

    if lua_getfield(L, 2, "allowedAlone") == LUA_TBOOLEAN {
        if lua_toboolean(L, -1) != 0 {
            toolbar.allowedIdentifiers_.add(identifier)
        } else {
            toolbar.allowedIdentifiers_.remove(identifier)
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
            let keyName = skin.toNSObject(at: -2) as? String ?? ""
            if !keysToKeepFromDefinitionDictionary.contains(keyName) {
                if lua_type(L, -1) != LUA_TFUNCTION {
                    newDict[keyName] = skin.toNSObject(at: -1)
                } else if keyName == "fn" {
                    lua_pushvalue(L, -1)
                    toolbar.fnRefDictionary[identifier] = NSNumber(value: skin.luaRef(refTable))
                }
            }
        } else {
            return luaL_error(L, "non-string keys not allowed in toolbar item definition \(identifier)")
        }
        lua_pop(L, 1)
    }

    if newDict.count > 0 {
        var handled = false
        for item in toolbar.items {
            if item.itemIdentifier.rawValue == identifier {
                toolbar.updateToolbarItem(item, with: newDict, state: L)
                handled = true
                break
            } else if let group = item as? NSToolbarItemGroup {
                for subItem in group.subitems {
                    if subItem.itemIdentifier.rawValue == identifier {
                        toolbar.updateToolbarItem(subItem, with: newDict, state: L)
                        handled = true
                        break
                    }
                }
                if handled { break }
            }
        }
        if !handled {
            if lua_getfield(L, 2, "groupMembers") == LUA_TBOOLEAN && lua_toboolean(L, -1) == 0 {
                newDict.removeObject(forKey: "groupMembers")
                (toolbar.itemDefDictionary[identifier] as? NSMutableDictionary)?.removeObject(forKey: "groupMembers")
            }
            lua_pop(L, 1)
            for (k, v) in newDict { (toolbar.itemDefDictionary[identifier] as? NSMutableDictionary)?[k] = v }
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_addItems(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TTABLE, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar

    let count = luaL_len(L, 2)
    var index: lua_Integer = 0
    var isGood = true

    while isGood && index < count {
        if lua_rawgeti(L, 2, index + 1) == LUA_TTABLE {
            isGood = toolbar.addToolbarDefinition(at: -1, state: L)
        } else {
            skin.logWarn("\(USERDATA_TB_TAG):addItems - not a table at index \(index + 1)")
            isGood = false
        }
        lua_pop(L, 1)
        index += 1
    }

    if !isGood {
        return luaL_error(L, "\(USERDATA_TB_TAG):addItems - malformed toolbar items encountered")
    }
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_deleteItem(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    let identifier = skin.toNSObject(at: 2) as! String

    guard toolbar.itemDefDictionary[identifier] != nil else {
        return luaL_error(L, "toolbar item \(identifier) does not exist")
    }

    if let itemIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == identifier }) {
        toolbar.removeItem(at: itemIndex)
    }
    toolbar.itemDefDictionary.removeObject(forKey: identifier)
    toolbar.fnRefDictionary.removeObject(forKey: identifier)
    toolbar.enabledDictionary.removeObject(forKey: identifier)
    toolbar.allowedIdentifiers_.remove(identifier)
    toolbar.defaultIdentifiers.remove(identifier)
    toolbar.selectableIdentifiers_.remove(identifier)
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_itemDetails(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    let identifier = skin.toNSObject(at: 2) as! String

    guard toolbar.itemDefDictionary[identifier] != nil else {
        return luaL_error(L, "toolbar item \(identifier) does not exist")
    }

    var ourItem: NSToolbarItem?
    for item in toolbar.items {
        if item.itemIdentifier.rawValue == identifier {
            ourItem = item
            break
        } else if let group = item as? NSToolbarItemGroup {
            for subItem in group.subitems where subItem.itemIdentifier.rawValue == identifier {
                ourItem = subItem
                break
            }
            if ourItem != nil { break }
        }
    }
    if ourItem == nil { ourItem = toolbar.itemDefDictionary[identifier] as? NSToolbarItem }
    skin.pushNSObject(ourItem)

    lua_pushboolean(L, toolbar.selectableIdentifiers_.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "selectable")
    lua_pushboolean(L, toolbar.defaultIdentifiers.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "default")
    lua_pushboolean(L, toolbar.allowedIdentifiers_.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "allowedAlone")
    let fnRef = toolbar.fnRefDictionary[identifier] as? NSNumber
    lua_pushboolean(L, (fnRef != nil && fnRef!.int32Value != LUA_NOREF) ? 1 : 0)
    lua_setfield(L, -2, "privateCallback")

    if ourItem is NSToolbarItem {
        skin.pushNSObject((toolbar.itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedMenuTitle"])
        lua_setfield(L, -2, "searchPredefinedMenuTitle")
        skin.pushNSObject((toolbar.itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedSearches"])
        lua_setfield(L, -2, "searchPredefinedSearches")
        skin.pushNSObject((toolbar.itemDefDictionary[identifier] as? NSDictionary)?["groupMembers"])
        lua_setfield(L, -2, "groupMembers")
    }
    return 1
}

private func toolbar_allowedItems(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    skin.pushNSObject(toolbar.allowedIdentifiers_.array)
    return 1
}

private func toolbar_items(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    skin.pushNSObject(toolbar.items.map { $0.itemIdentifier.rawValue })
    return 1
}

private func toolbar_visibleItems(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    skin.pushNSObject(toolbar.visibleItems?.map { $0.itemIdentifier.rawValue })
    return 1
}

private func toolbar_selectedItem(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) == 2 {
        if lua_type(L, 2) == LUA_TSTRING {
            let identifier = skin.toNSObject(at: 2) as! String
            guard toolbar.itemDefDictionary[identifier] != nil else {
                return luaL_error(L, "toolbar item \(identifier) does not exist")
            }
            toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
        } else {
            toolbar.selectedItemIdentifier = nil
        }
        lua_pushvalue(L, 1)
    } else {
        skin.pushNSObject(toolbar.selectedItemIdentifier?.rawValue)
    }
    return 1
}

private func toolbar_selectSearchField(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    let targetID = (lua_gettop(L) == 2) ? (skin.toNSObject(at: 2) as? String) : nil

    var targetItem: NSToolbarItem?
    for item in (toolbar.visibleItems ?? []) {
        if let tid = targetID, tid != item.itemIdentifier.rawValue { continue }
        if item.view is HSToolbarSearchField {
            targetItem = item
            break
        }
    }
    if let item = targetItem {
        (item.view as? HSToolbarSearchField)?.selectText(nil)
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func toolbar_identifier(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    skin.pushNSObject(toolbar.identifier)
    return 1
}

private func toolbar_customizePanel(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    toolbar.runCustomizationPalette(toolbar)
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_isCustomizing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    lua_pushboolean(L, toolbar.customizationPaletteIsRunning ? 1 : 0)
    return 1
}

private func toolbar_canCustomize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, toolbar.allowsUserCustomization ? 1 : 0)
    } else {
        toolbar.allowsUserCustomization = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

private func toolbar_autosaves(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TB_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let toolbar = skin.toNSObject(at: 1) as! HSToolbar
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, toolbar.autosavesConfiguration ? 1 : 0)
    } else {
        toolbar.autosavesConfiguration = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

// MARK: - Constants

private func toolbar_systemItems(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).pushNSObject(automaticallyIncluded)
    return 1
}

private func toolbar_itemPriorities(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

// MARK: - Push/To helpers

private func pushHSToolbar(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let toolbar = obj as? HSToolbar else { lua_pushnil(L); return 1 }
    let skin = LuaSkin.skin(with: L)
    if toolbar.selfRef == LUA_NOREF {
        let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        ptr.pointee = Unmanaged.passRetained(toolbar).toOpaque()
        luaL_getmetatable(L, USERDATA_TB_TAG)
        lua_setmetatable(L, -2)
        toolbar.selfRef = skin.luaRef(refTable)
        identifiersInUse.add(toolbar.identifier)
    }
    skin.pushLuaRef(refTable, ref: toolbar.selfRef)
    return 1
}

private func toHSToolbar(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    guard luaL_testudata(L, idx, USERDATA_TB_TAG) != nil else {
        skin.logError("expected \(USERDATA_TB_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
    let toolbar = getToolbar(L, idx)
    _ = toolbar.isAttached
    return toolbar
}

private func pushNSToolbarItem(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let item = obj as? NSToolbarItem else { lua_pushnil(L); return 1 }
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    skin.pushNSObject(item.itemIdentifier); lua_setfield(L, -2, "id")
    skin.pushNSObject(item.label); lua_setfield(L, -2, "label")
    skin.pushNSObject(item.toolTip); lua_setfield(L, -2, "tooltip")
    skin.pushNSObject(item.image); lua_setfield(L, -2, "image")
    lua_pushinteger(L, lua_Integer(item.visibilityPriority.rawValue)); lua_setfield(L, -2, "priority")
    lua_pushboolean(L, item.isEnabled ? 1 : 0); lua_setfield(L, -2, "enable")
    lua_pushinteger(L, lua_Integer(item.tag)); lua_setfield(L, -2, "tag")

    if let group = item as? NSToolbarItemGroup {
        skin.pushNSObject(group.subitems); lua_setfield(L, -2, "subitems")
    }

    if let toolbar = item.toolbar as? HSToolbar {
        skin.pushNSObject(toolbar); lua_setfield(L, -2, "toolbar")
        if let sf = item.view as? HSToolbarSearchField {
            lua_pushnumber(L, lua_Number(item.maxSize.width)); lua_setfield(L, -2, "searchWidth")
            skin.pushNSObject(sf.stringValue); lua_setfield(L, -2, "searchText")
            lua_pushboolean(L, sf.releaseOnCallback ? 1 : 0); lua_setfield(L, -2, "searchReleaseFocusOnCallback")
            lua_pushinteger(L, lua_Integer((sf.cell as? NSSearchFieldCell)?.maximumRecents ?? 0)); lua_setfield(L, -2, "searchHistoryLimit")
            skin.pushNSObject((sf.cell as? NSSearchFieldCell)?.recentSearches); lua_setfield(L, -2, "searchHistory")
            skin.pushNSObject((sf.cell as? NSSearchFieldCell)?.recentsAutosaveName); lua_setfield(L, -2, "searchHistoryAutosaveName")
        }
    }
    return 1
}

// MARK: - Infrastructure

private func toolbar_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let toolbar = skin.luaObject(at: 1, toClass: "HSToolbar") as! HSToolbar
    let desc = "\(USERDATA_TB_TAG): \(toolbar.identifier) (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, desc)
    return 1
}

private func toolbar_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TB_TAG) != nil && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "HSToolbar") as! HSToolbar
        let obj2 = skin.luaObject(at: 2, toClass: "HSToolbar") as! HSToolbar
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func toolbar_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, USERDATA_TB_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let toolbar = Unmanaged<HSToolbar>.fromOpaque(ptr.pointee).takeRetainedValue()

    for (_, value) in toolbar.fnRefDictionary {
        if let num = value as? NSNumber {
            skin.luaUnref(refTable, ref: num.int32Value)
        }
    }

    if let ourWindow = toolbar.windowUsingToolbar, (ourWindow.toolbar as? HSToolbar) === toolbar {
        ourWindow.toolbar = nil
    }

    toolbar.callbackRef = skin.luaUnref(refTable, ref: toolbar.callbackRef)
    toolbar.selfRef = skin.luaUnref(refTable, ref: toolbar.selfRef)
    toolbar.delegate = nil

    let identifierIndex = identifiersInUse.index(of: toolbar.identifier)
    if identifierIndex != NSNotFound { identifiersInUse.removeObject(at: identifierIndex) }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    identifiersInUse.removeAllObjects()
    return 0
}

// MARK: - Lua registration tables

private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: toolbar_new),
    luaL_Reg(name: strdup("attachToolbar"), func: toolbar_attachToolbar),
    luaL_Reg(name: strdup("uniqueName"), func: toolbar_uniqueName),
    luaL_Reg(name: nil, func: nil),
]

private let userdataLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_addItems"), func: toolbar_addItems),
    luaL_Reg(name: strdup("_removeItemAtIndex"), func: toolbar_removeItem),
    luaL_Reg(name: strdup("deleteItem"), func: toolbar_deleteItem),
    luaL_Reg(name: strdup("delete"), func: toolbar_gc),
    luaL_Reg(name: strdup("copyToolbar"), func: toolbar_copy),
    luaL_Reg(name: strdup("isAttached"), func: toolbar_isAttached),
    luaL_Reg(name: strdup("savedSettings"), func: toolbar_savedSettings),
    luaL_Reg(name: strdup("inTitleBar"), func: toolbar_inTitleBar),
    luaL_Reg(name: strdup("identifier"), func: toolbar_identifier),
    luaL_Reg(name: strdup("setCallback"), func: toolbar_setCallback),
    luaL_Reg(name: strdup("displayMode"), func: toolbar_displayMode),
    luaL_Reg(name: strdup("toolbarStyle"), func: toolbar_toolbarStyle),
    luaL_Reg(name: strdup("sizeMode"), func: toolbar_sizeMode),
    luaL_Reg(name: strdup("visible"), func: toolbar_visible),
    luaL_Reg(name: strdup("autosaves"), func: toolbar_autosaves),
    luaL_Reg(name: strdup("separator"), func: toolbar_separator),
    luaL_Reg(name: strdup("modifyItem"), func: toolbar_modifyItem),
    luaL_Reg(name: strdup("insertItem"), func: toolbar_insertItem),
    luaL_Reg(name: strdup("selectSearchField"), func: toolbar_selectSearchField),
    luaL_Reg(name: strdup("items"), func: toolbar_items),
    luaL_Reg(name: strdup("visibleItems"), func: toolbar_visibleItems),
    luaL_Reg(name: strdup("selectedItem"), func: toolbar_selectedItem),
    luaL_Reg(name: strdup("allowedItems"), func: toolbar_allowedItems),
    luaL_Reg(name: strdup("itemDetails"), func: toolbar_itemDetails),
    luaL_Reg(name: strdup("notifyOnChange"), func: toolbar_notifyOnChange),
    luaL_Reg(name: strdup("customizePanel"), func: toolbar_customizePanel),
    luaL_Reg(name: strdup("isCustomizing"), func: toolbar_isCustomizing),
    luaL_Reg(name: strdup("canCustomize"), func: toolbar_canCustomize),
    luaL_Reg(name: strdup("__tostring"), func: toolbar_tostring),
    luaL_Reg(name: strdup("__eq"), func: toolbar_eq),
    luaL_Reg(name: strdup("__gc"), func: toolbar_gc),
    luaL_Reg(name: nil, func: nil),
]

private let metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Entry point

@_cdecl("luaopen_hs_libwebviewtoolbar")
public func luaopen_hs_libwebviewtoolbar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TB_TAG,
                                    functions: moduleLib,
                                    metaFunctions: metaLib,
                                    objectFunctions: userdataLib)

    boolEncodingType = (true as NSNumber).objCType

    builtinToolbarItems = [
        NSToolbarItem.Identifier.space.rawValue,
        NSToolbarItem.Identifier.flexibleSpace.rawValue,
        NSToolbarItem.Identifier.showColors.rawValue,
        NSToolbarItem.Identifier.showFonts.rawValue,
        NSToolbarItem.Identifier.print.rawValue,
        NSToolbarItem.Identifier.separator.rawValue,
        NSToolbarItem.Identifier.toggleSidebar.rawValue,
    ]
    automaticallyIncluded = [
        NSToolbarItem.Identifier.space.rawValue,
        NSToolbarItem.Identifier.flexibleSpace.rawValue,
    ]
    keysToKeepFromDefinitionDictionary = ["id", "default", "selectable", "allowedAlone"]

    toolbar_systemItems(L); lua_setfield(L, -2, "systemToolbarItems")
    toolbar_itemPriorities(L); lua_setfield(L, -2, "itemPriorities")

    skin.registerPushNSHelper(pushHSToolbar, forClass: "HSToolbar")
    skin.registerLuaObjectHelper(toHSToolbar, forClass: "HSToolbar", withUserdataMapping: USERDATA_TB_TAG)
    skin.registerPushNSHelper(pushNSToolbarItem, forClass: "NSToolbarItem")

    return 1
}
