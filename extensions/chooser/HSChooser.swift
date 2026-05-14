//
//  HSChooser.swift
//  Hammerspoon
//
//  Created by Chris Jones on 29/12/2015.
//  Copyright © 2015 Hammerspoon. All rights reserved.
//

import Cocoa
import LuaSkin

// MARK: - Chooser definition

@objcMembers
class HSChooser: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, HSChooserTableViewDelegate {

    var queryField: NSTextField!
    var choicesTableView: HSChooserTableView!
    var effectView: NSVisualEffectView!

    var eventMonitors: [Any] = []
    var hasChosen: Bool = false
    var reloadWhenVisible: Bool = false

    // Customisable options
    var numRows: Int = 10
    var width: CGFloat = 40
    var fontName: String?
    var fontSize: CGFloat = 0
    var searchSubText: Bool = false
    var enableDefaultForQuery: Bool = false

    var fgColor: NSColor? {
        didSet {
            queryField?.textColor = fgColor
            guard let tableView = choicesTableView else { return }
            for x in 0..<tableView.numberOfRows {
                guard let cellView = tableView.view(atColumn: 0, row: x, makeIfNecessary: false) as? NSTableCellView else { continue }
                let text = cellView.viewWithTag(1) as? NSTextField
                let shortcutText = cellView.viewWithTag(2) as? NSTextField
                text?.textColor = fgColor
                shortcutText?.textColor = fgColor
            }
        }
    }

    var subTextColor: NSColor? {
        didSet {
            guard let tableView = choicesTableView else { return }
            for x in 0..<tableView.numberOfRows {
                guard let cellView = tableView.view(atColumn: 0, row: x, makeIfNecessary: false) as? NSTableCellView else { continue }
                let subText = cellView.viewWithTag(3) as? NSTextField
                subText?.textColor = subTextColor
            }
        }
    }

    var font: NSFont!

    // Size information we calculate for ourselves
    var winRect: NSRect = .zero
    var textRect: NSRect = .zero
    var listRect: NSRect = .zero
    var dividerRect: NSRect = .zero

    // Storage for different types of choice
    var currentStaticChoices: NSArray?
    var currentCallbackChoices: NSArray?
    var filteredChoices: NSArray?

    // Lua callback references
    var hideCallbackRef: Int32 = LUA_NOREF
    var showCallbackRef: Int32 = LUA_NOREF
    var choicesCallbackRef: Int32 = LUA_NOREF
    var queryChangedCallbackRef: Int32 = LUA_NOREF
    var completionCallbackRef: Int32 = LUA_NOREF
    var rightClickCallbackRef: Int32 = LUA_NOREF
    var invalidCallbackRef: Int32 = LUA_NOREF

    // A pointer to the hs.chooser module's references table
    var refTable: LSRefTable = 0

    // Our self-ref count
    var selfRefCount: Int = 0

    // Keep track of whether we are observing macOS interface theme (light/dark)
    var isObservingThemeChanges: Bool = false {
        didSet {
            guard oldValue != isObservingThemeChanges else { return }
            if isObservingThemeChanges {
                // Activate the observer.
                DistributedNotificationCenter.default().addObserver(
                    self,
                    selector: #selector(setBgLightDark(_:)),
                    name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                    object: nil)
            } else {
                // Deactivate the observer.
                DistributedNotificationCenter.default().removeObserver(
                    self,
                    name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                    object: nil)
            }
        }
    }

    // MARK: - Object initialisation

    init(refTable: LSRefTable, completionCallbackRef: Int32) {
        // Build the window programmatically instead of loading from a nib.
        let panel = HSChooser.createChooserWindow()
        super.init(window: panel)

        self.refTable = refTable
        self.selfRefCount = 0

        // Set our defaults
        self.numRows = 10
        self.width = 40
        self.fontName = nil
        self.fontSize = 0
        self.searchSubText = false

        // We're setting these directly, because we've overridden the setters and we don't need to invoke those now
        self.currentStaticChoices = nil
        self.currentCallbackChoices = nil
        self.filteredChoices = nil
        self.enableDefaultForQuery = false

        self.hideCallbackRef = LUA_NOREF
        self.showCallbackRef = LUA_NOREF
        self.choicesCallbackRef = LUA_NOREF
        self.queryChangedCallbackRef = LUA_NOREF
        self.rightClickCallbackRef = LUA_NOREF
        self.invalidCallbackRef = LUA_NOREF
        self.completionCallbackRef = completionCallbackRef

        self.hasChosen = false
        self.reloadWhenVisible = false

        // Decide which font to use
        if let name = self.fontName {
            self.font = NSFont(name: name, size: self.fontSize)
        } else {
            self.font = NSFont.systemFont(ofSize: self.fontSize)
        }

        calculateRects()

        guard setupWindow() else { return }

        // Start observing interface theme changes.
        self.isObservingThemeChanges = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Programmatic window construction

    private static func createChooserWindow() -> HSChooserWindow {
        let contentRect = NSRect(x: 574, y: 449, width: 509, height: 281)
        let styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .fullSizeContentView]
        let panel = HSChooserWindow(contentRect: contentRect,
                                    styleMask: styleMask,
                                    backing: .buffered,
                                    defer: true)
        panel.title = "Chooser"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .default
        panel.collectionBehavior = .ignoresCycle
        panel.allowsToolTipsWhenApplicationIsInactive = false
        panel.autorecalculatesKeyViewLoop = false

        // --- Root content view (HSChooserRootView) ---
        let rootView = HSChooserRootView(frame: NSRect(x: 0, y: 0, width: 509, height: 281))
        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView

        // --- Visual effect view (frosted glass) ---
        let effectView = NSVisualEffectView(frame: rootView.bounds)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        effectView.blendingMode = .behindWindow
        effectView.material = .sidebar
        effectView.state = .followsWindowActiveState
        rootView.addSubview(effectView)

        // Pin effectView to all edges of rootView
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        // --- Query text field (31pt system font, no border) ---
        let queryField = NSTextField(frame: .zero)
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.wantsLayer = true
        queryField.font = NSFont.systemFont(ofSize: 31)
        queryField.textColor = .controlTextColor
        queryField.backgroundColor = .textBackgroundColor
        queryField.isBordered = false
        queryField.isBezeled = false
        queryField.drawsBackground = false
        queryField.isEditable = true
        queryField.isSelectable = true
        queryField.usesSingleLineMode = true
        queryField.cell?.isScrollable = true
        queryField.cell?.lineBreakMode = .byClipping
        queryField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        effectView.addSubview(queryField)

        // --- Separator line ---
        let separator = NSBox(frame: .zero)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        effectView.addSubview(separator)

        // --- Scroll view + table view ---
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalLineScroll = 42
        scrollView.horizontalPageScroll = 10
        scrollView.verticalLineScroll = 42
        scrollView.verticalPageScroll = 10
        scrollView.usesPredominantAxisScrolling = false
        scrollView.drawsBackground = false

        let tableView = HSChooserTableView(frame: .zero)
        tableView.rowHeight = 40
        tableView.usesAutomaticRowHeights = true
        tableView.allowsExpansionToolTips = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .sourceList
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.autosaveTableColumns = false
        tableView.allowsTypeSelect = false
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.backgroundColor = NSColor(srgbRed: 0.0, green: 0.41176470588, blue: 0.85098039216, alpha: 0.0)
        tableView.gridColor = NSColor(white: 0.8, alpha: 0.0)
        tableView.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)

        // Create the single table column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.isEditable = false
        column.width = 487
        column.minWidth = 40
        column.maxWidth = 99000
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        // Ensure header is hidden (XIB had no visible header)
        tableView.headerView = nil

        scrollView.documentView = tableView
        effectView.addSubview(scrollView)

        // --- Auto Layout constraints matching the XIB ---
        // queryField: top=20, leading=20, trailing=20 from effectView; height=43
        // separator: top=20 below queryField; leading=0, trailing=0 from effectView
        // scrollView: top=5 below separator; leading=5, trailing=5, bottom=5 from effectView
        NSLayoutConstraint.activate([
            // Query field
            queryField.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 20),
            queryField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),
            effectView.trailingAnchor.constraint(equalTo: queryField.trailingAnchor, constant: 20),
            queryField.heightAnchor.constraint(equalToConstant: 43),

            // Separator
            separator.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: separator.trailingAnchor),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 5),
            effectView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 5),
            effectView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 5),
        ])

        return panel
    }

    // MARK: - Window related methods

    func windowDidBecomeKey(_ notification: Notification) {
        if reloadWhenVisible {
            choicesTableView.reloadData()
            reloadWhenVisible = false
        }

        weak var weakSelf = self
        weak var weakTableView = choicesTableView
        weak var weakWindow = window

        addShortcut("1", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 0) }
        addShortcut("2", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 1) }
        addShortcut("3", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 2) }
        addShortcut("4", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 3) }
        addShortcut("5", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 4) }
        addShortcut("6", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 5) }
        addShortcut("7", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 6) }
        addShortcut("8", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 7) }
        addShortcut("9", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 8) }
        addShortcut("0", keyCode: -1, mods: .command) { weakSelf?.tableView(weakTableView!, didClickedRow: 9) }

        addShortcut("Escape", keyCode: 27, mods: []) { weakWindow?.resignKey() }

        addShortcut("Up", keyCode: UInt16(NSUpArrowFunctionKey), mods: [.function, .numericPad]) { weakSelf?.selectPreviousChoice() }
        addShortcut("Down", keyCode: UInt16(NSDownArrowFunctionKey), mods: [.function, .numericPad]) { weakSelf?.selectNextChoice() }
        addShortcut("p", keyCode: -1, mods: .control) { weakSelf?.selectPreviousChoice() }
        addShortcut("n", keyCode: -1, mods: .control) { weakSelf?.selectNextChoice() }

        addShortcut("PageUp", keyCode: UInt16(NSPageUpFunctionKey), mods: .function) { weakSelf?.selectPreviousPage() }
        addShortcut("PageDown", keyCode: UInt16(NSPageDownFunctionKey), mods: .function) { weakSelf?.selectNextPage() }
        addShortcut("v", keyCode: -1, mods: .control) { weakSelf?.selectNextPage() }
    }

    func windowDidResignKey(_ notification: Notification) {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()

        if !hasChosen {
            cancel(nil)
        }
    }

    func calculateRects() {
        // Calculate the sizes of the various bits of our UI
        var winRect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let contentViewRect = winRect.insetBy(dx: 10, dy: 10)

        var textRect: NSRect = .zero
        var listRect: NSRect = .zero
        var dividerRect: NSRect = .zero
        var remainder: NSRect = .zero

        NSDivideRect(contentViewRect, &textRect, &remainder, font.boundingRectForFont.height, .maxY)
        NSDivideRect(remainder, &dividerRect, &listRect, 20.0, .maxY)
        dividerRect.origin.y += dividerRect.height / 2.0
        dividerRect.size.height = 1.0

        self.winRect = winRect
        self.textRect = textRect
        self.listRect = listRect
        self.dividerRect = dividerRect
    }

    func setupWindow() -> Bool {
        guard let _ = window else {
            NSLog("ERROR: Unable to create hs.chooser window")
            return false
        }

        // Configure delegates and actions (previously set via NIB outlets)
        choicesTableView.delegate = self
        choicesTableView.extendedDelegate = self
        choicesTableView.dataSource = self
        choicesTableView.target = self

        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(queryDidPressEnter(_:))

        // Previously done in windowDidLoad
        queryField.focusRingType = .none
        setAutoBgLightDark()

        return true
    }

    // We need to intercept the createChooserWindow result to capture outlet references.
    // Override the window setter to grab the views from the panel we built.
    override var window: NSWindow? {
        didSet {
            if let panel = window {
                // Walk the view hierarchy to capture references set up in createChooserWindow.
                // The static factory can't assign to instance properties, so we do it here.
                if let ev = findSubview(ofType: NSVisualEffectView.self, in: panel.contentView) {
                    effectView = ev
                    if let qf = findSubview(ofType: NSTextField.self, in: ev, where: { $0.isEditable }) {
                        queryField = qf
                    }
                    if let tv = findSubview(ofType: HSChooserTableView.self, in: ev) {
                        choicesTableView = tv
                    }
                }
            }
        }
    }

    private func findSubview<T: NSView>(ofType type: T.Type, in view: NSView?, where predicate: ((T) -> Bool)? = nil) -> T? {
        guard let view = view else { return nil }
        for sub in view.subviews {
            if let match = sub as? T, predicate?(match) ?? true {
                return match
            }
            if let found = findSubview(ofType: type, in: sub, where: predicate) {
                return found
            }
        }
        return nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            // User hit cmd-enter
            queryDidPressEnter(self)
            return true
        } else if commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
            // User hit option-enter
            queryDidPressEnter(self)
            return true
        }
        return false
    }

    func resizeWindow() {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        let rowHeight = choicesTableView.rowHeight
        let intercellHeight = choicesTableView.intercellSpacing.height
        let allRowsHeight = (rowHeight + intercellHeight) * CGFloat(numRows)

        var toolbarHeight: CGFloat = 0.0
        if let toolbar = window?.toolbar, toolbar.isVisible {
            let windowFrame = NSWindow.contentRect(forFrameRect: window!.frame, styleMask: window!.styleMask)
            toolbarHeight = windowFrame.height - (window!.contentView?.frame.height ?? 0)
        }

        let windowHeight = window?.contentView?.bounds.height ?? 0
        let tableHeight = choicesTableView.superview?.frame.height ?? 0
        let finalHeight = (windowHeight - tableHeight) + allRowsHeight + toolbarHeight

        let width: CGFloat
        if self.width >= 0 && self.width <= 100 {
            let percentWidth = self.width / 100.0
            width = screenFrame.width * percentWidth
        } else {
            var w = screenFrame.width * 0.50
            w = min(w, 800)
            w = max(w, 400)
            width = w
        }

        let winRect = NSRect(x: 0, y: 0, width: width, height: finalHeight)
        window?.setFrame(winRect, display: true)
        choicesTableView.setFrameSize(NSSize(width: winRect.width, height: choicesTableView.frame.height))
    }

    func showAtPoint(_ topLeft: NSPoint) {
        showWithHints(false, atPoint: topLeft)
    }

    func show() {
        showWithHints(true, atPoint: .zero)
    }

    func showWithHints(_ center: Bool, atPoint topLeft: NSPoint) {
        hasChosen = false

        // Call hs.chooser.globalCallback("willShow")
        let skin = LuaSkin.shared(withState: nil)
        let L = skin.L!
        _lua_stackguard_entry(L)
        skin.requireModule("hs.chooser")
        lua_getfield(L, -1, "globalCallback")
        lua_remove(L, -2)

        // Check the type of `globalCallback`
        if lua_type(L, -1) == LUA_TNIL {
            lua_remove(L, -1)
        } else if lua_type(L, -1) != LUA_TFUNCTION {
            skin.logError(String(format: "hs.chooser.globalCallback is expected to be a function, but is a %s",
                                 lua_typename(L, lua_type(L, -1))))
            // Remove whatever `globalCallback` is, from the stack
            lua_remove(L, -1)
        } else {
            skin.pushNSObject(self)
            lua_pushstring(L, "willOpen")
            skin.protectedCallAndError("hs.chooser.globalCallback willOpen", nargs: 2, nresults: 0)
        }

        resizeWindow()

        showWindow(self)
        window?.isVisible = true

        if center {
            window?.center()
        } else {
            window?.setFrameTopLeftPoint(topLeft)
        }
        window?.makeKeyAndOrderFront(self)
        window?.makeFirstResponder(queryField)

        window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)

        controlTextDidChange(Notification(name: Notification.Name("Unused"), object: nil))

        if showCallbackRef != LUA_NOREF && showCallbackRef != LUA_REFNIL {
            skin.pushLuaRef(refTable, ref: showCallbackRef)
            skin.protectedCallAndError("hs.chooser:showCallback", nargs: 0, nresults: 0)
        }
        _lua_stackguard_exit(skin.L)
    }

    func hide() {
        window?.isVisible = false

        // Call hs.chooser.globalCallback("didClose")
        let skin = LuaSkin.shared(withState: nil)
        let L = skin.L!
        _lua_stackguard_entry(L)
        skin.requireModule("hs.chooser")
        lua_getfield(L, -1, "globalCallback")
        lua_remove(L, -2)

        // Check the type of `globalCallback`
        if lua_type(L, -1) == LUA_TNIL {
            lua_remove(L, -1)
        } else if lua_type(L, -1) != LUA_TFUNCTION {
            skin.logError(String(format: "hs.chooser.globalCallback is expected to be a function, but is a %s",
                                 lua_typename(L, lua_type(L, -1))))
            // Remove whatever `globalCallback` is, from the stack
            lua_remove(L, -1)
        } else {
            skin.pushNSObject(self)
            lua_pushstring(L, "didClose")
            skin.protectedCallAndError("hs.chooser.globalCallback didClose", nargs: 2, nresults: 0)
        }

        // Call hs.chooser:hideCallback()
        if hideCallbackRef != LUA_NOREF && hideCallbackRef != LUA_REFNIL {
            skin.pushLuaRef(refTable, ref: hideCallbackRef)
            skin.protectedCallAndError("hs.chooser:hideCallback", nargs: 0, nresults: 0)
        }
        _lua_stackguard_exit(L)
    }

    var isVisible: Bool {
        return window?.isVisible ?? false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return getChoices()?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let choices = getChoices(), row < choices.count else { return nil }
        let choice = choices[row] as! NSDictionary

        var text: Any? = choice["text"]
        var subText: Any? = choice["subText"]
        var shortcutText = ""
        var image = choice["image"] as? NSImage

        if let t = text, !(t is String), !(t is NSAttributedString) {
            text = String(describing: t)
        }
        if let st = subText, !(st is String), !(st is NSAttributedString) {
            subText = String(describing: st)
        }
        if image != nil && !(image is NSImage) { image = nil }

        if row >= 0 && row < 9 {
            shortcutText = "\u{2318}\(row + 1)"
        }

        let chooserCellIdentifier = subText != nil ? "HSChooserCellSubtext" : "HSChooserCell"
        let identifier = NSUserInterfaceItemIdentifier(chooserCellIdentifier)
        var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? HSChooserCell

        if cellView == nil {
            if subText != nil {
                cellView = makeSubtextCell(withIdentifier: chooserCellIdentifier)
            } else {
                cellView = makePlainCell(withIdentifier: chooserCellIdentifier)
            }
        }

        guard let cell = cellView else { return nil }

        if let attrText = text as? NSAttributedString {
            cell.text.attributedStringValue = attrText
        } else {
            cell.text.stringValue = (text as? String) ?? ""
        }

        if subText != nil {
            if let attrSubText = subText as? NSAttributedString {
                cell.subText.attributedStringValue = attrSubText
            } else {
                cell.subText.stringValue = (subText as? String) ?? ""
            }
        }

        cell.shortcutText.stringValue = shortcutText.isEmpty ? "??" : shortcutText
        cell.image.image = image ?? NSImage(named: NSImage.followLinkFreestandingTemplateName)

        if let fg = fgColor {
            cell.text.textColor = fg
            cell.shortcutText.textColor = fg
        }

        if let stc = self.subTextColor {
            cell.subText?.textColor = stc
        }

        return cell
    }

    // MARK: - Programmatic cell construction

    /// Create the "HSChooserCellSubtext" cell: icon (36px) | main text (15pt) + subtext (cellTitle font) | shortcut text (25pt)
    private func makeSubtextCell(withIdentifier identifier: String) -> HSChooserCell {
        let cell = HSChooserCell(frame: NSRect(x: 0, y: 0, width: 496, height: 40))
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)
        cell.autoresizingMask = [.width, .height]

        // --- Image view (36px wide, pinned top+bottom+leading) ---
        let imageView = NSImageView(frame: .zero)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.tag = 4
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(named: NSImage.actionTemplateName)
        cell.addSubview(imageView)
        cell.image = imageView
        cell.imageView = imageView

        // --- Main text field (15pt system, secondaryLabelColor) ---
        let textField = NSTextField(frame: .zero)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.tag = 1
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.allowsExpansionToolTips = true
        textField.font = NSFont.systemFont(ofSize: 15)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = true
        textField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        textField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        cell.addSubview(textField)
        cell.text = textField

        // --- Subtext field (cellTitle font, tertiaryLabelColor) ---
        let subTextField = NSTextField(frame: .zero)
        subTextField.translatesAutoresizingMaskIntoConstraints = false
        subTextField.tag = -1
        subTextField.isBordered = false
        subTextField.isBezeled = false
        subTextField.drawsBackground = false
        subTextField.isEditable = false
        subTextField.isSelectable = false
        subTextField.allowsExpansionToolTips = true
        subTextField.font = NSFont(name: NSFont.systemFont(ofSize: 0).fontName, size: NSFont.smallSystemFontSize)
        subTextField.textColor = .tertiaryLabelColor
        subTextField.lineBreakMode = .byTruncatingMiddle
        subTextField.cell?.truncatesLastVisibleLine = true
        subTextField.cell?.sendsActionOnEndEditing = true
        subTextField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        subTextField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        cell.addSubview(subTextField)
        cell.subText = subTextField

        // --- Shortcut text field (25pt system, 40x40, vertically centering cell) ---
        let shortcutField = NSTextField(frame: .zero)
        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.tag = 2
        shortcutField.isBordered = false
        shortcutField.isBezeled = false
        shortcutField.drawsBackground = false
        shortcutField.isEditable = false
        shortcutField.isSelectable = false
        shortcutField.allowsExpansionToolTips = true
        shortcutField.cell = HSChooserVerticallyCenteringTextFieldCell(textCell: "??")
        shortcutField.font = NSFont.systemFont(ofSize: 25)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .left
        shortcutField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1000), for: .vertical)
        shortcutField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        cell.addSubview(shortcutField)
        cell.shortcutText = shortcutField

        // --- Constraints matching XIB "HSChooserCellSubtext" ---
        NSLayoutConstraint.activate([
            // Image: width=36, leading=cell.leading, top=cell.top+2, bottom=cell.bottom
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cell.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

            // Main text: top=cell.top+5, leading=image.trailing+5
            textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),

            // Subtext: leading=image.trailing+5, bottom=cell.bottom-3
            subTextField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            cell.bottomAnchor.constraint(equalTo: subTextField.bottomAnchor, constant: 3),

            // Main text bottom = subtext top + 2
            textField.bottomAnchor.constraint(equalTo: subTextField.topAnchor, constant: 2),

            // Shortcut: width=40, height=40, trailing=cell.trailing, centerY=image.centerY
            shortcutField.widthAnchor.constraint(equalToConstant: 40),
            shortcutField.heightAnchor.constraint(equalToConstant: 40),
            cell.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor),
            shortcutField.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

            // Shortcut leading = text.trailing+5 and subtext.trailing+5
            shortcutField.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 5),
            shortcutField.leadingAnchor.constraint(equalTo: subTextField.trailingAnchor, constant: 5),
        ])

        return cell
    }

    /// Create the "HSChooserCell" cell: icon (36px) | main text (20pt, vertically centering) | shortcut text (25pt)
    private func makePlainCell(withIdentifier identifier: String) -> HSChooserCell {
        let cell = HSChooserCell(frame: NSRect(x: 0, y: 0, width: 496, height: 40))
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)
        cell.autoresizingMask = [.width, .height]

        // --- Image view (36px wide) ---
        let imageView = NSImageView(frame: .zero)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.tag = 4
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(named: NSImage.actionTemplateName)
        cell.addSubview(imageView)
        cell.image = imageView
        cell.imageView = imageView

        // --- Main text field (20pt, vertically centering cell, secondaryLabelColor) ---
        let textField = NSTextField(frame: .zero)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.tag = 1
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.allowsExpansionToolTips = true
        textField.cell = HSChooserVerticallyCenteringTextFieldCell(textCell: "")
        textField.font = NSFont.systemFont(ofSize: 20)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = true
        textField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        textField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        cell.addSubview(textField)
        cell.text = textField

        // --- Shortcut text field (25pt, 40x40, vertically centering cell) ---
        let shortcutField = NSTextField(frame: .zero)
        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.tag = 2
        shortcutField.isBordered = false
        shortcutField.isBezeled = false
        shortcutField.drawsBackground = false
        shortcutField.isEditable = false
        shortcutField.isSelectable = false
        shortcutField.allowsExpansionToolTips = true
        shortcutField.cell = HSChooserVerticallyCenteringTextFieldCell(textCell: "??")
        shortcutField.font = NSFont.systemFont(ofSize: 25)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .left
        shortcutField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        shortcutField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1000), for: .vertical)
        cell.addSubview(shortcutField)
        cell.shortcutText = shortcutField

        // --- Constraints matching XIB "HSChooserCell" ---
        NSLayoutConstraint.activate([
            // Image: width=36, leading=cell.leading, top=cell.top+2, bottom=cell.bottom
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cell.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

            // Text: top=cell.top+5, bottom=cell.bottom-5, leading=image.trailing+5
            textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            cell.bottomAnchor.constraint(equalTo: textField.bottomAnchor, constant: 5),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),

            // Shortcut: width=40, height=40, trailing=cell.trailing, centerY=image.centerY
            shortcutField.widthAnchor.constraint(equalToConstant: 40),
            shortcutField.heightAnchor.constraint(equalToConstant: 40),
            cell.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor),
            shortcutField.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

            // Shortcut leading = text.trailing+5
            shortcutField.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 5),
        ])

        return cell
    }

    // MARK: - HSChooserTableViewDelegate

    func tableView(_ tableView: NSTableView, didClickedRow row: Int) {
        guard let choices = getChoices() else { return }

        if row >= 0 && row < choices.count {
            hasChosen = true
            let skin = LuaSkin.shared(withState: nil)
            _lua_stackguard_entry(skin.L)
            let choice = choices[row] as! NSDictionary

            if let valid = choice["valid"] as? NSNumber, !valid.boolValue,
               invalidCallbackRef != LUA_NOREF && invalidCallbackRef != LUA_REFNIL {
                skin.pushLuaRef(refTable, ref: invalidCallbackRef)
                skin.pushNSObject(choice)
                skin.protectedCallAndError("hs.chooser:invalidCallback", nargs: 1, nresults: 0)
            } else if completionCallbackRef != LUA_NOREF && completionCallbackRef != LUA_REFNIL {
                hide()
                skin.pushLuaRef(refTable, ref: completionCallbackRef)
                skin.pushNSObject(choice)
                skin.protectedCallAndError("hs.chooser:completionCallback", nargs: 1, nresults: 0)
            }

            _lua_stackguard_exit(skin.L)
        } else if enableDefaultForQuery && completionCallbackRef != LUA_NOREF && completionCallbackRef != LUA_REFNIL {
            // No row remaining in choices, return just query
            hasChosen = true
            let skin = LuaSkin.shared(withState: nil)
            _lua_stackguard_entry(skin.L)
            let choice: NSDictionary = ["text": queryField.stringValue]
            hide()
            skin.pushLuaRef(refTable, ref: completionCallbackRef)
            skin.pushNSObject(choice)
            skin.protectedCallAndError("hs.chooser:completionCallback", nargs: 1, nresults: 0)

            _lua_stackguard_exit(skin.L)
        }
    }

    func didRightClick(atRow row: Int) {
        if rightClickCallbackRef != LUA_NOREF && rightClickCallbackRef != LUA_REFNIL {
            // We have a right click callback set
            let skin = LuaSkin.shared(withState: nil)
            _lua_stackguard_entry(skin.L)
            skin.pushLuaRef(refTable, ref: rightClickCallbackRef)
            lua_pushinteger(skin.L, lua_Integer(row + 1))
            skin.protectedCallAndError("hs.chooser:rightClickCallback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(skin.L)
        }
    }

    // MARK: - UI callbacks

    @IBAction func cancel(_ sender: Any?) {
        hide()
        let skin = LuaSkin.shared(withState: nil)
        _lua_stackguard_entry(skin.L)

        if !skin.checkRefs(refTable, completionCallbackRef, LS_RBREAK) {
            skin.logWarn("Unable to call hs.chooser:completionCallback, reference is no longer valid")
            _lua_stackguard_exit(skin.L)
            return
        }

        skin.pushLuaRef(refTable, ref: completionCallbackRef)
        lua_pushnil(skin.L)
        skin.protectedCallAndError("hs.chooser:completionCallback", nargs: 1, nresults: 0)
        _lua_stackguard_exit(skin.L)
    }

    @IBAction func queryDidPressEnter(_ sender: Any?) {
        tableView(choicesTableView, didClickedRow: choicesTableView.selectedRow)
    }

    func controlTextDidChange(_ aNotification: Notification) {
        let queryString = queryField.stringValue

        if queryChangedCallbackRef != LUA_NOREF && queryChangedCallbackRef != LUA_REFNIL {
            // We have a query callback set, we are passing on responsibility for displaying/filtering results, to Lua
            let skin = LuaSkin.shared(withState: nil)
            _lua_stackguard_entry(skin.L)
            skin.pushLuaRef(refTable, ref: queryChangedCallbackRef)
            skin.pushNSObject(queryString as NSString)
            skin.protectedCallAndError("hs.chooser:queryChangedCallback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(skin.L)
        } else {
            // We do not have a query callback set, so we are doing the filtering
            if !queryString.isEmpty {
                let filtered = NSMutableArray()
                let lowercaseQuery = queryString.lowercased()

                for item in getChoicesWithOptions(false) ?? [] {
                    guard let choice = item as? NSDictionary else { continue }
                    var textStr: String
                    if let t = choice["text"] {
                        if let s = t as? String { textStr = s }
                        else { textStr = String(describing: t) }
                    } else {
                        textStr = ""
                    }

                    if textStr.lowercased().contains(lowercaseQuery) {
                        filtered.add(choice)
                    } else if searchSubText {
                        var subTextStr: String
                        if let st = choice["subText"] {
                            if let s = st as? String { subTextStr = s }
                            else { subTextStr = String(describing: st) }
                        } else {
                            subTextStr = ""
                        }
                        if subTextStr.lowercased().contains(lowercaseQuery) {
                            filtered.add(choice)
                        }
                    }
                }

                filteredChoices = filtered
            } else {
                filteredChoices = nil
            }
            choicesTableView.reloadData()
        }
    }

    func selectChoice(_ row: Int) {
        let numRows = getChoices()?.count ?? 0
        if row < 0 || row > numRows - 1 {
            LuaSkin.logError(String(format: "ERROR: unable to select row %ld of %ld", row, numRows))
            return
        }
        choicesTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        // FIXME: This scrolling is awfully jumpy
        choicesTableView.scrollRowToVisible(row)
    }

    func selectNextChoice() {
        var currentRow = choicesTableView.selectedRow
        if currentRow == (getChoices()?.count ?? 0) - 1 {
            currentRow = -1
        }
        selectChoice(currentRow + 1)
    }

    func selectPreviousChoice() {
        var currentRow = choicesTableView.selectedRow
        if currentRow == 0 {
            currentRow = getChoices()?.count ?? 0
        }
        selectChoice(currentRow - 1)
    }

    func selectNextPage() {
        let currentRow = choicesTableView.selectedRow
        let count = getChoices()?.count ?? 0
        if currentRow == count - 1 {
            selectChoice(0)
        } else if currentRow >= count - 10 {
            selectChoice(count - 1)
        } else {
            selectChoice(currentRow + 10)
        }
    }

    func selectPreviousPage() {
        let currentRow = choicesTableView.selectedRow
        if currentRow == 0 {
            selectChoice((getChoices()?.count ?? 0) - 1)
        } else if currentRow < 10 {
            selectChoice(0)
        } else {
            selectChoice(currentRow - 10)
        }
    }

    // MARK: - Choice management methods

    func updateChoices() {
        if window?.isVisible == true {
            choicesTableView.reloadData()
        } else {
            reloadWhenVisible = true
        }
    }

    func clearChoices() {
        currentStaticChoices = nil
        currentCallbackChoices = nil
        filteredChoices = nil
    }

    func clearChoicesAndUpdate() {
        clearChoices()
        updateChoices()
    }

    func getChoices() -> NSArray? {
        return getChoicesWithOptions(true)
    }

    func getChoicesWithOptions(_ includeFiltered: Bool) -> NSArray? {
        if includeFiltered, let filtered = filteredChoices {
            // We have some previously filtered choices, so we will return that
            return filtered
        } else if choicesCallbackRef == LUA_NOREF {
            // No callback is set, we can only return the static choices, even if it's nil
            return currentStaticChoices
        } else {
            // We have a callback set
            if currentCallbackChoices == nil {
                // We have not previously cached the callback choices
                let skin = LuaSkin.shared(withState: nil)
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: choicesCallbackRef)
                if skin.protectedCallAndTraceback(0, nresults: 1) {
                    currentCallbackChoices = skin.toNSObject(atIndex: -1) as? NSArray

                    var callbackChoicesTypeCheckPass = false
                    if let arr = currentCallbackChoices as? [Any] {
                        callbackChoicesTypeCheckPass = true
                        for element in arr {
                            if !(element is NSDictionary) {
                                callbackChoicesTypeCheckPass = false
                                break
                            }
                        }
                    }
                    if !callbackChoicesTypeCheckPass {
                        // Light verification of the callback choices shows the format is wrong, so let's ignore it
                        LuaSkin.logError("ERROR: data returned by hs.chooser:choices() callback could not be parsed correctly")
                        currentCallbackChoices = nil
                    }
                } else {
                    skin.logError(String(format: "%s:choices error - %@", USERDATA_TAG,
                                         skin.toNSObject(atIndex: -1) as? String ?? "unknown"))
                    // No need to lua_pop() here, see below
                }
                lua_pop(skin.L, 1) // remove result or error message
                _lua_stackguard_exit(skin.L)
            }

            return currentCallbackChoices
        }
    }

    // MARK: - UI customisation methods

    func applyDarkSetting(_ beDark: Bool) {
        let appearance = beDark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        window?.appearance = appearance
    }

    func setAutoBgLightDark() {
        let interfaceStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        let isDark = interfaceStyle?.lowercased() == "dark"
        applyDarkSetting(isDark)
    }

    func setBgLightDark(_ notification: Notification) {
        if notification.object == nil {
            isObservingThemeChanges = true
            setAutoBgLightDark()
            return
        }
        isObservingThemeChanges = false
        if let number = notification.object as? NSNumber {
            applyDarkSetting(number.boolValue)
        }
    }

    func isBgLightDark() -> Bool {
        return window?.appearance?.name == .vibrantDark
    }

    // MARK: - Utility methods

    func addShortcut(_ key: String, keyCode: UInt16, mods: NSEvent.ModifierFlags, handler action: @escaping () -> Void) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == mods {
                do {
                    let chars = event.charactersIgnoringModifiers ?? ""
                    if chars == key || (!chars.isEmpty && chars.unicodeScalars.first?.value == UInt32(keyCode)) {
                        action()
                        return nil
                    }
                }
            }
            return event
        }
        if let monitor = monitor {
            eventMonitors.append(monitor)
        }
    }
}
