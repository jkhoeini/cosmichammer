import Cocoa

// MARK: - String constants (from variables.h)

private let MJShowDockIconKey           = "MJShowDockIconKey"
private let MJShowMenuIconKey           = "MJShowMenuIconKey"
private let HSAutoLoadExtensions        = "HSAutoLoadExtensions"
private let HSAppleScriptEnabledKey     = "HSAppleScriptEnabledKey"
private let HSOpenConsoleOnDockClickKey = "HSOpenConsoleOnDockClickKey"
private let HSPreferencesDarkModeKey    = "HSPreferencesDarkModeKey"
private let MJHasRunAlreadyKey          = "MJHasRunAlreadyKey"
private let MJSkipDockMenuIconProblemAlertKey = "MJSkipDockMenuIconProblemAlertKey"

// MARK: - Preferences dark mode C interface (declared in MJPreferencesWindowController.h)

@_cdecl("PreferencesDarkModeEnabled")
func PreferencesDarkModeEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: HSPreferencesDarkModeKey)
}

@_cdecl("PreferencesDarkModeSetEnabled")
func PreferencesDarkModeSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: HSPreferencesDarkModeKey)
}

// MARK: - MJPreferencesWindowController

@objc(MJPreferencesWindowController)
class MJPreferencesWindowController: NSWindowController {

    // MARK: Private UI outlets
    private var openAtLoginCheckbox: NSButton!
    private var showDockIconCheckbox: NSButton!
    private var showMenuIconCheckbox: NSButton!
    private var keepConsoleOnTopCheckbox: NSButton!

    // MARK: KVO-observable accessibility state
    @objc dynamic var isAccessibilityEnabled: Bool = false {
        didSet {
            // KVO-driven bindings on statusText/enableAccessButton update automatically
        }
    }

    // MARK: Singleton

    @objc class func singleton() -> MJPreferencesWindowController {
        struct S { static let instance = MJPreferencesWindowController() }
        return S.instance
    }

    // MARK: Init

    @objc override init(window: NSWindow?) {
        super.init(window: window)
        loadWindow()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Setup

    @objc func setup() {
        reflectDefaults()
    }

    // MARK: - reflectDefaults

    @objc func reflectDefaults() {
        if PreferencesDarkModeEnabled() {
            window?.appearance = NSAppearance(named: .vibrantDark)
            window?.titlebarAppearsTransparent = true
        } else {
            window?.appearance = NSAppearance(named: .vibrantLight)
            window?.titlebarAppearsTransparent = false
        }
    }

    // MARK: - showWindow

    @objc override func showWindow(_ sender: Any?) {
        if window?.isVisible == false {
            window?.center()
        }
        super.showWindow(sender)
        reflectDefaults()
    }

    // MARK: - loadWindow

    override func loadWindow() {
        // --- Panel ---
        let panel = NSPanel(
            contentRect: NSRect(x: 957, y: 580, width: 357, height: 246),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Cosmic Hammer Preferences"
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("prefs")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.animationBehavior = .default

        // --- Visual effect view as the content view ---
        let effectView = NSVisualEffectView(frame: panel.contentView!.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.material = .underWindowBackground
        effectView.state = .followsWindowActiveState
        effectView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = panel.contentView!
        contentView.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // --- "Behavior:" label ---
        let behaviorLabel = NSTextField(labelWithString: "Behavior:")
        behaviorLabel.translatesAutoresizingMaskIntoConstraints = false
        behaviorLabel.alignment = .right
        behaviorLabel.font = NSFont.systemFont(ofSize: 0)
        effectView.addSubview(behaviorLabel)

        // --- Checkboxes ---
        let openAtLogin = NSButton(checkboxWithTitle: "Launch Cosmic Hammer at login",
                                   target: self,
                                   action: #selector(toggleOpensAtLogin(_:)))
        openAtLogin.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(openAtLogin)
        self.openAtLoginCheckbox = openAtLogin

        let showDock = NSButton(checkboxWithTitle: "Show dock icon",
                                target: self,
                                action: #selector(toggleShowDockIcon(_:)))
        showDock.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(showDock)
        self.showDockIconCheckbox = showDock

        let showMenu = NSButton(checkboxWithTitle: "Show menu icon",
                                target: self,
                                action: #selector(toggleMenuDockIcon(_:)))
        showMenu.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(showMenu)
        self.showMenuIconCheckbox = showMenu

        let keepOnTop = NSButton(checkboxWithTitle: "Keep Console window on top",
                                 target: self,
                                 action: #selector(toggleKeepConsoleOnTop(_:)))
        keepOnTop.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(keepOnTop)
        self.keepConsoleOnTopCheckbox = keepOnTop

        // --- "Accessibility:" label ---
        let accessibilityLabel = NSTextField(labelWithString: "Accessibility:")
        accessibilityLabel.translatesAutoresizingMaskIntoConstraints = false
        accessibilityLabel.alignment = .right
        accessibilityLabel.font = NSFont.systemFont(ofSize: 0)
        effectView.addSubview(accessibilityLabel)

        // --- Accessibility status text (bound via KVC) ---
        let statusText = NSTextField(labelWithString: "")
        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusText.font = NSFont.systemFont(ofSize: 0)
        statusText.bind(.value, to: self, withKeyPath: "maybeEnableAccessibilityString", options: nil)
        effectView.addSubview(statusText)

        // --- "Enable Accessibility" button (bound via KVC) ---
        let enableAccessButton = NSButton(frame: .zero)
        enableAccessButton.translatesAutoresizingMaskIntoConstraints = false
        enableAccessButton.title = "Enable Accessibility"
        enableAccessButton.bezelStyle = .rounded
        enableAccessButton.target = self
        enableAccessButton.action = #selector(openAccessibility(_:))
        enableAccessButton.bind(.enabled, to: self, withKeyPath: "isAccessibilityEnabled",
                                options: [NSBindingOption.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName])
        effectView.addSubview(enableAccessButton)

        // --- Status dot image view (bound via KVC) ---
        let statusDot = NSImageView(frame: .zero)
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.bind(.value, to: self, withKeyPath: "isAccessibilityEnabledImage", options: nil)
        effectView.addSubview(statusDot)

        // --- Auto Layout constraints ---
        NSLayoutConstraint.activate([
            // "Behavior:" label — top-left
            behaviorLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 20),
            behaviorLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),

            // First checkbox aligns baseline with "Behavior:" label, 8pt after label trailing
            openAtLogin.bottomAnchor.constraint(equalTo: behaviorLabel.bottomAnchor, constant: -1),
            openAtLogin.leadingAnchor.constraint(equalTo: behaviorLabel.trailingAnchor, constant: 8),

            // Remaining checkboxes stack vertically with 6pt spacing
            showDock.topAnchor.constraint(equalTo: openAtLogin.bottomAnchor, constant: 6),
            showDock.leadingAnchor.constraint(equalTo: behaviorLabel.trailingAnchor, constant: 8),

            showMenu.topAnchor.constraint(equalTo: showDock.bottomAnchor, constant: 6),
            showMenu.leadingAnchor.constraint(equalTo: behaviorLabel.trailingAnchor, constant: 8),

            keepOnTop.topAnchor.constraint(equalTo: showMenu.bottomAnchor, constant: 6),
            keepOnTop.leadingAnchor.constraint(equalTo: behaviorLabel.trailingAnchor, constant: 8),

            // "Accessibility:" label — below last checkbox, right-aligned with "Behavior:" label
            accessibilityLabel.topAnchor.constraint(equalTo: keepOnTop.bottomAnchor, constant: 8),
            accessibilityLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),
            accessibilityLabel.trailingAnchor.constraint(equalTo: behaviorLabel.trailingAnchor),

            // Status text vertically centered with "Accessibility:" label
            statusText.centerYAnchor.constraint(equalTo: accessibilityLabel.centerYAnchor),
            statusText.leadingAnchor.constraint(equalTo: accessibilityLabel.trailingAnchor, constant: 8),
            statusText.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),

            // "Enable Accessibility" button below status text, aligned to its leading
            enableAccessButton.topAnchor.constraint(equalTo: statusText.bottomAnchor, constant: 8),
            enableAccessButton.leadingAnchor.constraint(equalTo: statusText.leadingAnchor),
            enableAccessButton.widthAnchor.constraint(equalToConstant: 200),

            // Status dot centered vertically with the button, 8pt to its right
            statusDot.centerYAnchor.constraint(equalTo: enableAccessButton.centerYAnchor),
            statusDot.leadingAnchor.constraint(equalTo: enableAccessButton.trailingAnchor, constant: 8),
            statusDot.widthAnchor.constraint(equalToConstant: 16),
            statusDot.heightAnchor.constraint(equalToConstant: 16),
        ])

        // --- Assign the window ---
        self.window = panel

        // --- Post-load setup ---
        DispatchQueue.main.async {
            self.cacheIsAccessibilityEnabled()
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityChanged(_:)),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )

        openAtLoginCheckbox.state = MJAutoLaunchGet() ? .on : .off
        showDockIconCheckbox.state = MJDockIconVisible() ? .on : .off
        showMenuIconCheckbox.state = MJMenuIconVisible() ? .on : .off
        keepConsoleOnTopCheckbox.state = MJConsoleWindowAlwaysOnTop() ? .on : .off

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateFeedbackDisplay(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Notification handlers

    @objc func accessibilityChanged(_ note: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.cacheIsAccessibilityEnabled()
        }
    }

    @objc func updateFeedbackDisplay(_ notification: Notification) {
        DispatchQueue.main.async {
            self.openAtLoginCheckbox.state = MJAutoLaunchGet() ? .on : .off
            self.showDockIconCheckbox.state = MJDockIconVisible() ? .on : .off
            self.showMenuIconCheckbox.state = MJMenuIconVisible() ? .on : .off
            self.keepConsoleOnTopCheckbox.state = MJConsoleWindowAlwaysOnTop() ? .on : .off
        }
    }

    // MARK: - Accessibility helpers

    @objc func cacheIsAccessibilityEnabled() {
        isAccessibilityEnabled = MJAccessibilityIsEnabled()
    }

    @objc var maybeEnableAccessibilityString: String {
        isAccessibilityEnabled
            ? "Accessibility is enabled. You're all set!"
            : "WARNING! Accessibility is not enabled!"
    }

    @objc var isAccessibilityEnabledImage: NSImage? {
        NSImage(named: isAccessibilityEnabled ? NSImage.statusAvailableName : NSImage.statusUnavailableName)
    }

    @objc class func keyPathsForValuesAffectingMaybeEnableAccessibilityString() -> NSSet {
        NSSet(array: ["isAccessibilityEnabled"])
    }

    @objc class func keyPathsForValuesAffectingIsAccessibilityEnabledImage() -> NSSet {
        NSSet(array: ["isAccessibilityEnabled"])
    }

    // MARK: - Actions

    @objc func openAccessibility(_ sender: Any?) {
        MJAccessibilityOpenPanel()
    }

    @objc func toggleOpensAtLogin(_ sender: NSButton) {
        MJAutoLaunchSet(sender.state == .on)
    }

    @objc func toggleShowDockIcon(_ sender: NSButton) {
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                              selector: #selector(actuallyToggleShowDockIcon),
                                              object: nil)
        perform(#selector(actuallyToggleShowDockIcon), with: nil, afterDelay: 0.3)
    }

    @objc func actuallyToggleShowDockIcon() {
        let enabled = showDockIconCheckbox.state == .on
        MJDockIconSetVisible(enabled)
        maybeWarnAboutDockMenuProblem()
    }

    @objc func toggleMenuDockIcon(_ sender: NSButton) {
        MJMenuIconSetVisible(sender.state == .on)
        maybeWarnAboutDockMenuProblem()
    }

    @objc func toggleKeepConsoleOnTop(_ sender: NSButton) {
        MJConsoleWindowSetAlwaysOnTop(sender.state == .on)
    }

    // MARK: - Dock/menu icon problem alert

    private func maybeWarnAboutDockMenuProblem() {
        guard !MJMenuIconVisible() && !MJDockIconVisible() else { return }
        guard !UserDefaults.standard.bool(forKey: MJSkipDockMenuIconProblemAlertKey) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "How to get back to this window"
        alert.informativeText = "When both the dock icon and menu icon are disabled, you can get back to this Preferences window by activating Cosmic Hammer from Spotlight or by running `open -a \"Cosmic Hammer\"` from Terminal, and then pressing Command + Comma."
        alert.showsSuppressionButton = true
        alert.beginSheetModal(for: window!) { _ in
            let skip = alert.suppressionButton?.state == .on
            UserDefaults.standard.set(skip, forKey: MJSkipDockMenuIconProblemAlertKey)
        }
    }
}
