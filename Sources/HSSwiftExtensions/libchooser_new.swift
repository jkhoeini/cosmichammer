import Cocoa
import LuaSkin
import os.log

// MARK: - HSChooserTableView delegate protocol

@objc protocol HSChooserTableViewDelegate: AnyObject {
    func tableView(_ tableView: NSTableView, didClickedRow row: Int)
    func didRightClick(atRow row: Int)
}

// MARK: - HSChooserWindow

@objc class HSChooserWindow: NSPanel {
    override var canBecomeMain: Bool { true }
    override var canBecomeKey: Bool { true }
}

// MARK: - HSChooserRootView

@objc class HSChooserRootView: NSView {
    override var allowsVibrancy: Bool { true }
}

// MARK: - HSChooserCell

@objc class HSChooserCell: NSTableCellView {
    @objc var text: NSTextField!
    @objc var subText: NSTextField!
    @objc var shortcutText: NSTextField!
    // Note: 'image' property shadows NSTableCellView.imageView; we use a separate NSImageView reference.
    @objc var iconView: NSImageView!

    override var allowsVibrancy: Bool { false }
}

// MARK: - HSChooserVerticallyCenteringTextFieldCell

@objc class HSChooserVerticallyCenteringTextFieldCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var attrString = attributedStringValue

        if isHighlighted && backgroundStyle == .emphasized {
            let whiteString = attrString.mutableCopy() as! NSMutableAttributedString
            whiteString.addAttribute(.foregroundColor, value: NSColor.white,
                                     range: NSRange(location: 0, length: whiteString.length))
            attrString = whiteString
        }

        attrString.draw(with: titleRect(forBounds: cellFrame),
                         options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    override func titleRect(forBounds theRect: NSRect) -> NSRect {
        var titleFrame = super.titleRect(forBounds: theRect)

        let attrString = attributedStringValue
        let textRect = attrString.boundingRect(
            with: titleFrame.size,
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

        if textRect.size.height < titleFrame.size.height {
            titleFrame.origin.y = theRect.origin.y + (theRect.size.height - textRect.size.height) / 2.0
            titleFrame.size.height = textRect.size.height
        }
        return titleFrame
    }
}

// MARK: - HSChooserTableView

@objc class HSChooserTableView: NSTableView {
    @objc weak var extendedDelegate: HSChooserTableViewDelegate?
    var mouseTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mouseTrackingArea = NSTrackingArea(rect: frame,
                                           options: [.activeInKeyWindow, .mouseMoved],
                                           owner: self, userInfo: nil)
        addTrackingArea(mouseTrackingArea!)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func updateTrackingAreas() {
        if let existing = mouseTrackingArea {
            removeTrackingArea(existing)
        }
        mouseTrackingArea = NSTrackingArea(rect: frame,
                                           options: [.mouseMoved, .activeInKeyWindow],
                                           owner: self, userInfo: nil)
        addTrackingArea(mouseTrackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        let globalLocation = event.locationInWindow
        let localLocation = convert(globalLocation, from: nil)
        let clickedRow = row(at: localLocation)

        super.mouseDown(with: event)

        if clickedRow != -1 {
            extendedDelegate?.tableView(self, didClickedRow: clickedRow)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let globalLocation = event.locationInWindow
        let localLocation = convert(globalLocation, from: nil)
        let row = self.row(at: localLocation)

        super.mouseMoved(with: event)

        if row != -1 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollRowToVisible(row)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let globalLocation = event.locationInWindow
        let localLocation = convert(globalLocation, from: nil)
        let row = self.row(at: localLocation)
        extendedDelegate?.didRightClick(atRow: row)
    }

    override var allowsVibrancy: Bool { false }
}

// MARK: - HSChooser

@objc class HSChooser: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                       NSTableViewDataSource, NSTableViewDelegate, HSChooserTableViewDelegate {

    @objc var queryField: NSTextField!
    @objc var choicesTableView: HSChooserTableView!
    @objc var effectView: NSVisualEffectView!

    @objc var eventMonitors: NSMutableArray = NSMutableArray()
    @objc var hasChosen: Bool = false
    @objc var reloadWhenVisible: Bool = false

    // Customisable options
    @objc var numRows: Int = 10
    @objc var width: CGFloat = 40
    @objc var fontName: String?
    @objc var fontSize: CGFloat = 0
    @objc var searchSubText: Bool = false
    @objc var enableDefaultForQuery: Bool = false

    @objc var fgColor: NSColor? {
        didSet {
            queryField?.textColor = fgColor
            let numTableRows = choicesTableView?.numberOfRows ?? 0
            for x in 0..<numTableRows {
                if let cellView = choicesTableView.view(atColumn: 0, row: x, makeIfNecessary: false) as? NSTableCellView {
                    (cellView.viewWithTag(1) as? NSTextField)?.textColor = fgColor
                    (cellView.viewWithTag(2) as? NSTextField)?.textColor = fgColor
                }
            }
        }
    }

    @objc var subTextColor: NSColor? {
        didSet {
            let numTableRows = choicesTableView?.numberOfRows ?? 0
            for x in 0..<numTableRows {
                if let cellView = choicesTableView.view(atColumn: 0, row: x, makeIfNecessary: false) as? NSTableCellView {
                    (cellView.viewWithTag(3) as? NSTextField)?.textColor = subTextColor
                }
            }
        }
    }

    @objc var font: NSFont!

    // Size information we calculate for ourselves
    var winRect: NSRect = .zero
    var textRect: NSRect = .zero
    var listRect: NSRect = .zero
    var dividerRect: NSRect = .zero

    // Storage for different types of choice
    @objc var currentStaticChoices: NSArray?
    @objc var currentCallbackChoices: NSArray?
    @objc var filteredChoices: NSArray?

    // Lua callback references
    @objc var hideCallbackRef: Int32 = LUA_NOREF
    @objc var showCallbackRef: Int32 = LUA_NOREF
    @objc var choicesCallbackRef: Int32 = LUA_NOREF
    @objc var queryChangedCallbackRef: Int32 = LUA_NOREF
    @objc var completionCallbackRef: Int32 = LUA_NOREF
    @objc var rightClickCallbackRef: Int32 = LUA_NOREF
    @objc var invalidCallbackRef: Int32 = LUA_NOREF

    // A pointer to the hs.chooser module's references table
    @objc var refTable: LSRefTable = LUA_NOREF

    // Our self-ref count
    @objc var selfRefCount: Int32 = 0

    // Keep track of whether we are observing macOS interface theme (light/dark)
    @objc var isObservingThemeChanges: Bool = false {
        didSet {
            guard oldValue != isObservingThemeChanges else { return }
            if isObservingThemeChanges {
                DistributedNotificationCenter.default().addObserver(
                    self,
                    selector: #selector(setBgLightDark(_:)),
                    name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                    object: nil)
            } else {
                DistributedNotificationCenter.default().removeObserver(
                    self,
                    name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                    object: nil)
            }
        }
    }

    // MARK: - Initialiser

    @objc init(refTable: LSRefTable, completionCallbackRef: Int32) {
        let panel = HSChooser.createChooserWindow()
        super.init(window: panel)

        self.refTable = refTable
        self.selfRefCount = 0

        self.eventMonitors = NSMutableArray()

        // Set our defaults
        self.numRows = 10
        self.width = 40
        self.fontName = nil
        self.fontSize = 0
        self.searchSubText = false

        // Set ivars directly to avoid triggering didSet
        self.fgColor = nil
        self.subTextColor = nil

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
        if fontName == nil {
            font = NSFont.systemFont(ofSize: fontSize)
        } else {
            font = NSFont(name: fontName!, size: fontSize)
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

        return panel
    }

    private func buildWindowContents() {
        guard let panel = self.window as? HSChooserWindow else { return }
        panel.delegate = self

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
        self.effectView = effectView

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
        queryField.textColor = NSColor.controlTextColor
        queryField.backgroundColor = NSColor.textBackgroundColor
        queryField.isBordered = false
        queryField.isBezeled = false
        queryField.drawsBackground = false
        queryField.isEditable = true
        queryField.isSelectable = true
        queryField.usesSingleLineMode = true
        queryField.cell?.isScrollable = true
        queryField.cell?.lineBreakMode = .byClipping
        queryField.setContentHuggingPriority(NSLayoutConstraint.Priority(750),
                                             for: .vertical)
        effectView.addSubview(queryField)
        self.queryField = queryField

        // --- Separator line ---
        let separator = NSBox(frame: .zero)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.setContentHuggingPriority(NSLayoutConstraint.Priority(750),
                                            for: .vertical)
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
        tableView.backgroundColor = NSColor(srgbRed: 0.0, green: 0.41176470588,
                                            blue: 0.85098039216, alpha: 0.0)
        tableView.gridColor = NSColor(white: 0.8, alpha: 0.0)
        tableView.setContentHuggingPriority(NSLayoutConstraint.Priority(750),
                                            for: .vertical)

        // Create the single table column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.isEditable = false
        column.width = 487
        column.minWidth = 40
        column.maxWidth = 99000
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        // Ensure header is hidden
        tableView.headerView = nil

        scrollView.documentView = tableView
        effectView.addSubview(scrollView)
        self.choicesTableView = tableView

        // --- Auto Layout constraints matching the XIB ---
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
    }

    // MARK: - Window related methods

    func windowDidBecomeKey(_ notification: Notification) {
        weak let _self = self
        weak let _tableView = choicesTableView
        weak let _window = window

        if reloadWhenVisible {
            choicesTableView.reloadData()
            reloadWhenVisible = false
        }

        addShortcut("1", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 0) }
        addShortcut("2", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 1) }
        addShortcut("3", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 2) }
        addShortcut("4", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 3) }
        addShortcut("5", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 4) }
        addShortcut("6", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 5) }
        addShortcut("7", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 6) }
        addShortcut("8", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 7) }
        addShortcut("9", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 8) }
        addShortcut("0", keyCode: UInt16.max, mods: .command) { _self?.tableView(_tableView!, didClickedRow: 9) }

        addShortcut("Escape", keyCode: 27, mods: []) { _window?.resignKey() }

        let fnNumPad: NSEvent.ModifierFlags = [.function, .numericPad]
        addShortcut("Up", keyCode: UInt16(NSUpArrowFunctionKey), mods: fnNumPad) { _self?.selectPreviousChoice() }
        addShortcut("Down", keyCode: UInt16(NSDownArrowFunctionKey), mods: fnNumPad) { _self?.selectNextChoice() }
        addShortcut("p", keyCode: UInt16.max, mods: .control) { _self?.selectPreviousChoice() }
        addShortcut("n", keyCode: UInt16.max, mods: .control) { _self?.selectNextChoice() }

        addShortcut("PageUp", keyCode: UInt16(NSPageUpFunctionKey), mods: .function) { _self?.selectPreviousPage() }
        addShortcut("PageDown", keyCode: UInt16(NSPageDownFunctionKey), mods: .function) { _self?.selectNextPage() }
        addShortcut("v", keyCode: UInt16.max, mods: .control) { _self?.selectNextPage() }
    }

    func windowDidResignKey(_ notification: Notification) {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAllObjects()

        if !hasChosen {
            cancel(nil)
        }
    }

    @objc func calculateRects() {
        var winR = NSRect(x: 0, y: 0, width: 100, height: 100)
        let contentViewRect = winR.insetBy(dx: 10, dy: 10)

        var textR = NSRect.zero
        var listR = NSRect.zero
        var dividerR = NSRect.zero
        var remainder = NSRect.zero

        NSDivideRect(contentViewRect, &textR, &listR, font.boundingRectForFont.height, .maxY)
        NSDivideRect(listR, &dividerR, &remainder, 20.0, .maxY)
        listR = remainder
        dividerR.origin.y += dividerR.height / 2.0
        dividerR.size.height = 1.0

        self.winRect = winR
        self.textRect = textR
        self.listRect = listR
        self.dividerRect = dividerR
    }

    @objc func setupWindow() -> Bool {
        guard window != nil else {
            os_log(.error, "ERROR: Unable to create hs.chooser window")
            return false
        }

        // Build the window's view hierarchy
        buildWindowContents()

        // Configure delegates and actions
        choicesTableView.delegate = self
        choicesTableView.extendedDelegate = self
        choicesTableView.dataSource = self
        choicesTableView.target = self

        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(queryDidPressEnter(_:))

        queryField.focusRingType = .none
        setAutoBgLightDark()

        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            // User hit cmd-enter
            queryDidPressEnter(self)
            return true
        } else if commandSelector == #selector(NSTextView.insertLineBreak(_:)) {
            // User hit option-enter
            queryDidPressEnter(self)
            return true
        }
        return false
    }

    @objc func resizeWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let rowHeight = choicesTableView.rowHeight
        let intercellHeight = choicesTableView.intercellSpacing.height
        let allRowsHeight = (rowHeight + intercellHeight) * CGFloat(numRows)

        var toolbarHeight: CGFloat = 0.0
        if let toolbar = window?.toolbar, toolbar.isVisible {
            let windowFrame = NSWindow.contentRect(forFrameRect: window!.frame,
                                                   styleMask: window!.styleMask)
            toolbarHeight = windowFrame.height - (window!.contentView?.frame.height ?? 0)
        }

        let windowHeight = window!.contentView!.bounds.height
        let tableHeight = choicesTableView.superview?.frame.height ?? 0
        let finalHeight = (windowHeight - tableHeight) + allRowsHeight + toolbarHeight

        var calcWidth: CGFloat
        if width >= 0 && width <= 100 {
            let percentWidth = width / 100.0
            calcWidth = screenFrame.width * percentWidth
        } else {
            calcWidth = screenFrame.width * 0.50
            calcWidth = min(calcWidth, 800)
            calcWidth = max(calcWidth, 400)
        }

        let winR = NSRect(x: 0, y: 0, width: calcWidth, height: finalHeight)
        window?.setFrame(winR, display: true)
        choicesTableView.setFrameSize(NSSize(width: winR.width,
                                             height: choicesTableView.frame.height))
    }

    @objc func showAtPoint(_ topLeft: NSPoint) {
        showWithHints(false, atPoint: topLeft)
    }

    @objc func show() {
        showWithHints(true, atPoint: .zero)
    }

    @objc func showWithHints(_ center: Bool, atPoint topLeft: NSPoint) {
        hasChosen = false

        // Call hs.chooser.globalCallback("willShow")
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!
        _lua_stackguard_entry(L)
        skin.requireModule("hs.chooser")
        lua_getfield(L, -1, "globalCallback")
        lua_remove(L, -2)

        // Check the type of `globalCallback`
        if lua_type(L, -1) == LUA_TNIL {
            lua_remove(L, -1)
        } else if lua_type(L, -1) != LUA_TFUNCTION {
            skin.logError("hs.chooser.globalCallback is expected to be a function, but is a \(String(cString: lua_typename(L, lua_type(L, -1))))")
            lua_remove(L, -1)
        } else {
            skin.pushNSObject(self)
            lua_pushstring(L, "willOpen")
            skin.protectedCallAndError("hs.chooser.globalCallback willOpen", nargs: 2, nresults: 0)
        }

        resizeWindow()

        showWindow(self)
        window?.orderFront(nil)

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
        _lua_stackguard_exit(skin.l)
    }

    @objc func hide() {
        window?.orderOut(nil)

        // Call hs.chooser.globalCallback("didClose")
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!
        _lua_stackguard_entry(L)
        skin.requireModule("hs.chooser")
        lua_getfield(L, -1, "globalCallback")
        lua_remove(L, -2)

        // Check the type of `globalCallback`
        if lua_type(L, -1) == LUA_TNIL {
            lua_remove(L, -1)
        } else if lua_type(L, -1) != LUA_TFUNCTION {
            skin.logError("hs.chooser.globalCallback is expected to be a function, but is a \(String(cString: lua_typename(L, lua_type(L, -1))))")
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

    @objc var isVisible: Bool {
        return window?.isVisible ?? false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return getChoices()?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let choices = getChoices(),
              row < choices.count,
              let choice = choices[row] as? NSDictionary else { return nil }

        var text: Any? = choice["text"]
        var subText: Any? = choice["subText"]
        var shortcutText: String = ""
        var image: NSImage? = choice["image"] as? NSImage

        if let t = text, !(t is String) && !(t is NSAttributedString) {
            text = "\(t)"
        }
        if let st = subText, !(st is String) && !(st is NSAttributedString) {
            subText = "\(st)"
        }
        if row >= 0 && row < 9 {
            shortcutText = "\u{2318}\(row + 1)"
        } else {
            shortcutText = ""
        }

        let hasSubText = subText != nil
        let chooserCellIdentifier = hasSubText ? "HSChooserCellSubtext" : "HSChooserCell"
        let cellIdentifier = NSUserInterfaceItemIdentifier(chooserCellIdentifier)
        var cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? HSChooserCell

        if cellView == nil {
            if hasSubText {
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

        if hasSubText {
            if let attrSubText = subText as? NSAttributedString {
                cell.subText?.attributedStringValue = attrSubText
            } else {
                cell.subText?.stringValue = (subText as? String) ?? ""
            }
        }

        cell.shortcutText.stringValue = shortcutText.isEmpty ? "" : shortcutText
        cell.iconView.image = image ?? NSImage(named: NSImage.followLinkFreestandingTemplateName)

        if let fg = fgColor {
            cell.text.textColor = fg
            cell.shortcutText.textColor = fg
        }

        if let stc = subTextColor {
            cell.subText?.textColor = stc
        }

        return cell
    }

    // MARK: - Programmatic cell construction

    private func makeSubtextCell(withIdentifier identifier: String) -> HSChooserCell {
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
        cell.iconView = imageView
        cell.imageView = imageView

        // --- Main text field (15pt system) ---
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
        textField.textColor = NSColor.secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = true
        textField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        textField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        cell.addSubview(textField)
        cell.text = textField

        // --- Subtext field ---
        let subTextField = NSTextField(frame: .zero)
        subTextField.translatesAutoresizingMaskIntoConstraints = false
        subTextField.tag = -1
        subTextField.isBordered = false
        subTextField.isBezeled = false
        subTextField.drawsBackground = false
        subTextField.isEditable = false
        subTextField.isSelectable = false
        subTextField.allowsExpansionToolTips = true
        subTextField.font = NSFont(name: NSFont.systemFont(ofSize: 0).fontName,
                                   size: NSFont.smallSystemFontSize)
        subTextField.textColor = NSColor.tertiaryLabelColor
        subTextField.lineBreakMode = .byTruncatingMiddle
        subTextField.cell?.truncatesLastVisibleLine = true
        subTextField.cell?.sendsActionOnEndEditing = true
        subTextField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        subTextField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        cell.addSubview(subTextField)
        cell.subText = subTextField

        // --- Shortcut text field (25pt, vertically centering cell) ---
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
        shortcutField.textColor = NSColor.secondaryLabelColor
        shortcutField.alignment = .left
        shortcutField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1000), for: .vertical)
        shortcutField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        cell.addSubview(shortcutField)
        cell.shortcutText = shortcutField

        // --- Constraints matching XIB "HSChooserCellSubtext" ---
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cell.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

            textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),

            subTextField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            cell.bottomAnchor.constraint(equalTo: subTextField.bottomAnchor, constant: 3),

            textField.bottomAnchor.constraint(equalTo: subTextField.topAnchor, constant: 2),

            shortcutField.widthAnchor.constraint(equalToConstant: 40),
            shortcutField.heightAnchor.constraint(equalToConstant: 40),
            cell.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor),
            shortcutField.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

            shortcutField.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 5),
            shortcutField.leadingAnchor.constraint(equalTo: subTextField.trailingAnchor, constant: 5),
        ])

        return cell
    }

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
        cell.iconView = imageView
        cell.imageView = imageView

        // --- Main text field (20pt, vertically centering cell) ---
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
        textField.textColor = NSColor.secondaryLabelColor
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
        shortcutField.textColor = NSColor.secondaryLabelColor
        shortcutField.alignment = .left
        shortcutField.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .vertical)
        shortcutField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1000), for: .vertical)
        cell.addSubview(shortcutField)
        cell.shortcutText = shortcutField

        // --- Constraints matching XIB "HSChooserCell" ---
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cell.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

            textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            cell.bottomAnchor.constraint(equalTo: textField.bottomAnchor, constant: 5),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),

            shortcutField.widthAnchor.constraint(equalToConstant: 40),
            shortcutField.heightAnchor.constraint(equalToConstant: 40),
            cell.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor),
            shortcutField.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

            shortcutField.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 5),
        ])

        return cell
    }

    // MARK: - HSChooserTableViewDelegate

    @objc func tableView(_ tableView: NSTableView, didClickedRow row: Int) {
        let choices = getChoices()
        let choiceCount = choices?.count ?? 0

        if row >= 0 && row < choiceCount {
            hasChosen = true
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            let choice = choices![row] as! NSDictionary

            if let valid = choice["valid"], !(valid as AnyObject).boolValue,
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

            _lua_stackguard_exit(skin.l)
        } else if enableDefaultForQuery && completionCallbackRef != LUA_NOREF && completionCallbackRef != LUA_REFNIL {
            // No row remaining in choices, return just query
            hasChosen = true
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            let choice: NSDictionary = ["text": queryField.stringValue]
            hide()
            skin.pushLuaRef(refTable, ref: completionCallbackRef)
            skin.pushNSObject(choice)
            skin.protectedCallAndError("hs.chooser:completionCallback", nargs: 1, nresults: 0)

            _lua_stackguard_exit(skin.l)
        }
    }

    @objc func didRightClick(atRow row: Int) {
        if rightClickCallbackRef != LUA_NOREF && rightClickCallbackRef != LUA_REFNIL {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: rightClickCallbackRef)
            lua_pushinteger(skin.l, lua_Integer(row + 1))
            skin.protectedCallAndError("hs.chooser:rightClickCallback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }

    // MARK: - UI callbacks

    @IBAction func cancel(_ sender: Any?) {
        hide()
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)

        if completionCallbackRef == LUA_NOREF || completionCallbackRef == LUA_REFNIL {
            skin.logWarn("Unable to call hs.chooser:completionCallback, reference is no longer valid")
            _lua_stackguard_exit(skin.l)
            return
        }

        skin.pushLuaRef(refTable, ref: completionCallbackRef)
        lua_pushnil(skin.l)
        skin.protectedCallAndError("hs.chooser:completionCallback", nargs: 1, nresults: 0)
        _lua_stackguard_exit(skin.l)
    }

    @IBAction @objc func queryDidPressEnter(_ sender: Any?) {
        tableView(choicesTableView, didClickedRow: choicesTableView.selectedRow)
    }

    @objc func controlTextDidChange(_ aNotification: Notification) {
        let queryString = queryField.stringValue

        if queryChangedCallbackRef != LUA_NOREF && queryChangedCallbackRef != LUA_REFNIL {
            // We have a query callback set
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: queryChangedCallbackRef)
            skin.pushNSObject(queryString as NSString)
            skin.protectedCallAndError("hs.chooser:queryChangedCallback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(skin.l)
        } else {
            // We do not have a query callback set, so we are doing the filtering
            if !queryString.isEmpty {
                let filtered = NSMutableArray()

                if let allChoices = getChoicesWithOptions(false) {
                    for item in allChoices {
                        guard let choice = item as? NSDictionary else { continue }
                        var text = choice["text"]
                        if let t = text, !(t is String) { text = "\(t)" }
                        let textStr = (text as? String) ?? ""

                        if textStr.lowercased().contains(queryString.lowercased()) {
                            filtered.add(choice)
                        } else if searchSubText {
                            var subText = choice["subText"]
                            if let st = subText, !(st is String) { subText = "\(st)" }
                            let subTextStr = (subText as? String) ?? ""
                            if subTextStr.lowercased().contains(queryString.lowercased()) {
                                filtered.add(choice)
                            }
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

    @objc func selectChoice(_ row: Int) {
        let numRows = getChoices()?.count ?? 0
        if row < 0 || row > numRows - 1 {
            LuaSkin.skin(with: nil).logError("ERROR: unable to select row \(row) of \(numRows)")
            return
        }
        choicesTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        choicesTableView.scrollRowToVisible(row)
    }

    @objc func selectNextChoice() {
        var currentRow = choicesTableView.selectedRow
        let count = getChoices()?.count ?? 0
        if currentRow == count - 1 {
            currentRow = -1
        }
        selectChoice(currentRow + 1)
    }

    @objc func selectPreviousChoice() {
        var currentRow = choicesTableView.selectedRow
        let count = getChoices()?.count ?? 0
        if currentRow == 0 {
            currentRow = count
        }
        selectChoice(currentRow - 1)
    }

    @objc func selectNextPage() {
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

    @objc func selectPreviousPage() {
        let currentRow = choicesTableView.selectedRow
        let count = getChoices()?.count ?? 0
        if currentRow == 0 {
            selectChoice(count - 1)
        } else if currentRow < 10 {
            selectChoice(0)
        } else {
            selectChoice(currentRow - 10)
        }
    }

    // MARK: - Choice management methods

    @objc func updateChoices() {
        if window?.isVisible == true {
            choicesTableView.reloadData()
        } else {
            reloadWhenVisible = true
        }
    }

    @objc func clearChoices() {
        currentStaticChoices = nil
        currentCallbackChoices = nil
        filteredChoices = nil
    }

    @objc func clearChoicesAndUpdate() {
        clearChoices()
        updateChoices()
    }

    @objc func getChoices() -> NSArray? {
        return getChoicesWithOptions(true)
    }

    @objc func getChoicesWithOptions(_ includeFiltered: Bool) -> NSArray? {
        if includeFiltered, let filtered = filteredChoices {
            return filtered
        } else if choicesCallbackRef == LUA_NOREF {
            return currentStaticChoices
        } else if choicesCallbackRef != LUA_NOREF {
            if currentCallbackChoices == nil {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: choicesCallbackRef)
                if skin.protectedCallAndTraceback(0, nresults: 1) {
                    currentCallbackChoices = skin.toNSObject(atIndex: -1) as? NSArray

                    var callbackChoicesTypeCheckPass = false
                    if let arr = currentCallbackChoices {
                        callbackChoicesTypeCheckPass = true
                        for element in arr {
                            if !(element is NSDictionary) {
                                callbackChoicesTypeCheckPass = false
                                break
                            }
                        }
                    }
                    if !callbackChoicesTypeCheckPass {
                        LuaSkin.skin(with: nil).logError("ERROR: data returned by hs.chooser:choices() callback could not be parsed correctly")
                        currentCallbackChoices = nil
                    }
                } else {
                    let errMsg = skin.toNSObject(atIndex: -1)
                    skin.logError("hs.chooser:choices error - \(errMsg ?? "unknown")")
                }
                lua_pop(skin.l, 1)
                _lua_stackguard_exit(skin.l)
            }

            return currentCallbackChoices
        }

        return nil
    }

    // MARK: - UI customisation methods

    @objc func applyDarkSetting(_ beDark: Bool) {
        let appearance = beDark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        window?.appearance = appearance
    }

    @objc func setAutoBgLightDark() {
        let interfaceStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        let isDark = interfaceStyle?.lowercased() == "dark"
        applyDarkSetting(isDark)
    }

    @objc func setBgLightDark(_ notification: Notification) {
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

    @objc func isBgLightDark() -> Bool {
        return window?.appearance?.name == .vibrantDark
    }

    // MARK: - Utility methods

    private func addShortcut(_ key: String, keyCode: UInt16, mods: NSEvent.ModifierFlags, handler action: @escaping () -> Void) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == mods {
                do {
                    let chars = event.charactersIgnoringModifiers ?? ""
                    if chars == key || (!chars.isEmpty && chars.unicodeScalars.first!.value == UInt32(keyCode)) {
                        action()
                        return nil
                    }
                }
            }
            return event
        }
        if let monitor = monitor {
            eventMonitors.add(monitor)
        }
    }
}
