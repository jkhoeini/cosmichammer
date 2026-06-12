import Cocoa

// MARK: - String constants (from variables.h)

private let HSConsoleDarkModeKey = "HSConsoleDarkModeKey"
private let MJKeepConsoleOnTopKey = "MJKeepConsoleOnTopKey"

// MARK: - C-visible functions (imported by ObjC via MJConsoleWindowController.h)

@_cdecl("ConsoleDarkModeEnabled")
public func ConsoleDarkModeEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: HSConsoleDarkModeKey)
}

@_cdecl("ConsoleDarkModeSetEnabled")
public func ConsoleDarkModeSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: HSConsoleDarkModeKey)
}

@_cdecl("MJConsoleWindowAlwaysOnTop")
public func MJConsoleWindowAlwaysOnTop() -> Bool {
    UserDefaults.standard.bool(forKey: MJKeepConsoleOnTopKey)
}

@_cdecl("MJConsoleWindowSetAlwaysOnTop")
public func MJConsoleWindowSetAlwaysOnTop(_ alwaysOnTop: Bool) {
    UserDefaults.standard.set(alwaysOnTop, forKey: MJKeepConsoleOnTopKey)
    MJConsoleWindowController.singleton().reflectDefaults()
}

// MJLuaSetupLogHandler, MJLuaRunString, MJLuaCompletionsForWord
// are now defined in LuaRuntime.swift (same module) — no @_silgen_name needed.

// MARK: - MJReplLineType

enum MJReplLineType {
    case command
    case result
    case stdout
}

// MARK: - MJConsoleWindowController

@objc(MJConsoleWindowController)
public class MJConsoleWindowController: NSWindowController, NSTextFieldDelegate {

    // MARK: Public properties (declared in .h)

    @objc public var MJColorForStdout: NSColor?
    @objc public var MJColorForCommand: NSColor?
    @objc public var MJColorForResult: NSColor?
    @objc public var consoleFont: NSFont?
    @objc public var maxConsoleOutputHistory: NSNumber?

    // MARK: Private properties

    @objc private var history: NSMutableArray = NSMutableArray()
    private var historyIndex: Int = 0
    @objc private var outputView: NSTextView?
    @objc private var inputField: NSTextField?
    private var preshownStdouts: [Any] = []
    private var dateFormatter: DateFormatter
    private var outputBuffer: [NSAttributedString]
    private var outputTimer: Timer?

    // MARK: Singleton

    public class func singleton() -> MJConsoleWindowController {
        return _shared
    }

    private static let _shared = MJConsoleWindowController()

    // MARK: Init

    public override init(window: NSWindow?) {
        let df = DateFormatter()
        let enUSPOSIX = Locale(identifier: "en_US_POSIX")
        df.locale = enUSPOSIX
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.dateFormatter = df
        self.outputBuffer = []
        self.outputBuffer.reserveCapacity(1000)

        super.init(window: window)

        // Start the drain timer
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, !self.outputBuffer.isEmpty else { return }
            autoreleasepool {
                guard let storage = self.outputView?.textStorage else { return }
                storage.beginEditing()
                let maxLength = self.maxConsoleOutputHistory?.intValue ?? 100000
                for attrStr in self.outputBuffer {
                    let curLength = storage.length
                    let addLength = attrStr.length
                    storage.append(attrStr)
                    if curLength > maxLength && maxLength > 0 {
                        storage.deleteCharacters(in: NSRange(location: 0, length: curLength - maxLength + addLength))
                    }
                }
                self.outputBuffer.removeAll()
                storage.endEditing()
                self.outputView?.scrollToEndOfDocument(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.outputTimer = timer

        initializeConsoleColorsAndFont()

        // NSWindowController.init(window:nil) marks isWindowLoaded = YES,
        // preventing loadWindow() from ever being called automatically.
        // Force it here.
        loadWindow()

        // Post-load setup (equivalent to windowDidLoad)
        shouldCascadeWindows = false
        history = NSMutableArray()
        appendString("\nWelcome to the Cosmic Hammer Console!\nYou can run any Lua code in here.\n\n",
                     type: .stdout)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for MJConsoleWindowController")
    }

    // MARK: - Programmatic window construction

    public override func loadWindow() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let contentRect = NSRect(x: 916, y: 704, width: 510, height: 389)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )
        window.title = "Cosmic Hammer Console"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 200)
        window.setFrameAutosaveName("console")
        window.collectionBehavior = .fullScreenPrimary
        window.animationBehavior = .default
        window.autorecalculatesKeyViewLoop = false
        window.allowsToolTipsWhenApplicationIsInactive = false

        guard let contentView = window.contentView else { return }

        // --- ScrollView + TextView (output) ---
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = true
        scrollView.contentView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.usesFindBar = true
        textView.allowsCharacterPickerTouchBarItem = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor

        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        contentView.addSubview(scrollView)
        self.outputView = textView

        // --- Input field (HSGrowingTextField) ---
        let inputField = HSGrowingTextField(frame: .zero)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.font = NSFont(name: "Menlo-Regular", size: 12.0)
        inputField.textColor = .controlTextColor
        inputField.backgroundColor = .textBackgroundColor
        inputField.drawsBackground = true
        inputField.isBordered = true
        inputField.isBezeled = true
        inputField.bezelStyle = .squareBezel
        inputField.isEditable = true
        inputField.isSelectable = true
        inputField.focusRingType = .none
        inputField.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 250),
            for: .horizontal
        )
        inputField.target = self
        inputField.action = #selector(tryMessage(_:))
        inputField.delegate = self
        contentView.addSubview(inputField)
        self.inputField = inputField

        // --- Auto Layout constraints ---
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            inputField.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            inputField.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            inputField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            inputField.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
        ])

        window.initialFirstResponder = inputField
        self.window = window
    }

    // MARK: - Public API

    public func initializeConsoleColorsAndFont() {
        MJColorForStdout  = NSColor(calibratedHue: 0.88, saturation: 1.0, brightness: 0.6, alpha: 1.0)
        MJColorForCommand = .black
        MJColorForResult  = NSColor(calibratedHue: 0.54, saturation: 1.0, brightness: 0.7, alpha: 1.0)
        consoleFont       = NSFont(name: "Menlo", size: 12.0)
        maxConsoleOutputHistory = NSNumber(value: 100000)
    }

    public func setup() {
        preshownStdouts = []
        MJLuaSetupLogHandler { [weak self] str in
            guard let self = self else { return }
            if self.outputView != nil {
                self.appendString(str as String, type: .stdout)
                self.outputView?.scrollToEndOfDocument(self)
            } else {
                self.preshownStdouts.append(str)
            }
        }
        reflectDefaults()
    }

    public func reflectDefaults() {
        if ConsoleDarkModeEnabled() {
            window?.appearance = NSAppearance(named: .vibrantDark)
            window?.titlebarAppearsTransparent = true
            outputView?.enclosingScrollView?.drawsBackground = false
        } else {
            window?.appearance = NSAppearance(named: .vibrantLight)
            window?.titlebarAppearsTransparent = false
            outputView?.enclosingScrollView?.drawsBackground = true
        }
        window?.level = MJConsoleWindowAlwaysOnTop() ? .floating : .normal
    }

    // MARK: - Internal helpers

    private func appendString(_ str: String, type: MJReplLineType) {
        var color = MJColorForStdout ?? .textColor
        switch type {
        case .stdout:  color = MJColorForStdout  ?? .textColor
        case .command: color = MJColorForCommand ?? .textColor
        case .result:  color = MJColorForResult  ?? .textColor
        }

        var displayStr = str
        if type == .stdout {
            let dateStr = dateFormatter.string(from: Date())
            displayStr = "\(dateStr): \(str)"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: consoleFont ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: color,
        ]
        let attrStr = NSAttributedString(string: displayStr, attributes: attrs)
        outputBuffer.append(attrStr)
    }

    private func run(_ command: String) -> String {
        return MJLuaRunString(command as NSString) as String
    }

    @objc private func tryMessage(_ sender: NSTextField) {
        let command = sender.stringValue
        appendString("\n> \(command)\n", type: .command)

        let result = run(command)
        appendString("\(result)\n", type: .result)

        sender.stringValue = ""
        (sender as? HSGrowingTextField)?.resetGrowth()

        saveToHistory(command)
        outputView?.scrollToEndOfDocument(self)
    }

    private func saveToHistory(_ cmd: String) {
        history.add(cmd)
        historyIndex = history.count
        useCurrentHistoryIndex()
    }

    private func goPrevHistory() {
        historyIndex = max(historyIndex - 1, 0)
        useCurrentHistoryIndex()
    }

    private func goNextHistory() {
        historyIndex = min(historyIndex + 1, history.count)
        useCurrentHistoryIndex()
    }

    private func useCurrentHistoryIndex() {
        (inputField as? HSGrowingTextField)?.resetGrowth()

        if historyIndex == history.count {
            inputField?.stringValue = ""
        } else {
            inputField?.stringValue = (history[historyIndex] as? String) ?? ""
        }

        if let win = inputField?.window,
           let editor = win.fieldEditor(true, for: inputField) {
            let length = editor.string.count
            editor.selectedRange = NSRange(location: length, length: 0)
        }
    }

    // MARK: - NSTextFieldDelegate

    @objc public func control(_ control: NSControl,
                              textView: NSTextView,
                              doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.moveUp(_:)) {
            goPrevHistory()
            return true
        } else if command == #selector(NSResponder.moveDown(_:)) {
            goNextHistory()
            return true
        } else if command == #selector(NSResponder.insertTab(_:)) {
            inputField?.currentEditor()?.complete(nil)
            return true
        }
        return false
    }

    @objc public func control(_ control: NSControl,
                              textView: NSTextView,
                              completions words: [String],
                              forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        let currentText = textView.string
        let nsCurrentText = currentText as NSString
        let maxRange = NSMaxRange(charRange)
        let textBeforeCursor = nsCurrentText.substring(to: maxRange)
        let textAfterCursor  = nsCurrentText.substring(from: maxRange)
        let completionWord   = nsCurrentText.substring(with: charRange)

        let completions = (MJLuaCompletionsForWord(completionWord as NSString) as? [String]) ?? []

        if completions.count == 1 {
            let completeWith = completions[0]
            var stringToAdd = ""
            if completeWith.hasPrefix(completionWord) {
                let startIdx = completeWith.index(completeWith.startIndex,
                                                  offsetBy: completionWord.count)
                stringToAdd = String(completeWith[startIdx...])
            }
            textView.string = "\(textBeforeCursor)\(stringToAdd)\(textAfterCursor)"
            textView.setSelectedRange(NSRange(location: maxRange + stringToAdd.count, length: 0))
            return []
        }
        return completions
    }
}
