import CLua
import Foundation
import Synchronization

public final class Environment: @unchecked Sendable {
    public struct Runtime {
        public let clock: any ClockProtocol
        public let eventLoop: any EventLoopProtocol
        public let fileSystem: any FileSystemProtocol
        public let settings: any SettingsProtocol
        public let systemInfo: any SystemInfoProtocol
        public let process: any ProcessProtocol
        public let telemetry: any TelemetryProtocol

        public init(clock: any ClockProtocol, eventLoop: any EventLoopProtocol,
                    fileSystem: any FileSystemProtocol, settings: any SettingsProtocol,
                    systemInfo: any SystemInfoProtocol, process: any ProcessProtocol,
                    telemetry: any TelemetryProtocol) {
            self.clock = clock
            self.eventLoop = eventLoop
            self.fileSystem = fileSystem
            self.settings = settings
            self.systemInfo = systemInfo
            self.process = process
            self.telemetry = telemetry
        }
    }

    public struct UserInterface {
        public let workspace: any WorkspaceProtocol
        public let pasteboard: any PasteboardProtocol
        public let screen: any ScreenProtocol
        public let window: any WindowProtocol
        public let accessibility: any AccessibilityProtocol
        public let input: any InputProtocol
        public let spaces: any SpacesProtocol
        public let webView: any WebViewProtocol
        public let dialog: any DialogProtocol
        public let statusBar: any StatusBarProtocol
        public let drawing: any DrawingProtocol
        public let application: any ApplicationProtocol

        public init(workspace: any WorkspaceProtocol, pasteboard: any PasteboardProtocol,
                    screen: any ScreenProtocol, window: any WindowProtocol,
                    accessibility: any AccessibilityProtocol, input: any InputProtocol,
                    spaces: any SpacesProtocol, webView: any WebViewProtocol,
                    dialog: any DialogProtocol, statusBar: any StatusBarProtocol,
                    drawing: any DrawingProtocol, application: any ApplicationProtocol) {
            self.workspace = workspace
            self.pasteboard = pasteboard
            self.screen = screen
            self.window = window
            self.accessibility = accessibility
            self.input = input
            self.spaces = spaces
            self.webView = webView
            self.dialog = dialog
            self.statusBar = statusBar
            self.drawing = drawing
            self.application = application
        }
    }

    public struct Services {
        public let network: any NetworkProtocol
        public let location: any LocationProtocol
        public let notification: any NotificationProtocol
        public let audio: any AudioProtocol
        public let socket: any SocketProtocol
        public let speech: any SpeechProtocol
        public let automation: any AutomationProtocol
        public let fileWatching: any FileWatchingProtocol
        public let device: any DeviceProtocol
        public let camera: any CameraProtocol
        public let search: any SearchProtocol
        public let loginItem: any LoginItemProtocol
        public let bonjour: any BonjourProtocol
        public let certificate: any CertificateProtocol
        public let media: any MediaProtocol

        public init(network: any NetworkProtocol, location: any LocationProtocol,
                    notification: any NotificationProtocol, audio: any AudioProtocol,
                    socket: any SocketProtocol, speech: any SpeechProtocol,
                    automation: any AutomationProtocol, fileWatching: any FileWatchingProtocol,
                    device: any DeviceProtocol, camera: any CameraProtocol,
                    search: any SearchProtocol, loginItem: any LoginItemProtocol,
                    bonjour: any BonjourProtocol, certificate: any CertificateProtocol,
                    media: any MediaProtocol) {
            self.network = network
            self.location = location
            self.notification = notification
            self.audio = audio
            self.socket = socket
            self.speech = speech
            self.automation = automation
            self.fileWatching = fileWatching
            self.device = device
            self.camera = camera
            self.search = search
            self.loginItem = loginItem
            self.bonjour = bonjour
            self.certificate = certificate
            self.media = media
        }
    }

    public let runtime: Runtime
    public let userInterface: UserInterface
    public let services: Services

    public init(runtime: Runtime, userInterface: UserInterface, services: Services) {
        self.runtime = runtime
        self.userInterface = userInterface
        self.services = services
    }

    public var clock: any ClockProtocol { runtime.clock }
    public var eventLoop: any EventLoopProtocol { runtime.eventLoop }
    public var fileSystem: any FileSystemProtocol { runtime.fileSystem }
    public var settings: any SettingsProtocol { runtime.settings }
    public var systemInfo: any SystemInfoProtocol { runtime.systemInfo }
    public var process: any ProcessProtocol { runtime.process }
    public var telemetry: any TelemetryProtocol { runtime.telemetry }
    public var workspace: any WorkspaceProtocol { userInterface.workspace }
    public var pasteboard: any PasteboardProtocol { userInterface.pasteboard }
    public var screen: any ScreenProtocol { userInterface.screen }
    public var window: any WindowProtocol { userInterface.window }
    public var accessibility: any AccessibilityProtocol { userInterface.accessibility }
    public var input: any InputProtocol { userInterface.input }
    public var spaces: any SpacesProtocol { userInterface.spaces }
    public var webView: any WebViewProtocol { userInterface.webView }
    public var dialog: any DialogProtocol { userInterface.dialog }
    public var statusBar: any StatusBarProtocol { userInterface.statusBar }
    public var drawing: any DrawingProtocol { userInterface.drawing }
    public var application: any ApplicationProtocol { userInterface.application }
    public var network: any NetworkProtocol { services.network }
    public var location: any LocationProtocol { services.location }
    public var notification: any NotificationProtocol { services.notification }
    public var audio: any AudioProtocol { services.audio }
    public var socket: any SocketProtocol { services.socket }
    public var speech: any SpeechProtocol { services.speech }
    public var automation: any AutomationProtocol { services.automation }
    public var fileWatching: any FileWatchingProtocol { services.fileWatching }
    public var device: any DeviceProtocol { services.device }
    public var camera: any CameraProtocol { services.camera }
    public var search: any SearchProtocol { services.search }
    public var loginItem: any LoginItemProtocol { services.loginItem }
    public var bonjour: any BonjourProtocol { services.bonjour }
    public var certificate: any CertificateProtocol { services.certificate }
    public var media: any MediaProtocol { services.media }
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

/// Release the Environment retained in lua_getextraspace without reading from a
/// lua_State that may already be closed. Runtime teardown snapshots this pointer
/// before lua_close, then delegates the matching release here.
public func environmentRelease(_ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    Unmanaged<Environment>.fromOpaque(raw).release()
}

/// Retrieve the Environment from a lua_State. O(1) pointer read.
public func environmentGet(_ L: UnsafeMutablePointer<lua_State>!) -> Environment {
    let raw = lua_getextraspace(L)!.load(as: UnsafeMutableRawPointer.self)
    precondition(raw != UnsafeMutableRawPointer(bitPattern: 0),
                 "environmentGet called on lua_State with no attached Environment")
    return Unmanaged<Environment>.fromOpaque(raw).takeUnretainedValue()
}

// MARK: - Process environment for callbacks without a lua_State

/// Process-global environment storage is required by AppKit/C callbacks that do not
/// receive a lua_State. Mutex makes the exceptional global seam explicit and safe
/// under Swift 6 strict concurrency; Lua-state-owned code should use environmentGet.
private let globalEnvironment = Mutex<Environment?>(nil)

public func environmentSetGlobal(_ environment: Environment) {
    globalEnvironment.withLock { $0 = environment }
}

public func environmentClearGlobal() {
    globalEnvironment.withLock { $0 = nil }
}

public func environmentGetGlobal() -> Environment {
    globalEnvironment.withLock { environment in
        guard let environment else {
            preconditionFailure("environmentGetGlobal called before environmentSetGlobal")
        }
        return environment
    }
}

public func environmentGetGlobalOrNil() -> Environment? {
    globalEnvironment.withLock { $0 }
}
