//
//  MJAppDelegate.swift
//  Hammerspoon
//
//  Translated from MJAppDelegate.m
//  Copyright (c) 2015 Hammerspoon. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers

// MARK: - HSOpenFileDelegate Protocol

@objc protocol HSOpenFileDelegate: NSObjectProtocol {
    func callback(withURL openUrl: String, senderPID pid: pid_t)
}

// MARK: - MJAppDelegate

@objcMembers
class MJAppDelegate: NSObject, NSApplicationDelegate {
    var menuBarMenu: NSMenu?
    var startupEvent: NSAppleEventDescriptor?
    var startupFile: String?
    weak var openFileDelegate: HSOpenFileDelegate?

    // MARK: - Programmatic Menu Construction

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        // -- Hammerspoon (application) menu --
        let appMenuItem = NSMenuItem(title: "Hammerspoon", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Hammerspoon")

        let aboutItem = appMenu.addItem(withTitle: "About Hammerspoon", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self

        appMenu.addItem(.separator())

        let prefsItem = appMenu.addItem(withTitle: "Preferences\u{2026}", action: #selector(showPreferencesWindow(_:)), keyEquivalent: ",")
        prefsItem.target = self

        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide Hammerspoon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        appMenu.addItem(.separator())

        let quitItem = appMenu.addItem(withTitle: "Quit Hammerspoon", action: #selector(quitHammerspoon(_:)), keyEquivalent: "q")
        quitItem.target = self

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // -- File menu --
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let reloadItem = fileMenu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "R")
        reloadItem.target = self
        reloadItem.keyEquivalentModifierMask = .command

        let openConfigItem = fileMenu.addItem(withTitle: "Open Config", action: #selector(openConfig(_:)), keyEquivalent: "o")
        openConfigItem.target = self

        fileMenu.addItem(.separator())

        let consoleItem = fileMenu.addItem(withTitle: "Console\u{2026}", action: #selector(showConsoleWindow(_:)), keyEquivalent: "r")
        consoleItem.target = self

        fileMenu.addItem(.separator())

        let pageSetupItem = fileMenu.addItem(withTitle: "Page Setup\u{2026}", action: #selector(NSDocument.runPageLayout(_:)), keyEquivalent: "P")
        pageSetupItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(withTitle: "Print\u{2026}", action: #selector(NSView.printView(_:)), keyEquivalent: "p")

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // -- Edit menu --
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

        // Find submenu
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
        editMenu.addItem(findMenuItem)

        // Spelling and Grammar submenu
        let spellingMenuItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling")

        spellingMenu.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spellingMenu.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spellingMenu.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        spellingMenu.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")

        spellingMenuItem.submenu = spellingMenu
        editMenu.addItem(spellingMenuItem)

        // Substitutions submenu
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
        editMenu.addItem(subsMenuItem)

        // Transformations submenu
        let transMenuItem = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let transMenu = NSMenu(title: "Transformations")

        transMenu.addItem(withTitle: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        transMenu.addItem(withTitle: "Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        transMenu.addItem(withTitle: "Capitalize", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")

        transMenuItem.submenu = transMenu
        editMenu.addItem(transMenuItem)

        // Speech submenu
        let speechMenuItem = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        let speechMenu = NSMenu(title: "Speech")

        speechMenu.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        speechMenu.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")

        speechMenuItem.submenu = speechMenu
        editMenu.addItem(speechMenuItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // -- Window menu --
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // -- Help menu --
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        helpMenu.addItem(withTitle: "Hammerspoon Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")

        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItemMenu() {
        let menu = NSMenu(title: "Status Item Menu")

        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config", action: #selector(openConfig(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Console\u{2026}", action: #selector(showConsoleWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Preferences\u{2026}", action: #selector(showPreferencesWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Hammerspoon", action: #selector(showAboutPanel(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Hammerspoon", action: #selector(quitHammerspoon(_:)), keyEquivalent: "").target = self

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

    func applicationWillFinishLaunching(_ aNotification: Notification) {
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
        self.startupEvent = nil
        self.startupFile = nil
        self.openFileDelegate = nil
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        self.startupEvent = event
    }

    func application(_ theApplication: NSApplication, openFile fileAndPath: String) -> Bool {
        var typeOfFile: String? = nil
        let fileURL = URL(fileURLWithPath: fileAndPath)
        if let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
            typeOfFile = contentType.identifier
        }

        if typeOfFile == "org.hammerspoon.hammerspoon.spoon" {
            // This is a Spoon, so we will attempt to copy it to the Spoons directory
            var success = false
            var upgrade = false
            let spoonPath = (MJConfigDirAbsolute() as NSString).appendingPathComponent("Spoons")
            let spoonName = (fileAndPath as NSString).lastPathComponent
            let dstSpoonFullPath = (spoonPath as NSString).appendingPathComponent(spoonName)

            if dstSpoonFullPath == fileAndPath {
                NSLog("User double clicked on a Spoon in %@, skipping", MJConfigDirAbsolute())
                return true
            }

            let fileManager = FileManager.default

            // Remove any preexisting copy of the Spoon
            if fileManager.fileExists(atPath: dstSpoonFullPath) {
                NSLog("Spoon already exists at %@, removing the old version", dstSpoonFullPath)
                upgrade = true
                do {
                    try fileManager.removeItem(atPath: dstSpoonFullPath)
                    success = true
                } catch {
                    NSLog("Unable to remove existing Spoon (%@):%@", dstSpoonFullPath, error.localizedDescription)
                    let alert = NSAlert()
                    alert.addButton(withTitle: "OK")
                    alert.messageText = "Error upgrading Spoon"
                    alert.informativeText = "\(error.localizedDescription)\n\nSource: \(fileAndPath)\nDest: \(spoonPath)"
                    alert.alertStyle = .critical
                    alert.runModal()
                    return true
                }
            }

            do {
                try FileManager.default.moveItem(atPath: fileAndPath, toPath: dstSpoonFullPath)
                success = true
            } catch {
                NSLog("Unable to move %@ to %@: %@", fileAndPath, spoonPath, error.localizedDescription)
                let alert = NSAlert()
                alert.addButton(withTitle: "OK")
                alert.messageText = "Error installing Spoon"
                alert.informativeText = "\(error.localizedDescription)\n\nSource: \(fileAndPath)\nDest: \(spoonPath)"
                alert.alertStyle = .critical
                alert.runModal()
            }

            if success {
                let notification = NSUserNotification()
                notification.title = "Spoon \(upgrade ? "upgraded" : "installed")"
                notification.informativeText = "\(spoonName) is now available\(upgrade ? ", reload your config" : "")"
                notification.soundName = NSUserNotificationDefaultSoundName
                NSUserNotificationCenter.default.deliver(notification)
            }

            return true // Note that we always return YES here because otherwise macOS tells the user that we can't open Spoons, which is ludicrous
        }

        let fileExtension = (fileAndPath as NSString).pathExtension
        guard let infoDict = Bundle.main.infoDictionary,
              let supportedExtensions = (infoDict as NSDictionary).value(forKeyPath: "CFBundleDocumentTypes.CFBundleTypeExtensions") as? [Any] else {
            return true
        }
        let flatSupportedExtensions: [String]
        if let nested = supportedExtensions as? [[String]] {
            flatSupportedExtensions = nested.flatMap { $0 }
        } else if let flat = supportedExtensions as? [String] {
            flatSupportedExtensions = flat
        } else {
            flatSupportedExtensions = []
        }

        // Files to be processed by hs.urlevent
        if flatSupportedExtensions.contains(fileExtension) {
            if openFileDelegate == nil {
                self.startupFile = fileAndPath
            } else {
                openFileDelegate?.callback(withURL: fileAndPath, senderPID: -1)
            }
        } else {
            // Trigger File Dropped to Dock Icon Callback
            fileDroppedToDockIcon(fileAndPath)
        }

        return true
    }

    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let webpageURL = userActivity.webpageURL {
            NSWorkspace.shared.open(webpageURL)
            return true
        }
        return false
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Set app icon programmatically as a fallback for non-bundle contexts
        if let icon = NSImage(named: "Hammerspoon") {
            NSApp.applicationIconImage = icon
        }

        var isTesting = false

        // User is holding down Command (0x37) & Option (0x3A) keys:
        if CGEventSource.keyState(.combinedSessionState, key: 0x3A)
            && CGEventSource.keyState(.combinedSessionState, key: 0x37) {

            let alert = NSAlert()
            let deleteButton = alert.addButton(withTitle: "Delete Preferences")
            deleteButton.hasDestructiveAction = true

            alert.addButton(withTitle: "Cancel")
            alert.messageText = "Do you want to delete the preferences?"
            alert.informativeText = "Deleting the preferences will reset all Hammerspoon settings (including everything that uses hs.settings) to their defaults. This does not remove anything in ~/.hammerspoon/"
            alert.alertStyle = .warning

            if alert.runModal() == .alertFirstButtonReturn {
                // Reset Preferences:
                let allObjects = UserDefaults.standard.dictionaryRepresentation()
                for key in allObjects.keys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                UserDefaults.standard.synchronize()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityChanged(_:)),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )

        // Remove our early event manager handler so hs.urlevent can register for it later, if the user has it configured to
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        if NSClassFromString("XCTest") != nil {
            // Hammerspoon Tests
            NSLog("in testing mode!")
            isTesting = true

            let mainBundle = Bundle.main
            guard let bundle = Bundle(path: "\(mainBundle.bundlePath)/Contents/Plugins/Hammerspoon Tests.xctest"),
                  let lsUnitPath = bundle.path(forResource: "lsunit", ofType: "lua") else {
                NSLog("Unable to find lsunit.lua in Hammerspoon Tests.xctest. We're about to crash, sorry!")
                abort()
            }

            NSLog("testing lsunit.lua")
            let fsPath = (lsUnitPath as NSString).fileSystemRepresentation
            MJConfigFile = FileManager.default.string(withFileSystemRepresentation: fsPath, length: strlen(fsPath))
        } else if ProcessInfo.processInfo.environment["XCTESTING"] != nil {
            // Hammerspoon UI Tests
            NSLog("in UI testing mode")
            let initPath = FileManager.default.currentDirectoryPath + "/Hammerspoon UI Tests-Runner.app/Contents/PlugIns/Hammerspoon UI Tests.xctest/Contents/Resources/init.lua"

            guard FileManager.default.fileExists(atPath: initPath) else {
                NSLog("Unable to find init.lua in Hammerspoon UI Tests. We're about to crash, sorry!")
                abort()
            }

            NSLog("UI testing init.lua")
            let fsPath = (initPath as NSString).fileSystemRepresentation
            MJConfigFile = FileManager.default.string(withFileSystemRepresentation: fsPath, length: strlen(fsPath))
            showConsoleWindow(nil)
        } else {
            // No test environment detected, this is a live user run
            if let userMJConfigFile = UserDefaults.standard.string(forKey: "MJConfigFile") {
                MJConfigFile = userMJConfigFile
            }

            // Ensure we have a Spoons directory
            let spoonsPath = (MJConfigDirAbsolute() as NSString).appendingPathComponent("Spoons")
            let fileManager = FileManager.default
            var spoonsPathIsDir: ObjCBool = false
            let spoonsPathExists = fileManager.fileExists(atPath: spoonsPath, isDirectory: &spoonsPathIsDir)

            NSLog("Determined Spoons path will be: %@ (exists: %@, isDir: %@)",
                  spoonsPath,
                  spoonsPathExists ? "YES" : "NO",
                  spoonsPathIsDir.boolValue ? "YES" : "NO")

            if spoonsPathExists && !spoonsPathIsDir.boolValue {
                NSLog("ERROR: %@ exists, but is a file", spoonsPath)
                abort()
            }

            if !spoonsPathExists {
                NSLog("Creating Spoons directory at: %@", spoonsPath)
                try? FileManager.default.createDirectory(atPath: spoonsPath, withIntermediateDirectories: true, attributes: nil)
            }
        }

        // Become the handler for events from macOS Services
        NSApp.servicesProvider = self

        MJEnsureDirectoryExists(MJConfigDir())
        FileManager.default.changeCurrentDirectoryPath(MJConfigDir())

        registerDefaultDefaults()

        MJMenuIconSetup(self.menuBarMenu)
        MJDockIconSetup()
        MJConsoleWindowController.singleton().setup()
        MJLuaCreate()

        if !MJAccessibilityIsEnabled() {
            MJPreferencesWindowController.singleton().showWindow(nil)
        }

        // Suppress unused variable warning
        _ = isTesting
    }

    // Dragging & Dropping of Text to Dock Item
    @objc func processDockIconDraggedText(_ pboard: NSPasteboard, userData: String, error errorPtr: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let pboardString = pboard.string(forType: .string) {
            textDroppedToDockIcon(pboardString)
        }
    }

    // Dragging & Dropping of File to Dock Item
    @objc func processDockIconDraggedFile(_ pboard: NSPasteboard, userData: String, error errorPtr: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let filePaths = pboard.propertyList(forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")) as? [String] {
            for filePath in filePaths {
                fileDroppedToDockIcon(filePath)
            }
        }
    }

    @objc private func accessibilityChanged(_ note: Notification) {
        NSLog("accessibilityChanged: %@", MJAccessibilityIsEnabled() ? "ENABLED" : "DISABLED")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            callAccessibilityStateCallback()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MJLuaDestroy()
        return .terminateNow
    }

    private func registerDefaultDefaults() {
        UserDefaults.standard.register(defaults: [
            "NSApplicationCrashOnExceptions": true,
            MJShowDockIconKey: false,
            MJShowMenuIconKey: true,
            HSAutoLoadExtensions: true,
            HSAppleScriptEnabledKey: false,
            HSOpenConsoleOnDockClickKey: true,
            HSPreferencesDarkModeKey: false,
            HSConsoleDarkModeKey: false,
        ])
    }

    @IBAction func reloadConfig(_ sender: Any?) {
        MJLuaReplace()
    }

    @IBAction func showConsoleWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        MJConsoleWindowController.singleton().showWindow(nil)
    }

    @IBAction func showPreferencesWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        MJPreferencesWindowController.singleton().showWindow(nil)
    }

    @IBAction func showAboutPanel(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        // The ObjC version uses @try/@catch for NSException. In Swift we attempt the call
        // and rely on the fact that orderFrontStandardAboutPanel rarely throws. If the
        // installation is corrupt, this may crash rather than log gracefully.
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    @IBAction func quitHammerspoon(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    @IBAction func openConfig(_ sender: Any?) {
        let path = MJConfigFileFullPath()

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
        }

        let workspace = NSWorkspace.shared
        if !workspace.openFile(path) {
            // No app is associated with .lua files, so fall back on TextEdit
            workspace.openFile(path, withApplication: "TextEdit", andDeactivate: true)
        }
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = MJAppDelegate()
app.delegate = delegate
app.run()
