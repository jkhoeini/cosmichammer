import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TB_TAG = "hs.webview.toolbar"
private var refTable: Int32 = LUA_NOREF
private var identifiersInUse = NSMutableArray()
private var boolEncodingType: UnsafePointer<CChar>!
private var builtinToolbarItems: [String] = []
private var automaticallyIncluded: [String] = []
private var keysToKeepFromDefinitionDictionary: [String] = []

// MARK: - Helper: get toolbar from userdata

func getToolbar(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSToolbar {
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
    let singleton = catchingObjCException {
        (cls as AnyObject).perform(Selector(("singleton")))?.takeUnretainedValue() as? NSWindowController
    }
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
            let count = luaL_len(L, idx)
            var index: lua_Integer = 0
            var isGood = true

            let absIdx = lua_absindex(L, idx)
            while isGood && index < count {
                if lua_rawgeti(L, absIdx, index + 1) == LUA_TTABLE {
                    isGood = addToolbarDefinition(at: -1, state: L)
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):not a table at index \(index + 1) in toolbar \(identifier)")
                    isGood = false
                }
                lua_pop(L, 1)
                index += 1
            }

            if !isGood {
                os_log(.error, "%{public}s", "\(USERDATA_TB_TAG):malformed toolbar items encountered")
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
        super.init(identifier: original.identifier)
        selfRef = LUA_NOREF
        callbackRef = LUA_NOREF
        if original.callbackRef != LUA_NOREF {
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(original.callbackRef))
            callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
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
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(theRef))
                theRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
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
            os_log(.error, "%{public}s","\(USERDATA_TB_TAG):Unknown object sent to callback:\(sender)")
            return
        }

        let theFnRef = fnRefDictionary[item?.itemIdentifier.rawValue ?? ""] as? NSNumber
        let itemFnRef = theFnRef?.int32Value ?? LUA_NOREF
        let fnRef = (itemFnRef != LUA_NOREF) ? itemFnRef : callbackRef
        if fnRef != LUA_NOREF {
            let capturedSelf = self
            DispatchQueue.main.async { [weak self] in
                guard fnRef != LUA_NOREF else { return }
                let L = lua_getCurrentState()!
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fnRef))
                wv_pushAny(L, capturedSelf)
                _ = toolbar_pushWindowContext(L, self?.windowUsingToolbar)
                lua_pushany(L, item?.itemIdentifier.rawValue)
                if argCount == 4 { lua_pushany(L, searchText) }
                if lua_pcall(L, argCount, 0, 0) != LUA_OK { lua_pop(L, 1) }
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
        let absIdx = lua_absindex(L, idx)

        var identifier: String? = nil
        if lua_getfield(L, absIdx, "id") == LUA_TSTRING {
            identifier = lua_tovalue(L, at: -1) as? String
        }
        lua_pop(L, 1)

        guard let identifier = identifier else {
            os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):id must be present, and it must be a string")
            return false
        }
        if itemDefDictionary[identifier] != nil {
            os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):identifier \(identifier) must be unique or a system defined item")
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
                    let keyName = lua_tovalue(L, at: -2) as? String ?? ""
                    if !keysToKeepFromDefinitionDictionary.contains(keyName) {
                        if lua_type(L, -1) != LUA_TFUNCTION {
                            toolbarItem[keyName] = lua_tovalue(L, at: -1)
                        } else if keyName == "fn" {
                            lua_pushvalue(L, -1)
                            fnRefDictionary[identifier] = NSNumber(value: luaL_ref(L, LUA_REGISTRYINDEX_VALUE))
                        }
                    }
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):non-string keys not allowed for toolbar item \(identifier) definition")
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
        let L = lua_getCurrentState()!
        updateToolbarItem(item, with: itemDefDictionary[item.itemIdentifier.rawValue] as? NSMutableDictionary ?? NSMutableDictionary(), inGroup: false, state: L)
    }

    @objc func updateToolbarItem(_ item: NSToolbarItem, with itemDefinition: NSMutableDictionary, state L: UnsafeMutablePointer<lua_State>!) {
        updateToolbarItem(item, with: itemDefinition, inGroup: false, state: L)
    }

    @objc func updateToolbarItem(_ item: NSToolbarItem, with itemDefinition: NSMutableDictionary, inGroup: Bool, state L: UnsafeMutablePointer<lua_State>!) {
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
                    }
                } else {
                    if itemView != nil {
                        item.view = nil
                        itemView = nil
                    }
                }
            } else {
                os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):searchfield for \(identifier) must be a boolean")
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
                os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):searchPredefinedMenuTitle for \(identifier) must be a string or a boolean")
                itemDefinition.removeObject(forKey: "searchPredefinedMenuTitle")
            }
        }

        for keyName in (itemDefinition.allKeys as? [String]) ?? [] {
            let keyValue = itemDefinition[keyName]!

            if keyName == "enable" {
                if isBoolNumber(keyValue) {
                    enabledDictionary[identifier] = keyValue
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a boolean")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "fn" {
                if let existing = fnRefDictionary[identifier] as? NSNumber, existing.int32Value != LUA_NOREF {
                    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, existing.int32Value)
                }
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer((keyValue as! NSNumber).int32Value))
                fnRefDictionary[identifier] = NSNumber(value: luaL_ref(L, LUA_REGISTRYINDEX_VALUE))
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
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string, or false to clear")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "tooltip" {
                if let str = keyValue as? String {
                    item.toolTip = str
                } else {
                    if let num = keyValue as? NSNumber, !num.boolValue {
                        item.toolTip = nil
                    } else {
                        os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string, or false to clear")
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "priority" {
                if let num = keyValue as? NSNumber {
                    item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: num.intValue)
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an integer")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "tag" {
                if let num = keyValue as? NSNumber {
                    item.tag = num.intValue
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an integer")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "image" {
                if let img = keyValue as? NSImage {
                    item.image = img
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an hs.image object")
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
                        os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an array of strings")
                        itemDefinition.removeObject(forKey: keyName)
                    }
                } else {
                    if inGroup {
                        os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(identifier) is in a group and cannot contain group members. Remove item from its group first.")
                    } else {
                        os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):cannot change currently visible toolbar item \(identifier) type. Remove item from toolbar first.")
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchWidth", itemView != nil {
                if let num = keyValue as? NSNumber {
                    if !inGroup {
                        var fieldFrame = itemView!.frame
                        fieldFrame.size.width = CGFloat(num.doubleValue)
                        item.minSize = fieldFrame.size
                        item.maxSize = fieldFrame.size
                    }
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a number")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchReleaseFocusOnCallback", let sf = itemView {
                if isBoolNumber(keyValue) {
                    sf.releaseOnCallback = (keyValue as! NSNumber).boolValue
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a boolean")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchText", itemView != nil {
                if let str = keyValue as? String {
                    itemView!.stringValue = str
                } else if let num = keyValue as? NSNumber {
                    itemView!.stringValue = num.stringValue
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchPredefinedSearches", itemView != nil {
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
                        os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an array, or false to remove")
                    }
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistoryLimit", itemView != nil {
                if let num = keyValue as? NSNumber {
                    (itemView!.cell as? NSSearchFieldCell)?.maximumRecents = num.intValue
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an integer")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistory", itemView != nil {
                if let arr = keyValue as? [String] {
                    (itemView!.cell as? NSSearchFieldCell)?.recentSearches = arr
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be an array of strings")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName == "searchHistoryAutosaveName", itemView != nil {
                if let str = keyValue as? String {
                    (itemView!.cell as? NSSearchFieldCell)?.recentsAutosaveName = str
                    _ = (itemView!.cell as? NSSearchFieldCell)?.recentSearches
                } else if let num = keyValue as? NSNumber {
                    (itemView!.cell as? NSSearchFieldCell)?.recentsAutosaveName = num.stringValue
                    _ = (itemView!.cell as? NSSearchFieldCell)?.recentSearches
                } else {
                    os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) for \(identifier) must be a string")
                    itemDefinition.removeObject(forKey: keyName)
                }
            } else if keyName != "searchfield" && keyName != "searchPredefinedMenuTitle" {
                os_log(.debug, "%{public}s", "\(USERDATA_TB_TAG):\(keyName) is not a valid field for \(identifier); ignoring")
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

    private func pushWindowContext(_ L: UnsafeMutablePointer<lua_State>) {
        _ = toolbar_pushWindowContext(L, windowUsingToolbar)
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard notifyToolbarChanges && callbackRef != LUA_NOREF else { return }
        let capturedSelf = self
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.callbackRef != LUA_NOREF else { return }
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(self.callbackRef))
            wv_pushAny(L, capturedSelf)
            self.pushWindowContext(L)
            let itemId = (notification.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier.rawValue ?? ""
            lua_pushany(L, itemId)
            lua_pushstring(L, "add")
            if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard notifyToolbarChanges && callbackRef != LUA_NOREF else { return }
        let capturedSelf = self
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.callbackRef != LUA_NOREF else { return }
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(self.callbackRef))
            wv_pushAny(L, capturedSelf)
            self.pushWindowContext(L)
            let itemId = (notification.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier.rawValue ?? ""
            lua_pushany(L, itemId)
            lua_pushstring(L, "remove")
            if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - Module Functions

private func toolbar_new(_ L: LuaState) throws -> CInt {
    let identifier = lua_tovalue(L, at: 1) as! String

    let idx: Int32 = (lua_gettop(L) == 2) ? 2 : LUA_NOREF

    if identifiersInUse.contains(identifier) {
        throw LuaCallError("bad argument #1: identifier already in use")
    }

    if let toolbar = HSToolbar(identifier: identifier, itemTableIndex: idx, state: L) {
        wv_pushAny(L, toolbar)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func toolbar_uniqueName(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let identifier = lua_tovalue(L, at: 1) as! String
    lua_pushboolean(L, !identifiersInUse.contains(identifier) ? 1 : 0)
    return 1
}

private func toolbar_attachToolbar(_ L: LuaState) throws -> CInt {
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
        newToolbar = getToolbar(L, 1)
    } else if top == 1 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        setToolbar = false
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil && lua_type(L, 2) == LUA_TNIL {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
    } else if top == 2 && lua_type(L, 1) == LUA_TUSERDATA && luaL_testudata(L, 1, "hs.webview") != nil && lua_type(L, 2) == LUA_TUSERDATA && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        theWindow = getWindowFromUserdata(L, 1, "hs.webview")
        newToolbar = getToolbar(L, 2)
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
        newToolbar = getToolbar(L, 2)
        isChooser = true
    } else {
        throw LuaCallError("\(USERDATA_TB_TAG):attachToolbar requires an optional window target object and an \(USERDATA_TB_TAG) object or nil")
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
            wv_pushAny(L, old)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

// MARK: - Userdata Methods

private func toolbar_inTitleBar(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    let theWindow = toolbar.windowUsingToolbar
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, theWindow?.titleVisibility == .hidden ? 1 : 0)
    } else {
        if let win = theWindow {
            win.titleVisibility = lua_toboolean(L, 2) != 0 ? .hidden : .visible
        } else {
            os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):inTitleBar - requires the toolbar to be attached before using")
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

private func toolbar_isAttached(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushboolean(L, toolbar.isAttached ? 1 : 0)
    return 1
}

private func toolbar_copy(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let oldToolbar = getToolbar(L, 1)
    if let newToolbar = HSToolbar(copy: oldToolbar, state: L) {
        wv_pushAny(L, newToolbar)
    } else {
        lua_pushnil(L)
    }
    return 1
}

private func toolbar_setCallback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, toolbar.callbackRef)

    toolbar.callbackRef = LUA_NOREF
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        toolbar.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_savedSettings(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushany(L, toolbar.configuration)
    return 1
}

private func toolbar_separator(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) != 1 {
        toolbar.showsBaselineSeparator = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.showsBaselineSeparator ? 1 : 0)
    }
    return 1
}

private func toolbar_visible(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) != 1 {
        toolbar.isVisible = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.isVisible ? 1 : 0)
    }
    return 1
}

private func toolbar_notifyOnChange(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) != 1 {
        toolbar.notifyToolbarChanges = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, toolbar.notifyToolbarChanges ? 1 : 0)
    }
    return 1
}

private func toolbar_insertItem(_ L: LuaState) throws -> CInt {
    let toolbar = getToolbar(L, 1)
    let identifier = lua_tovalue(L, at: 2) as! String
    var index = lua_tointeger(L, 3)

    guard toolbar.itemDefDictionary[identifier] != nil else {
        throw LuaCallError("toolbar item \(identifier) does not exist")
    }
    guard index >= 1 && index <= Int64(toolbar.items.count + 1) else {
        throw LuaCallError("index out of bounds")
    }
    guard toolbar.allowedIdentifiers_.contains(identifier) else {
        throw LuaCallError("\(identifier) is not allowed outside of its group")
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

private func toolbar_removeItem(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)
    let toolbar = getToolbar(L, 1)
    let index = luaL_checkinteger(L, 2)
    guard index >= 1 && index <= Int64(toolbar.items.count + 1) else {
        throw LuaCallError("index out of bounds")
    }
    toolbar.removeItem(at: Int(index - 1))
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_sizeMode(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) == 2 {
        let size = lua_tovalue(L, at: 2) as! String
        switch size {
        case "default": toolbar.sizeMode = .default
        case "regular": toolbar.sizeMode = .regular
        case "small":   toolbar.sizeMode = .small
        default: throw LuaCallError("invalid sizeMode:\(size)")
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.sizeMode {
        case .default: lua_pushany(L, "default")
        case .regular: lua_pushany(L, "regular")
        case .small:   lua_pushany(L, "small")
        default: lua_pushany(L, "** unrecognized sizeMode (\(toolbar.sizeMode.rawValue))")
        }
    }
    return 1
}

private func toolbar_displayMode(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) == 2 {
        let mode = lua_tovalue(L, at: 2) as! String
        switch mode {
        case "default": toolbar.displayMode = .default
        case "label":   toolbar.displayMode = .labelOnly
        case "icon":    toolbar.displayMode = .iconOnly
        case "both":    toolbar.displayMode = .iconAndLabel
        default: throw LuaCallError("invalid displayMode:\(mode)")
        }
        lua_pushvalue(L, 1)
    } else {
        switch toolbar.displayMode {
        case .default:      lua_pushany(L, "default")
        case .labelOnly:    lua_pushany(L, "label")
        case .iconOnly:     lua_pushany(L, "icon")
        case .iconAndLabel: lua_pushany(L, "both")
        default: lua_pushany(L, "** unrecognized displayMode (\(toolbar.displayMode.rawValue))")
        }
    }
    return 1
}

private func toolbar_toolbarStyle(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) == 2 {
        let style = lua_tovalue(L, at: 2) as! String
        switch style {
        case "automatic":      toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.automatic.rawValue)
        case "expanded":       toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.expanded.rawValue)
        case "preference":     toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.preference.rawValue)
        case "unified":        toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.unified.rawValue)
        case "unifiedCompact": toolbar.toolbarStyle_ = NSInteger(NSWindow.ToolbarStyle.unifiedCompact.rawValue)
        default: throw LuaCallError("invalid toolbarStyle: '\(style)'")
        }
        if let win = toolbar.windowUsingToolbar {
            win.toolbarStyle = NSWindow.ToolbarStyle(rawValue: Int(toolbar.toolbarStyle_)) ?? .automatic
        }
        lua_pushvalue(L, 1)
    } else {
        let style = NSWindow.ToolbarStyle(rawValue: Int(toolbar.toolbarStyle_)) ?? .automatic
        switch style {
        case .automatic:      lua_pushany(L, "automatic")
        case .expanded:       lua_pushany(L, "expanded")
        case .preference:     lua_pushany(L, "preference")
        case .unified:        lua_pushany(L, "unified")
        case .unifiedCompact: lua_pushany(L, "unifiedCompact")
        default: lua_pushany(L, "** unrecognized toolbarStyle (\(toolbar.toolbarStyle_))")
        }
    }
    return 1
}

private func toolbar_modifyItem(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)
    let toolbar = getToolbar(L, 1)

    guard lua_getfield(L, 2, "id") == LUA_TSTRING else {
        lua_pop(L, 1)
        throw LuaCallError("id must be present, and it must be a string")
    }
    let identifier = lua_tovalue(L, at: -1) as! String
    lua_pop(L, 1)

    guard toolbar.itemDefDictionary[identifier] != nil else {
        throw LuaCallError("toolbar item \(identifier) does not exist")
    }
    if builtinToolbarItems.contains(identifier) {
        throw LuaCallError("cannot modify a built-in toolbar item definition")
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
            let keyName = lua_tovalue(L, at: -2) as? String ?? ""
            if !keysToKeepFromDefinitionDictionary.contains(keyName) {
                if lua_type(L, -1) != LUA_TFUNCTION {
                    newDict[keyName] = lua_tovalue(L, at: -1)
                } else if keyName == "fn" {
                    lua_pushvalue(L, -1)
                    toolbar.fnRefDictionary[identifier] = NSNumber(value: luaL_ref(L, LUA_REGISTRYINDEX_VALUE))
                }
            }
        } else {
            throw LuaCallError("non-string keys not allowed in toolbar item definition \(identifier)")
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

private func toolbar_addItems(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)
    let toolbar = getToolbar(L, 1)

    let count = luaL_len(L, 2)
    var index: lua_Integer = 0
    var isGood = true

    while isGood && index < count {
        if lua_rawgeti(L, 2, index + 1) == LUA_TTABLE {
            isGood = toolbar.addToolbarDefinition(at: -1, state: L)
        } else {
            os_log(.info, "%{public}s", "\(USERDATA_TB_TAG):addItems - not a table at index \(index + 1)")
            isGood = false
        }
        lua_pop(L, 1)
        index += 1
    }

    if !isGood {
        throw LuaCallError("\(USERDATA_TB_TAG):addItems - malformed toolbar items encountered")
    }
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_deleteItem(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let toolbar = getToolbar(L, 1)
    let identifier = lua_tovalue(L, at: 2) as! String

    guard toolbar.itemDefDictionary[identifier] != nil else {
        throw LuaCallError("toolbar item \(identifier) does not exist")
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

private func toolbar_itemDetails(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let toolbar = getToolbar(L, 1)
    let identifier = lua_tovalue(L, at: 2) as! String

    guard toolbar.itemDefDictionary[identifier] != nil else {
        throw LuaCallError("toolbar item \(identifier) does not exist")
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
    wv_pushAny(L, ourItem)

    lua_pushboolean(L, toolbar.selectableIdentifiers_.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "selectable")
    lua_pushboolean(L, toolbar.defaultIdentifiers.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "default")
    lua_pushboolean(L, toolbar.allowedIdentifiers_.contains(identifier) ? 1 : 0)
    lua_setfield(L, -2, "allowedAlone")
    let fnRef = toolbar.fnRefDictionary[identifier] as? NSNumber
    lua_pushboolean(L, (fnRef != nil && fnRef!.int32Value != LUA_NOREF) ? 1 : 0)
    lua_setfield(L, -2, "privateCallback")

    if ourItem != nil {
        lua_pushany(L, (toolbar.itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedMenuTitle"])
        lua_setfield(L, -2, "searchPredefinedMenuTitle")
        lua_pushany(L, (toolbar.itemDefDictionary[identifier] as? NSDictionary)?["searchPredefinedSearches"])
        lua_setfield(L, -2, "searchPredefinedSearches")
        lua_pushany(L, (toolbar.itemDefDictionary[identifier] as? NSDictionary)?["groupMembers"])
        lua_setfield(L, -2, "groupMembers")
    }
    return 1
}

private func toolbar_allowedItems(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushany(L, toolbar.allowedIdentifiers_.array)
    return 1
}

private func toolbar_items(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushany(L, toolbar.items.map { $0.itemIdentifier.rawValue })
    return 1
}

private func toolbar_visibleItems(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushany(L, toolbar.visibleItems?.map { $0.itemIdentifier.rawValue })
    return 1
}

private func toolbar_selectedItem(_ L: LuaState) throws -> CInt {
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) == 2 {
        if lua_type(L, 2) == LUA_TSTRING {
            let identifier = lua_tovalue(L, at: 2) as! String
            guard toolbar.itemDefDictionary[identifier] != nil else {
                throw LuaCallError("toolbar item \(identifier) does not exist")
            }
            toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
        } else {
            toolbar.selectedItemIdentifier = nil
        }
        lua_pushvalue(L, 1)
    } else {
        lua_pushany(L, toolbar.selectedItemIdentifier?.rawValue)
    }
    return 1
}

private func toolbar_selectSearchField(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    let targetID = (lua_gettop(L) == 2) ? (lua_tovalue(L, at: 2) as? String) : nil

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

private func toolbar_identifier(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushany(L, toolbar.identifier)
    return 1
}

private func toolbar_customizePanel(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    toolbar.runCustomizationPalette(toolbar)
    lua_pushvalue(L, 1)
    return 1
}

private func toolbar_isCustomizing(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    lua_pushboolean(L, toolbar.customizationPaletteIsRunning ? 1 : 0)
    return 1
}

private func toolbar_canCustomize(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, toolbar.allowsUserCustomization ? 1 : 0)
    } else {
        toolbar.allowsUserCustomization = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

private func toolbar_autosaves(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TB_TAG)
    let toolbar = getToolbar(L, 1)
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, toolbar.autosavesConfiguration ? 1 : 0)
    } else {
        toolbar.autosavesConfiguration = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

// MARK: - Constants

private func toolbar_systemItems(_ L: LuaState) throws -> CInt {
    lua_pushany(L, automaticallyIncluded)
    return 1
}

private func toolbar_itemPriorities(_ L: LuaState) throws -> CInt {
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

@discardableResult
func toolbar_pushWindowContext(_ L: UnsafeMutablePointer<lua_State>!, _ window: NSWindow?) -> Int32 {
    guard let window else {
        lua_pushstring(L, "** no window attached")
        return 1
    }

    if window == consoleWindow() {
        lua_pushstring(L, "console")
    } else if let webview = window as? HSWebViewWindow {
        _ = wv_HSWebViewWindow_toLua(L, webview)
    } else if let chooser = window.windowController as? HSChooser {
        _ = pushHSChooser(L, chooser)
    } else if let controller = window.windowController {
        lua_pushany(L, controller)
    } else {
        lua_pushany(L, window)
    }
    return 1
}

@discardableResult
func toolbar_pushHSToolbar(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let toolbar = obj as? HSToolbar else { lua_pushnil(L); return 1 }
    if toolbar.selfRef == LUA_NOREF {
        let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        ptr.pointee = Unmanaged.passRetained(toolbar).toOpaque()
        luaL_getmetatable(L, USERDATA_TB_TAG)
        lua_setmetatable(L, -2)
        toolbar.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        identifiersInUse.add(toolbar.identifier)
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(toolbar.selfRef))
    return 1
}

private func toHSToolbar(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    guard luaL_testudata(L, idx, USERDATA_TB_TAG) != nil else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TB_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
    let toolbar = getToolbar(L, idx)
    _ = toolbar.isAttached
    return toolbar
}

private func pushNSToolbarItem(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let item = obj as? NSToolbarItem else { lua_pushnil(L); return 1 }
    lua_newtable(L)
    lua_pushany(L, item.itemIdentifier.rawValue); lua_setfield(L, -2, "id")
    lua_pushany(L, item.label); lua_setfield(L, -2, "label")
    lua_pushany(L, item.toolTip); lua_setfield(L, -2, "tooltip")
    lua_pushany(L, item.image); lua_setfield(L, -2, "image")
    lua_pushinteger(L, lua_Integer(item.visibilityPriority.rawValue)); lua_setfield(L, -2, "priority")
    lua_pushboolean(L, item.isEnabled ? 1 : 0); lua_setfield(L, -2, "enable")
    lua_pushinteger(L, lua_Integer(item.tag)); lua_setfield(L, -2, "tag")

    if let group = item as? NSToolbarItemGroup {
        lua_createtable(L, Int32(group.subitems.count), 0)
        for subitem in group.subitems {
            wv_pushAny(L, subitem)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        lua_setfield(L, -2, "subitems")
    }

    if let toolbar = item.toolbar as? HSToolbar {
        wv_pushAny(L, toolbar); lua_setfield(L, -2, "toolbar")
        if let sf = item.view as? HSToolbarSearchField {
            lua_pushnumber(L, lua_Number(item.maxSize.width)); lua_setfield(L, -2, "searchWidth")
            lua_pushany(L, sf.stringValue); lua_setfield(L, -2, "searchText")
            lua_pushboolean(L, sf.releaseOnCallback ? 1 : 0); lua_setfield(L, -2, "searchReleaseFocusOnCallback")
            lua_pushinteger(L, lua_Integer((sf.cell as? NSSearchFieldCell)?.maximumRecents ?? 0)); lua_setfield(L, -2, "searchHistoryLimit")
            lua_pushany(L, (sf.cell as? NSSearchFieldCell)?.recentSearches); lua_setfield(L, -2, "searchHistory")
            lua_pushany(L, (sf.cell as? NSSearchFieldCell)?.recentsAutosaveName); lua_setfield(L, -2, "searchHistoryAutosaveName")
        }
    }
    return 1
}

func wv_HSToolbar_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    return toolbar_pushHSToolbar(L, obj)
}

func wv_NSToolbarItem_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    return pushNSToolbarItem(L, obj)
}

// MARK: - Infrastructure

private func toolbar_tostring(_ L: LuaState) throws -> CInt {
    let toolbar = getToolbar(L, 1)
    let desc = "\(USERDATA_TB_TAG): \(toolbar.identifier) (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, desc)
    return 1
}

private func toolbar_eq(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, USERDATA_TB_TAG) != nil && luaL_testudata(L, 2, USERDATA_TB_TAG) != nil {
        let obj1 = getToolbar(L, 1)
        let obj2 = getToolbar(L, 2)
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func toolbar_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_TB_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let toolbar = Unmanaged<HSToolbar>.fromOpaque(ptr.pointee).takeRetainedValue()

    for (_, value) in toolbar.fnRefDictionary {
        if let num = value as? NSNumber {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, num.int32Value)
        }
    }

    if let ourWindow = toolbar.windowUsingToolbar, (ourWindow.toolbar as? HSToolbar) === toolbar {
        ourWindow.toolbar = nil
    }

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, toolbar.callbackRef)


    toolbar.callbackRef = LUA_NOREF
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, toolbar.selfRef)

    toolbar.selfRef = LUA_NOREF
    toolbar.delegate = nil

    let identifierIndex = identifiersInUse.index(of: toolbar.identifier)
    if identifierIndex != NSNotFound { identifiersInUse.removeObject(at: identifierIndex) }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    identifiersInUse.removeAllObjects()
    return 0
}

// MARK: - Entry point

@_cdecl("luaopen_hs_libwebviewtoolbar")
public func luaopen_hs_libwebviewtoolbar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TB_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(toolbar_addItems); lua_setfield(L, -2, "_addItems")
        L.push(toolbar_removeItem); lua_setfield(L, -2, "_removeItemAtIndex")
        L.push(toolbar_deleteItem); lua_setfield(L, -2, "deleteItem")
        L.push(toolbar_gc); lua_setfield(L, -2, "delete")
        L.push(toolbar_copy); lua_setfield(L, -2, "copyToolbar")
        L.push(toolbar_isAttached); lua_setfield(L, -2, "isAttached")
        L.push(toolbar_savedSettings); lua_setfield(L, -2, "savedSettings")
        L.push(toolbar_inTitleBar); lua_setfield(L, -2, "inTitleBar")
        L.push(toolbar_identifier); lua_setfield(L, -2, "identifier")
        L.push(toolbar_setCallback); lua_setfield(L, -2, "setCallback")
        L.push(toolbar_displayMode); lua_setfield(L, -2, "displayMode")
        L.push(toolbar_toolbarStyle); lua_setfield(L, -2, "toolbarStyle")
        L.push(toolbar_sizeMode); lua_setfield(L, -2, "sizeMode")
        L.push(toolbar_visible); lua_setfield(L, -2, "visible")
        L.push(toolbar_autosaves); lua_setfield(L, -2, "autosaves")
        L.push(toolbar_separator); lua_setfield(L, -2, "separator")
        L.push(toolbar_modifyItem); lua_setfield(L, -2, "modifyItem")
        L.push(toolbar_insertItem); lua_setfield(L, -2, "insertItem")
        L.push(toolbar_selectSearchField); lua_setfield(L, -2, "selectSearchField")
        L.push(toolbar_items); lua_setfield(L, -2, "items")
        L.push(toolbar_visibleItems); lua_setfield(L, -2, "visibleItems")
        L.push(toolbar_selectedItem); lua_setfield(L, -2, "selectedItem")
        L.push(toolbar_allowedItems); lua_setfield(L, -2, "allowedItems")
        L.push(toolbar_itemDetails); lua_setfield(L, -2, "itemDetails")
        L.push(toolbar_notifyOnChange); lua_setfield(L, -2, "notifyOnChange")
        L.push(toolbar_customizePanel); lua_setfield(L, -2, "customizePanel")
        L.push(toolbar_isCustomizing); lua_setfield(L, -2, "isCustomizing")
        L.push(toolbar_canCustomize); lua_setfield(L, -2, "canCustomize")
        L.push(toolbar_tostring); lua_setfield(L, -2, "__tostring")
        L.push(toolbar_eq); lua_setfield(L, -2, "__eq")
        L.push(toolbar_gc); lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 3)
        L.push(toolbar_new); lua_setfield(L, -2, "new")
        L.push(toolbar_attachToolbar); lua_setfield(L, -2, "attachToolbar")
        L.push(toolbar_uniqueName); lua_setfield(L, -2, "uniqueName")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc); lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

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

        try toolbar_systemItems(L); lua_setfield(L, -2, "systemToolbarItems")
        try toolbar_itemPriorities(L); lua_setfield(L, -2, "itemPriorities")
    }
}
