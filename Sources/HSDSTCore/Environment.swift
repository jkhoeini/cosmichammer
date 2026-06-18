import CLua
import Foundation

public final class Environment {
    // MARK: - Original 12 protocols
    public let clock: any ClockProtocol
    public let eventLoop: any EventLoopProtocol
    public let fileSystem: any FileSystemProtocol
    public let network: any NetworkProtocol
    public let workspace: any WorkspaceProtocol
    public let pasteboard: any PasteboardProtocol
    public let settings: any SettingsProtocol
    public let screen: any ScreenProtocol
    public let systemInfo: any SystemInfoProtocol
    public let location: any LocationProtocol
    public let notification: any NotificationProtocol
    public let process: any ProcessProtocol

    // MARK: - New 15 protocols
    public let window: any WindowProtocol
    public let accessibility: any AccessibilityProtocol
    public let input: any InputProtocol
    public let audio: any AudioProtocol
    public let socket: any SocketProtocol
    public let speech: any SpeechProtocol
    public let spaces: any SpacesProtocol
    public let webView: any WebViewProtocol
    public let automation: any AutomationProtocol
    public let fileWatching: any FileWatchingProtocol
    public let device: any DeviceProtocol
    public let camera: any CameraProtocol
    public let search: any SearchProtocol
    public let loginItem: any LoginItemProtocol
    public let dialog: any DialogProtocol

    // MARK: - Round 3 protocols
    public let statusBar: any StatusBarProtocol
    public let bonjour: any BonjourProtocol
    public let drawing: any DrawingProtocol
    public let certificate: any CertificateProtocol
    public let media: any MediaProtocol

    // MARK: - Round 4 protocols
    public let application: any ApplicationProtocol

    public init(
        clock: any ClockProtocol,
        eventLoop: any EventLoopProtocol,
        fileSystem: any FileSystemProtocol,
        network: any NetworkProtocol,
        workspace: any WorkspaceProtocol,
        pasteboard: any PasteboardProtocol,
        settings: any SettingsProtocol,
        screen: any ScreenProtocol,
        systemInfo: any SystemInfoProtocol,
        location: any LocationProtocol,
        notification: any NotificationProtocol,
        process: any ProcessProtocol,
        window: any WindowProtocol,
        accessibility: any AccessibilityProtocol,
        input: any InputProtocol,
        audio: any AudioProtocol,
        socket: any SocketProtocol,
        speech: any SpeechProtocol,
        spaces: any SpacesProtocol,
        webView: any WebViewProtocol,
        automation: any AutomationProtocol,
        fileWatching: any FileWatchingProtocol,
        device: any DeviceProtocol,
        camera: any CameraProtocol,
        search: any SearchProtocol,
        loginItem: any LoginItemProtocol,
        dialog: any DialogProtocol,
        statusBar: any StatusBarProtocol,
        bonjour: any BonjourProtocol,
        drawing: any DrawingProtocol,
        certificate: any CertificateProtocol,
        media: any MediaProtocol,
        application: any ApplicationProtocol
    ) {
        self.clock = clock
        self.eventLoop = eventLoop
        self.fileSystem = fileSystem
        self.network = network
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.settings = settings
        self.screen = screen
        self.systemInfo = systemInfo
        self.location = location
        self.notification = notification
        self.process = process
        self.window = window
        self.accessibility = accessibility
        self.input = input
        self.audio = audio
        self.socket = socket
        self.speech = speech
        self.spaces = spaces
        self.webView = webView
        self.automation = automation
        self.fileWatching = fileWatching
        self.device = device
        self.camera = camera
        self.search = search
        self.loginItem = loginItem
        self.dialog = dialog
        self.statusBar = statusBar
        self.bonjour = bonjour
        self.drawing = drawing
        self.certificate = certificate
        self.media = media
        self.application = application
    }
}

// MARK: - lua_getextraspace storage

/// Attach an Environment to a lua_State. Retains the Environment.
/// Must be called once after luaL_newstate(), before any extension code runs.
public func environmentAttach(_ L: UnsafeMutablePointer<lua_State>!, _ env: Environment) {
    let retained = Unmanaged.passRetained(env)
    lua_getextraspace(L)!.storeBytes(of: retained.toOpaque(), as: UnsafeMutableRawPointer.self)
}

/// Detach and release the Environment from a lua_State.
/// Must be called before lua_close().
public func environmentDetach(_ L: UnsafeMutablePointer<lua_State>!) {
    let extra = lua_getextraspace(L)!
    let raw = extra.load(as: UnsafeMutableRawPointer.self)
    guard raw != UnsafeMutableRawPointer(bitPattern: 0) else { return }
    Unmanaged<Environment>.fromOpaque(raw).release()
    extra.storeBytes(of: Int(0), as: Int.self)
}

/// Retrieve the Environment from a lua_State. O(1) pointer read.
public func environmentGet(_ L: UnsafeMutablePointer<lua_State>!) -> Environment {
    let raw = lua_getextraspace(L)!.load(as: UnsafeMutableRawPointer.self)
    precondition(raw != UnsafeMutableRawPointer(bitPattern: 0),
                 "environmentGet called on lua_State with no attached Environment")
    return Unmanaged<Environment>.fromOpaque(raw).takeUnretainedValue()
}

// MARK: - Global accessor for non-Lua code (AppKit callbacks, @_cdecl functions)

private var _globalEnvironment: Environment?

/// Set the global Environment. Called once alongside environmentAttach.
/// Provides access for code without a lua_State (AppKit delegates, @_cdecl exports).
public func environmentSetGlobal(_ env: Environment) {
    _globalEnvironment = env
}

/// Clear the global Environment. Called alongside environmentDetach.
public func environmentClearGlobal() {
    _globalEnvironment = nil
}

/// Retrieve the global Environment for non-Lua code paths.
public func environmentGetGlobal() -> Environment {
    guard let env = _globalEnvironment else {
        preconditionFailure("environmentGetGlobal called before environmentSetGlobal")
    }
    return env
}

/// Safe accessor that returns nil instead of crashing when no global Environment is set.
/// Use in @_cdecl functions that may be called between tests or outside Lua context.
public func environmentGetGlobalOrNil() -> Environment? {
    return _globalEnvironment
}
