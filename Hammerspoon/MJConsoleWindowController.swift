import Cocoa

// MARK: - Console Dark Mode

@_cdecl("ConsoleDarkModeEnabled")
func ConsoleDarkModeEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: "HSConsoleDarkModeKey")
}

@_cdecl("ConsoleDarkModeSetEnabled")
func ConsoleDarkModeSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "HSConsoleDarkModeKey")
}

// MARK: - Console Always-On-Top

@_cdecl("MJConsoleWindowAlwaysOnTop")
func MJConsoleWindowAlwaysOnTop() -> Bool {
    UserDefaults.standard.bool(forKey: "MJKeepConsoleOnTopKey")
}

@_cdecl("MJConsoleWindowSetAlwaysOnTop")
func MJConsoleWindowSetAlwaysOnTop(_ alwaysOnTop: Bool) {
    UserDefaults.standard.set(alwaysOnTop, forKey: "MJKeepConsoleOnTopKey")
    MJConsoleWindowController.singleton().reflectDefaults()
}

// MARK: - MJReplLineType

private enum MJReplLineType: UInt {
    case command
    case result
    case stdout
}

// MARK: - MJConsoleWindowController

@objcMembers
class MJConsoleWindowController: NSWindowController, NSTextFieldDelegate {

    // MARK: Public properties (match header)

    var mjColorForStdout: NSColor = .black
    var mjColorForCommand: NSColor = .black
    var mjColorForResult: NSColor = .black
    var consoleFont: NSFont = NSFont.systemFont(ofSize: 12)
    var maxConsoleOutputHistory: NSNumber = NSNumber(value: 100_000)

    // MARK: Private properties

    private var history: [String] = []
    private var historyIndex: Int = 0
    private var outputView: NSTextView!
    private var inputField: NSTextField!
    private var preshownStdouts: [String] = []
    private var dateFormatter: DateFormatter = DateFormatter()
    private var outputBuffer: [NSAttributedString] = []
    private var outputTimer: Timer?

    // MARK: - Singleton

    private static var _singleton: MJConsoleWindowController?

    @objc static func singleton() -> MJConsoleWindowController {
        if let existing = _singleton {
            return existing
        }
        let instance = MJConsoleWindowController()
        _singleton = instance
        return instance
    }

    // MARK: - Init

    override init() {
        super.init(window: nil)

        let enUSPOSIX = Locale(identifier: "en_US_POSIX")
        dateFormatter.locale = enUSPOSIX
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        outputBuffer.reserveCapacity(1000)

        // Strings that we want to add to the console window are batched up in outputBuffer and this timer drains them
        outputTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, !self.outputBuffer.isEmpty else { return }

            autoreleasepool {
                let storage = self.outputView.textStorage!
                storage.beginEditing()

                for attrstr in self.outputBuffer {
                    let curLength = storage.length
                    let maxLength = self.maxConsoleOutputHistory.intValue
                    let addLength = attrstr.length

                    storage.append(attrstr)
                    if curLength > maxLength, maxLength > 0 {
                        storage.deleteCharacters(in: NSRange(location: 0, length: curLength - maxLength + addLength))
                    }
                }

                self.outputBuffer.removeAll()
                storage.endEditing()
                self.outputView.scrollToEndOfDocument(nil)
            }
        }
        RunLoop.main.add(outputTimer!, forMode: .common)

        initializeConsoleColorsAndFont()

        // NSWindowController -init calls -initWithWindow:nil which marks
        // isWindowLoaded=YES, preventing loadWindow from ever running.
        // Force it to run here.
        loadWindow()

        // Post-load setup (windowDidLoad equivalent)
        shouldCascadeWindows = false
        history = []
        appendString(
            "Welcome to the Hammerspoon Console!\n"
            + "You can run any Lua code in here.\n\n",
            type: .stdout
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Programmatic window construction

    override func loadWindow() {
        // --- Window ---
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let contentRect = NSRect(x: 916, y: 704, width: 510, height: 389)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )
        window.title = "Hammerspoon Console"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 200)
        window.frameAutosaveName = "console"
        window.collectionBehavior = .fullScreenPrimary
        window.animationBehavior = .default
        window.autorecalculatesKeyViewLoop = false
        window.allowsToolTipsWhenApplicationIsInactive = false

        let contentView = window.contentView!

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

        // Let the text view track the scroll view's clip width but grow vertically
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        contentView.addSubview(scrollView)
        outputView = textView

        // --- Input field ---
        let input = HSGrowingTextField(frame: .zero)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.font = NSFont(name: "Menlo-Regular", size: 12.0)
        input.textColor = .controlTextColor
        input.backgroundColor = .textBackgroundColor
        input.drawsBackground = true
        input.isBordered = true
        input.isBezeled = true
        input.bezelStyle = .squareBezel
        input.isEditable = true
        input.isSelectable = true
        input.focusRingType = .none
        input.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(250),
            for: .horizontal
        )
        input.target = self
        input.action = #selector(tryMessage(_:))
        input.delegate = self
        contentView.addSubview(input)
        inputField = input

        // --- Auto Layout constraints (matching XIB: 20pt margins, 8pt gap) ---
        NSLayoutConstraint.activate([
            // Scroll view edges
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // Input field edges
            input.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            input.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            // 8pt gap between scroll view bottom and input field top
            input.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
        ])

        window.initialFirstResponder = input
        self.window = window
    }

    // MARK: - Console colors and font

    @objc func initializeConsoleColorsAndFont() {
        mjColorForStdout = NSColor(calibratedHue: 0.88, saturation: 1.0, brightness: 0.6, alpha: 1.0)
        mjColorForCommand = .black
        mjColorForResult = NSColor(calibratedHue: 0.54, saturation: 1.0, brightness: 0.7, alpha: 1.0)
        consoleFont = NSFont(name: "Menlo", size: 12.0) ?? NSFont.systemFont(ofSize: 12.0)
        maxConsoleOutputHistory = NSNumber(value: 100_000)
    }

    // MARK: - Setup

    @objc func setup() {
        preshownStdouts = []
        MJLuaSetupLogHandler { [weak self] str in
            guard let self = self, let str = str else { return }
            if self.outputView != nil {
                self.appendString(str, type: .stdout)
                self.outputView.scrollToEndOfDocument(nil)
            } else {
                self.preshownStdouts.append(str)
            }
        }
        reflectDefaults()
    }

    // MARK: - Reflect defaults

    @objc func reflectDefaults() {
        // Dark Mode:
        if ConsoleDarkModeEnabled() {
            window?.appearance = NSAppearance(named: .vibrantDark)
            window?.titlebarAppearsTransparent = true
            outputView.enclosingScrollView?.drawsBackground = false
        } else {
            window?.appearance = NSAppearance(named: .vibrantLight)
            window?.titlebarAppearsTransparent = false
            outputView.enclosingScrollView?.drawsBackground = true
        }

        let level: NSWindow.Level = MJConsoleWindowAlwaysOnTop() ? .floating : .normal
        window?.level = level
    }

    // MARK: - Append string

    private func appendString(_ str: String?, type: MJReplLineType) {
        guard var str = str else { return }

        let color: NSColor
        switch type {
        case .stdout:  color = mjColorForStdout
        case .command: color = mjColorForCommand
        case .result:  color = mjColorForResult
        }

        if type == .stdout {
            str = "\(dateFormatter.string(from: Date())): \(str)"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: consoleFont,
            .foregroundColor: color,
        ]
        let attrstr = NSAttributedString(string: str, attributes: attrs)

        // We don't actually append the string immediately, it goes into a buffer that drains on a timer (see above)
        outputBuffer.append(attrstr)
    }

    // MARK: - Run command

    @objc func run(_ command: String) -> String {
        return MJLuaRunString(command) ?? ""
    }

    // MARK: - Try message (action from input field)

    @objc func tryMessage(_ sender: NSTextField) {
        let command = sender.stringValue
        appendString("\n> \(command)\n", type: .command)

        let result = run(command)
        appendString("\(result)\n", type: .result)

        sender.stringValue = ""
        (sender as? HSGrowingTextField)?.resetGrowth()

        saveToHistory(command)
        outputView.scrollToEndOfDocument(nil)
    }

    // MARK: - History

    private func saveToHistory(_ cmd: String) {
        history.append(cmd)
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
            inputField.stringValue = ""
        } else {
            inputField.stringValue = history[historyIndex]
        }

        if let editor = inputField.window?.fieldEditor(true, for: inputField) as? NSText {
            let length = editor.string.count
            editor.selectedRange = NSRange(location: length, length: 0)
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            goPrevHistory()
            return true
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            goNextHistory()
            return true
        } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
            inputField.currentEditor()?.complete(nil)
            return true
        }
        return false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let currentText = textView.string
        let nsText = currentText as NSString
        let textBeforeCursor = nsText.substring(to: NSMaxRange(charRange))
        let textAfterCursor = nsText.substring(from: NSMaxRange(charRange))
        let completionWord = nsText.substring(with: charRange)

        guard let completions = MJLuaCompletionsForWord(completionWord) as? [String] else {
            return []
        }

        if completions.count == 1 {
            // We have only one completion, so we should just insert it into the text field
            let completeWith = completions[0]
            var stringToAdd = ""

            if completeWith.hasPrefix(completionWord) {
                stringToAdd = String(completeWith.dropFirst(completionWord.count))
            }

            textView.string = "\(textBeforeCursor)\(stringToAdd)\(textAfterCursor)"
            textView.setSelectedRange(NSRange(
                location: NSMaxRange(charRange) + (stringToAdd as NSString).length,
                length: 0
            ))
            return []
        }

        return completions
    }
}
