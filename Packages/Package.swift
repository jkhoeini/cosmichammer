// swift-tools-version:6.2
import PackageDescription

// Unified SPM package for all Hammerspoon libraries.
//
// Three internal targets compiled into one static library product:
//
//   LuaSkin          – Lua 5.4 runtime + Objective-C bridge
//   CocoaHTTPServer  – vendored HTTP server (used by hs.httpserver)
//   HSExtensions     – 90+ extensions + core app sources
//
// The hs CLI (Packages/hs/) is a separate package built outside Xcode
// by `swift build --package-path Packages/hs` in the justfile.

let package = Package(
    name: "HammerspoonLibs",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HammerspoonLibs", type: .static, targets: ["HSExtensions"]),
    ],
    dependencies: [
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", exact: "7.6.5"),
        .package(url: "https://github.com/armadsen/ORSSerialPort", exact: "2.1.0"),
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack", exact: "3.9.0"),
    ],
    targets: [
        // ---------------------------------------------------------------
        // LuaSkin — Lua 5.4 + Objective-C bridge
        // ---------------------------------------------------------------
        .target(
            name: "LuaSkin",
            path: "LuaSkin/Sources/LuaSkin",
            exclude: ["Resources/luaskin.lua"],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_USE_APICHECK"),
                .define("LUA_COMPAT_5_3"),
                .headerSearchPath("include/LuaSkin"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        // ---------------------------------------------------------------
        // CocoaHTTPServer — vendored HTTP server library
        // ---------------------------------------------------------------
        .target(
            name: "CocoaHTTPServer",
            dependencies: [
                "CocoaAsyncSocket",
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
            ],
            path: "CocoaHTTPServer",
            exclude: ["LICENSE.txt"],
            sources: ["Core", "Extensions"],
            publicHeadersPath: "Core",
            cSettings: [
                .headerSearchPath("Core"),
                .headerSearchPath("Core/Categories"),
                .headerSearchPath("Core/Mime"),
                .headerSearchPath("Core/Responses"),
                .headerSearchPath("Extensions/WebDAV"),
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedLibrary("xml2"),
            ]
        ),
        // ---------------------------------------------------------------
        // HSExtensions — 90+ extensions + core app .m files
        // ---------------------------------------------------------------
        // SPM auto-discovers sources under HSExtensions/Sources/HSExtensions/
        // by following symlinks into extensions/<name>/ and Hammerspoon/.
        // Non-source files inside Hammerspoon/ (XIBs, plists, assets, etc.)
        // are individually excluded.  "ipc/cli" is the standalone hs CLI
        // (built by Packages/hs/).  "sqlite3/lsqlite3.c" is compiled as
        // Objective-C via lsqlite3_wrapper.m — excluding it avoids
        // duplicate symbols.
        .target(
            name: "HSExtensions",
            dependencies: [
                "LuaSkin",
                "CocoaHTTPServer",
                "CocoaAsyncSocket",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
            ],
            path: "HSExtensions/Sources/HSExtensions",
            exclude: [
                // Non-source files inside Hammerspoon/ that must not be
                // compiled or treated as SPM resources.
                "Hammerspoon/Build Configs",
                "Hammerspoon/ConsoleWindow.xib",
                "Hammerspoon/Credits.rtf",
                "Hammerspoon/Hammerspoon-Info.plist",
                "Hammerspoon/Hammerspoon-dev.entitlements",
                "Hammerspoon/Hammerspoon.entitlements",
                "Hammerspoon/Hammerspoon.sdef",
                "Hammerspoon/Images.xcassets",
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
