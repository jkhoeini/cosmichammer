// swift-tools-version:5.9
import PackageDescription

// SPM auto-discovers sources under Sources/HSExtensions/ by following the
// symlinks into extensions/<name>/ AND into Hammerspoon/ (the core app
// sources).  The Hammerspoon symlink points at the main app source tree;
// SPM compiles its .m/.h files alongside the extensions so that everything
// ends up in one static library (libHSExtensions.a).
//
// Excludes:
//  - Non-source files inside Hammerspoon/ (XIBs, plists, assets, etc.)
//    that SPM would otherwise try to process or treat as resources.
//  - "ipc/cli" — the standalone `hs` CLI tool (built by Packages/hs/).
//  - "sqlite3/lsqlite3.c" — compiled indirectly via lsqlite3_wrapper.m as
//    Objective-C.  Letting SPM also compile it as plain C causes duplicate
//    symbols.

let package = Package(
    name: "HSExtensions",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HSExtensions", type: .static, targets: ["HSExtensions"]),
    ],
    dependencies: [
        .package(path: "../LuaSkin"),
        .package(path: "../CocoaHTTPServer"),
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", exact: "7.6.5"),
        .package(url: "https://github.com/armadsen/ORSSerialPort", exact: "2.1.0"),
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack", exact: "3.8.5"),
    ],
    targets: [
        .target(
            name: "HSExtensions",
            dependencies: [
                "LuaSkin",
                "CocoaHTTPServer",
                "CocoaAsyncSocket",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
            ],
            path: "Sources/HSExtensions",
            exclude: [
                // Non-source files inside Hammerspoon/ that must not be
                // compiled or treated as SPM resources.
                "Hammerspoon/Build Configs",
                "Hammerspoon/ConsoleWindow.xib",
                "Hammerspoon/Credits.rtf",
                "Hammerspoon/Hammerspoon-Info.plist",
                "Hammerspoon/Hammerspoon-Prefix.pch",
                "Hammerspoon/Hammerspoon-dev.entitlements",
                "Hammerspoon/Hammerspoon.entitlements",
                "Hammerspoon/Hammerspoon.sdef",
                "Hammerspoon/Images.xcassets",
                "Hammerspoon/Intents.intentdefinition",
                "Hammerspoon/MainMenu.xib",
                "Hammerspoon/PreferencesWindow.xib",
                "Hammerspoon/Spoon.icns",
                "Hammerspoon/setup.lua",
                "Hammerspoon/statusicon.pdf",
                // Other excludes carried forward from before.
                "ipc/cli",
                "sqlite3/lsqlite3.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_COMPAT_5_3"),
                // Header search paths so #import "Foo.h" resolves for extensions
                // that include sibling files relatively or that share helper
                // headers under the main app source tree.
                .headerSearchPath("Hammerspoon"),
                .headerSearchPath("axuielement"),
                .headerSearchPath("canvas"),
                .headerSearchPath("chooser"),
                .headerSearchPath("doc"),
                .headerSearchPath("eventtap"),
                .headerSearchPath("fs"),
                .headerSearchPath("hash"),
                .headerSearchPath("hid"),
                .headerSearchPath("httpserver"),
                .headerSearchPath("location"),
                .headerSearchPath("network/ping"),
                .headerSearchPath("noises"),
                .headerSearchPath("osascript"),
                .headerSearchPath("razer"),
                .headerSearchPath("shortcuts"),
                .headerSearchPath("socket"),
                .headerSearchPath("spaces"),
                .headerSearchPath("streamdeck"),
                .headerSearchPath("webview"),
                .unsafeFlags([
                    "-Wno-everything",
                ]),
            ],
            cxxSettings: [
                .define("LUA_USE_MACOSX"),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Quartz"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreSpotlight"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("DiscRecording"),
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("Intents"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("OSAKit"),
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("IOBluetooth"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
