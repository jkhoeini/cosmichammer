import Cocoa
import UniformTypeIdentifiers
import os.log
import HSDSTCore

// MJLuaCreate, MJLuaDestroy, MJLuaReplace, callDockIconCallback,
// callAccessibilityStateCallback, textDroppedToDockIcon, fileDroppedToDockIcon
// are now defined in LuaRuntime.swift (same module) — no @_silgen_name needed.

// MARK: - MJAppDelegate

enum OpenedFileHandlingResult: Equatable {
    case deliveredToURLEvent
    case storedForStartup
    case deliveredToDock
}

@objc(MJAppDelegate)
class MJAppDelegate: NSObject, NSApplicationDelegate, HSAppDelegateURLAccess {

    // MARK: Properties (matching MJAppDelegate.h)

    var menuBarMenu: NSMenu?
    @objc var startupEvents: [NSAppleEventDescriptor] = []
    @objc var startupFile: String?
    @objc weak var openFileDelegate: (NSObjectProtocol & HSOpenFileDelegate)?

    // MARK: - Programmatic Menu Construction

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        mainMenu.addItem(buildAppMenuItem())
        mainMenu.addItem(buildFileMenuItem())
        mainMenu.addItem(buildEditMenuItem())
        mainMenu.addItem(buildWindowMenuItem())
        mainMenu.addItem(buildHelpMenuItem())

        NSApp.mainMenu = mainMenu
    }

    private func buildAppMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem(title: "Cosmic Hammer", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Cosmic Hammer")

        appMenu.addItem(withTitle: "About Cosmic Hammer", action: #selector(showAboutPanel(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences\u{2026}", action: #selector(showPreferencesWindow(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cosmic Hammer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cosmic Hammer", action: #selector(quitCosmicHammer(_:)), keyEquivalent: "q").target = self

        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    private func buildFileMenuItem() -> NSMenuItem {
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let reloadItem = fileMenu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "R")
        reloadItem.target = self
        reloadItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(withTitle: "Open Config", action: #selector(openConfig(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Console\u{2026}", action: #selector(showConsoleWindow(_:)), keyEquivalent: "r").target = self
        fileMenu.addItem(.separator())
        let pageSetupItem = fileMenu.addItem(withTitle: "Page Setup\u{2026}", action: #selector(NSDocument.runPageLayout(_:)), keyEquivalent: "P")
        pageSetupItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Print\u{2026}", action: #selector(NSView.printView(_:)), keyEquivalent: "p")

        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    private func buildEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = .command
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatchItem = editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        pasteMatchItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        editMenu.addItem(buildFindSubmenuItem())
        editMenu.addItem(buildSpellingSubmenuItem())
        editMenu.addItem(buildSubstitutionsSubmenuItem())
        editMenu.addItem(buildTransformationsSubmenuItem())
        editMenu.addItem(buildSpeechSubmenuItem())

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    private func buildFindSubmenuItem() -> NSMenuItem {
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")

        let findItem = findMenu.addItem(withTitle: "Find\u{2026}", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = 1
        let findReplaceItem = findMenu.addItem(withTitle: "Find and Replace\u{2026}", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findReplaceItem.tag = 12
        findReplaceItem.keyEquivalentModifierMask = [.command, .option]
        let findNextItem = findMenu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNextItem.tag = 2
        let findPrevItem = findMenu.addItem(withTitle: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "G")
        findPrevItem.tag = 3
        findPrevItem.keyEquivalentModifierMask = .command
        let useSelItem = findMenu.addItem(withTitle: "Use Selection for Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "e")
        useSelItem.tag = 7
        findMenu.addItem(withTitle: "Jump to Selection", action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")

        findMenuItem.submenu = findMenu
        return findMenuItem
    }

    private func buildSpellingSubmenuItem() -> NSMenuItem {
        let spellingMenuItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling")

        spellingMenu.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spellingMenu.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spellingMenu.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        spellingMenu.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")

        spellingMenuItem.submenu = spellingMenu
        return spellingMenuItem
    }

    private func buildSubstitutionsSubmenuItem() -> NSMenuItem {
        let subsMenuItem = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        let subsMenu = NSMenu(title: "Substitutions")

        subsMenu.addItem(withTitle: "Show Substitutions", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: "")
        subsMenu.addItem(.separator())
        subsMenu.addItem(withTitle: "Smart Copy/Paste", action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Smart Links", action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Data Detectors", action: #selector(NSTextView.toggleAutomaticDataDetection(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")

        subsMenuItem.submenu = subsMenu
        return subsMenuItem
    }

    private func buildTransformationsSubmenuItem() -> NSMenuItem {
        let transMenuItem = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let transMenu = NSMenu(title: "Transformations")

        transMenu.addItem(withTitle: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        transMenu.addItem(withTitle: "Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        transMenu.addItem(withTitle: "Capitalize", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")

        transMenuItem.submenu = transMenu
        return transMenuItem
    }

    private func buildSpeechSubmenuItem() -> NSMenuItem {
        let speechMenuItem = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        let speechMenu = NSMenu(title: "Speech")

        speechMenu.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        speechMenu.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")

        speechMenuItem.submenu = speechMenu
        return speechMenuItem
    }

    private func buildWindowMenuItem() -> NSMenuItem {
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return windowMenuItem
    }

    private func buildHelpMenuItem() -> NSMenuItem {
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        helpMenu.addItem(withTitle: "Cosmic Hammer Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")

        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        return helpMenuItem
    }

    private func setupStatusItemMenu() {
        let menu = NSMenu(title: "Status Item Menu")

        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config", action: #selector(openConfig(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Console\u{2026}", action: #selector(showConsoleWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Preferences\u{2026}", action: #selector(showPreferencesWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Cosmic Hammer", action: #selector(showAboutPanel(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Cosmic Hammer", action: #selector(quitCosmicHammer(_:)), keyEquivalent: "").target = self

        self.menuBarMenu = menu
    }

    // MARK: - Application Lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        callDockIconCallback()
        if HSOpenConsoleOnDockClickEnabled() {
            MJConsoleWindowController.singleton().showWindow(nil)
        }
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItemMenu()

        // Set up an early event manager handler so we can catch URLs used to launch us
        let appleEventManager = NSAppleEventManager.shared()
        appleEventManager.setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        self.startupEvents = []
        self.startupFile = nil
        self.openFileDelegate = nil
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        self.startupEvents.append(event)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenedFile(filename, supportedExtensions: Self.supportedDocumentExtensions(from: Bundle.main.infoDictionary))
        return true
    }

    @discardableResult
    func handleOpenedFile(_ filename: String, supportedExtensions: [String]?) -> OpenedFileHandlingResult {
        precondition(!filename.isEmpty, "filename must not be empty")

        if let supportedExtensions {
            if Self.isURLEventDocument(filename, supportedExtensions: supportedExtensions) {
                if openFileDelegate == nil {
                    self.startupFile = filename
                    return .storedForStartup
                } else {
                    openFileDelegate?.callback(withURL: filename, senderPID: -1)
                    return .deliveredToURLEvent
                }
            } else {
                fileDroppedToDockIcon(filename as NSString)
                return .deliveredToDock
            }
        } else {
            fileDroppedToDockIcon(filename as NSString)
            return .deliveredToDock
        }
    }

    private static func supportedDocumentExtensions(from infoDictionary: [String: Any]?) -> [String]? {
        let infoDict = infoDictionary as NSDictionary?
        guard let supportedExtensions = infoDict?.value(forKeyPath: "CFBundleDocumentTypes.CFBundleTypeExtensions") as? [Any] else {
            return nil
        }

        return supportedExtensions.compactMap { item -> [String]? in
            if let array = item as? [String] { return array }
            if let string = item as? String { return [string] }
            return nil
        }.flatMap { $0 }
    }

    private static func isURLEventDocument(_ filename: String, supportedExtensions: [String]) -> Bool {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let normalizedExtensions = supportedExtensions.map { $0.lowercased() }
        return normalizedExtensions.contains(fileExtension)
    }

    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            if let ws = environmentGetGlobalOrNil()?.workspace {
                _ = ws.openURL(url.absoluteString)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLifecycle.registerDefaultDefaults()
        setFallbackAppIcon()
        promptToResetPreferencesIfHotkeyHeld()
        registerAccessibilityObserver()

        // Remove our early event manager handler so hs.urlevent can register for it later
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

        configureTestEnvironmentIfNeeded()

        // Become the handler for events from macOS Services
        NSApp.servicesProvider = self

        do {
            try AppLifecycle.prepareConfigDirectories()
            try AppLifecycle.changeToConfigDirectory()
        } catch {
            terminateAfterStartupFilesystemError(error)
            return
        }

        MJMenuIconSetup(self.menuBarMenu!)
        MJDockIconSetup()
        MJConsoleWindowController.singleton().setup()
        MJLuaCreate()

        if !MJAccessibilityIsEnabled() {
            MJPreferencesWindowController.singleton().showWindow(nil)
        }
    }

    private func setFallbackAppIcon() {
        if let icon = NSImage(named: "CosmicHammer") {
            NSApp.applicationIconImage = icon
        }
    }

    private func promptToResetPreferencesIfHotkeyHeld() {
        guard CGEventSource.keyState(.combinedSessionState, key: 0x3A)
                && CGEventSource.keyState(.combinedSessionState, key: 0x37) else { return }

        let alert = NSAlert()
        let deleteButton = alert.addButton(withTitle: "Delete Preferences")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.messageText = "Do you want to delete the preferences?"
        alert.informativeText = "Deleting the preferences will reset all Cosmic Hammer settings (including everything that uses hs.settings) to their defaults. This does not remove anything in your Cosmic Hammer configuration directory."
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            if let s = environmentGetGlobalOrNil()?.settings {
                for key in s.allKeys() {
                    s.removeObject(forKey: key)
                }
                _ = s.synchronize()
            } else {
                let allObjects = UserDefaults.standard.dictionaryRepresentation()
                for key in allObjects.keys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                UserDefaults.standard.synchronize()
            }
        }
    }

    private func registerAccessibilityObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityChanged(_:)),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
    }

    private func configureTestEnvironmentIfNeeded() {
        if NSClassFromString("XCTest") != nil {
            configureUnitTestEnvironment()
        } else if ProcessInfo.processInfo.environment["XCTESTING"] != nil {
            configureUITestEnvironment()
        } else {
            AppLifecycle.applyStoredConfigFile()
        }
    }

    private func configureUnitTestEnvironment() {
        os_log(.info, "in testing mode!")
        let mainBundle = Bundle.main
        if let bundle = Bundle(path: "\(mainBundle.bundlePath)/Contents/Plugins/CosmicHammer Tests.xctest"),
           let lsUnitPath = bundle.path(forResource: "lsunit", ofType: "lua")
        {
            let fsPath = (lsUnitPath as NSString).fileSystemRepresentation
            MJConfigFileSet(FileManager.default.string(withFileSystemRepresentation: fsPath, length: strlen(fsPath)) as NSString)
        } else {
            os_log(.fault, "Unable to find lsunit.lua in CosmicHammer Tests.xctest. We're about to crash, sorry!")
            abort()
        }
    }

    private func configureUITestEnvironment() {
        os_log(.info, "in UI testing mode")
        let initPath = FileManager.default.currentDirectoryPath + "/CosmicHammer UI Tests-Runner.app/Contents/PlugIns/CosmicHammer UI Tests.xctest/Contents/Resources/init.lua"
        let fsPath = (initPath as NSString).fileSystemRepresentation
        MJConfigFileSet(FileManager.default.string(withFileSystemRepresentation: fsPath, length: strlen(fsPath)) as NSString)
        showConsoleWindow(nil)
    }

    // Dragging & Dropping of Text to Dock Item
    @objc func processDockIconDraggedText(_ pboard: NSPasteboard, userData: String, error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let pboardString = pboard.string(forType: .string) {
            textDroppedToDockIcon(pboardString as NSString)
        }
    }

    // Dragging & Dropping of File to Dock Item
    @objc func processDockIconDraggedFile(_ pboard: NSPasteboard, userData: String, error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // errorPointer is non-optional in Swift; no nil check needed
        let pasteboardType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        if let filePaths = pboard.propertyList(forType: pasteboardType) as? [String] {
            for filePath in filePaths {
                fileDroppedToDockIcon(filePath as NSString)
            }
        }
    }

    @objc private func accessibilityChanged(_ note: Notification) {
        os_log(.info, "accessibilityChanged: %{public}s", MJAccessibilityIsEnabled() ? "ENABLED" : "DISABLED")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            callAccessibilityStateCallback()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MJLuaDestroy()
        return .terminateNow
    }

    private func terminateAfterStartupFilesystemError(_ error: Error) {
        let message = String(describing: error)
        os_log(.error, "Unable to prepare Cosmic Hammer config directory: %{public}s", message)

        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        alert.messageText = "Cosmic Hammer startup failed"
        alert.informativeText = "Unable to prepare the config directory.\n\n\(message)"
        alert.alertStyle = .critical
        alert.runModal()

        NSApplication.shared.terminate(nil)
    }

    // MARK: - Actions

    @IBAction func reloadConfig(_ sender: Any?) {
        MJLuaReplace()
    }

    @IBAction func showConsoleWindow(_ sender: Any?) {
        NSApplication.shared.activate()
        MJConsoleWindowController.singleton().showWindow(nil)
    }

    @IBAction func showPreferencesWindow(_ sender: Any?) {
        NSApplication.shared.activate()
        MJPreferencesWindowController.singleton().showWindow(nil)
    }

    @IBAction func showAboutPanel(_ sender: Any?) {
        NSApplication.shared.activate()
        // ObjC original wrapped this in @try/@catch for NSException.
        // Swift cannot catch ObjC exceptions, so we call it directly.
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    @IBAction func quitCosmicHammer(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    @IBAction func openConfig(_ sender: Any?) {
        let path = MJConfigFileFullPath() as String
        assert(!path.isEmpty, "config file path must not be empty")

        let fileExists: Bool
        if let fs = environmentGetGlobalOrNil()?.fileSystem {
            fileExists = fs.fileExists(atPath: path)
        } else {
            fileExists = FileManager.default.fileExists(atPath: path)
        }
        if !fileExists {
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
        }

        let nsWorkspace = NSWorkspace.shared
        if let ws = environmentGetGlobalOrNil()?.workspace {
            if !ws.openFile(path) {
                // No app is associated with .lua files, so fall back on TextEdit
                nsWorkspace.openFile(path, withApplication: "TextEdit", andDeactivate: true)
            }
        } else {
            if !nsWorkspace.openFile(path) {
                // No app is associated with .lua files, so fall back on TextEdit
                nsWorkspace.openFile(path, withApplication: "TextEdit", andDeactivate: true)
            }
        }
    }
}

// MARK: - String helper (matching NSString appendingPathComponent)

private extension String {
    func appendingPathComponent(_ component: String) -> String {
        return (self as NSString).appendingPathComponent(component)
    }
}

// MARK: - Entry point

@_cdecl("launchCosmicHammer")
func launchCosmicHammer() -> Int32 {
    autoreleasepool {
        let app = NSApplication.shared
        let delegate = MJAppDelegate()
        app.delegate = delegate
        app.run()
    }
    return 0
}
