// swift-tools-version:6.2
import PackageDescription

// Unified SPM package for Cosmic Hammer.
//
// All source lives under Sources/<TargetName>/:
//
//   LuaSkin            – Lua 5.4 runtime + Objective-C bridge
//   CocoaHTTPServer    – vendored HTTP server (used by hs.httpserver)
//   HSExtensions       – ObjC/C/C++ extension code + core app headers
//   HSSwiftExtensions  – Swift extension code + core app Swift sources
//   HSApp              – thin executable wrapper (main.swift)
//   CEditline          – system library for the hs CLI
//   hs                 – standalone hs CLI tool
//
// Tests live under Tests/CosmicHammerTests/.
//
// Lua files remain in extensions/ (copied to the app bundle at build time).
// App resources (plists, icons) remain in CosmicHammer/.

let package = Package(
    name: "CosmicHammer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CosmicHammer", targets: ["HSApp"]),
        .library(name: "CosmicHammerLibs", type: .static, targets: ["HSExtensions", "HSSwiftExtensions"]),
        .executable(name: "hs", targets: ["hs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", exact: "7.6.5"),
        .package(url: "https://github.com/armadsen/ORSSerialPort", exact: "2.1.0"),
    ],
    targets: [
        // ---------------------------------------------------------------
        // LuaSkin — Lua 5.4 + Objective-C bridge
        // ---------------------------------------------------------------
        .target(
            name: "LuaSkin",
            path: "Sources/LuaSkin",
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
            ],
            path: "Sources/CocoaHTTPServer",
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
        // HSExtensions — ObjC/C/C++ extension sources + core app headers
        // ---------------------------------------------------------------
        .target(
            name: "HSExtensions",
            dependencies: [
                "LuaSkin",
                "CocoaHTTPServer",
                "CocoaAsyncSocket",
                "HSSwiftExtensions",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
            ],
            path: "Sources/HSExtensions",
            exclude: [
                "sqlite3/lsqlite3.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_COMPAT_5_3"),
                .headerSearchPath("CosmicHammer"),
                .headerSearchPath("doc"),
                .headerSearchPath("eventtap"),
                .headerSearchPath("fs"),
                .headerSearchPath("noises"),
            ],
            cxxSettings: [
                .define("LUA_USE_MACOSX"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-ObjC", "-Xlinker", "-all_load"]),
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
                .linkedFramework("SkyLight"),
                .linkedFramework("DisplayServices"),
                .linkedFramework("CoreDisplay"),
            ]
        ),
        // ---------------------------------------------------------------
        // HSSwiftExtensions — Swift extension + core app Swift sources
        // ---------------------------------------------------------------
        .target(
            name: "HSSwiftExtensions",
            dependencies: [
                "LuaSkin",
                "CocoaHTTPServer",
                "CocoaAsyncSocket",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
            ],
            path: "Sources/HSSwiftExtensions",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // ---------------------------------------------------------------
        // HSApp — thin executable wrapper
        // ---------------------------------------------------------------
        .executableTarget(
            name: "HSApp",
            dependencies: ["HSExtensions"],
            path: "Sources/HSApp"
        ),
        // ---------------------------------------------------------------
        // CEditline — system library for the hs CLI
        // ---------------------------------------------------------------
        .systemLibrary(
            name: "CEditline",
            path: "Sources/CEditline"
        ),
        // ---------------------------------------------------------------
        // hs — standalone command-line tool
        // ---------------------------------------------------------------
        .executableTarget(
            name: "hs",
            dependencies: ["CEditline"],
            path: "Sources/hs",
            exclude: ["hs.man", "hs.m"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("edit"),
            ]
        ),
        // ---------------------------------------------------------------
        // CosmicHammerTests — Swift Testing suite
        // ---------------------------------------------------------------
        .testTarget(
            name: "CosmicHammerTests",
            dependencies: ["HSExtensions", "HSSwiftExtensions", "LuaSkin"],
            path: "Tests/CosmicHammerTests",
            exclude: ["lsunit.lua", "testinit.lua"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
