// swift-tools-version:6.2
import PackageDescription

// Unified SPM package for Cosmic Hammer.
//
// Three internal targets compiled into one executable product:
//
//   LuaSkin          – Lua 5.4 runtime + Objective-C bridge
//   CocoaHTTPServer  – vendored HTTP server (used by hs.httpserver)
//   HSExtensions     – 90+ extensions + core app sources (contains main())
//
// The hs CLI (Packages/hs/) is a separate package built outside Xcode
// by `swift build --package-path Packages/hs` in the justfile.

let package = Package(
    name: "CosmicHammer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CosmicHammer", targets: ["HSApp"]),
        .library(name: "CosmicHammerLibs", type: .static, targets: ["HSExtensions", "HSSwiftExtensions"]),
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
        // by following symlinks into extensions/<name>/ and CosmicHammer/.
        // Non-source files inside CosmicHammer/ (XIBs, plists, assets, etc.)
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
                "HSSwiftExtensions",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
            ],
            path: "HSExtensions/Sources/HSExtensions",
            exclude: [
                // Non-source files inside CosmicHammer/ that must not be
                // compiled or treated as SPM resources.
                "CosmicHammer/Build Configs",
                "CosmicHammer/Credits.rtf",
                "CosmicHammer/CosmicHammer-Info.plist",
                "CosmicHammer/CosmicHammer-dev.entitlements",
                "CosmicHammer/CosmicHammer.entitlements",
                "CosmicHammer/CosmicHammer.icns",
                "CosmicHammer/CosmicHammer.sdef",
                "CosmicHammer/Spoon.icns",
                "CosmicHammer/setup.lua",
                "CosmicHammer/statusicon.pdf",
                // Other excludes carried forward from before.
                "ipc/cli",
                "sqlite3/lsqlite3.c",
                // Swift files must live in a separate target (SPM does
                // not support mixed ObjC + Swift in a single target).
                "streamdeck/libstreamdeck_new.swift",
                "streamdeck/NSImage+BMP.swift",
                "streamdeck/NSImage+Flipped.swift",
                "streamdeck/NSImage+JPEG.swift",
                "streamdeck/NSImage+Rotated.swift",
                "CosmicHammer/MJConsoleWindowController.swift",
                "CosmicHammer/HSAppleScript.swift",
                "CosmicHammer/HSuicore.swift",
                "CosmicHammer/HSGrowingTextField.swift",
                "CosmicHammer/MJAccessibilityUtils.swift",
                "CosmicHammer/MJAutoLaunch.swift",
                "CosmicHammer/MJFileUtils.swift",
                "CosmicHammer/MJVersionUtils.swift",
                "CosmicHammer/MJDockIcon.swift",
                "CosmicHammer/MJMenuIcon.swift",
                "CosmicHammer/MJPreferencesWindowController.swift",
                "CosmicHammer/MJUserNotificationManager.swift",
                "CosmicHammer/MJConfigUtils.swift",
                "CosmicHammer/MJAppDelegate.swift",
                "CosmicHammer/HSLogger.swift",
                "CosmicHammer/MJLua.swift",
                "osascript/NSAppleEventDescriptor+Parsing.swift",
                "hash/algorithms.swift",
                "base64/libbase64.swift",
                "math/libmath.swift",
                "plist/libplist.swift",
                "canvas/libcanvas_matrix.swift",
                "midi/libmidi.swift",
                "usb/libusb.swift",
                "json/libjson.swift",
                "crash/libcrash.swift",
                "settings/libsettings.swift",
                "host/locale/libhost_locale.swift",
                "milight/libmilight.swift",
                "osascript/libosascript.swift",
                "fs/libfs_xattr.swift",
                "distributednotifications/libdistributednotifications.swift",
                "battery/libbattery_watcher.swift",
                "dockicon/libdockicon.swift",
                "hotkey/libhotkey.swift",
                "sound/libsound.swift",
                "caffeinate/libcaffeinate_watcher.swift",
                "caffeinate/libcaffeinate.swift",
                "brightness/libbrightness.swift",
                "camera/libcamera.swift",
                "keycodes/libkeycodes.swift",
                "mouse/libmouse.swift",
                "pathwatcher/libpathwatcher.swift",
                "spaces/libspaces.swift",
                "spaces/libspaces_watcher.swift",
                "wifi/libwifi.swift",
                "timer/libtimer.swift",
                "dialog/libdialog.swift",
                "pasteboard/libpasteboard.swift",
                "task/libtask.swift",
                "urlevent/liburlevent.swift",
                "battery/libbattery.swift",
                "bonjour/libbonjoir.swift",
                "bonjour/libbonjour_service.swift",
                "console/libconsole.swift",
                "drawing/color/libdrawing_color.swift",
                "fs/libfs.swift",
                "fs/libfs_volume.swift",
                "host/libhost.swift",
                "http/libhttp.swift",
                "ipc/libipc.swift",
                "location/liblocation.swift",
                "network/libnetwork_configuration.swift",
                "network/libnetwork_host.swift",
                "network/libnetwork_reachability.swift",
                "notify/libnotify.swift",
                "pasteboard/libpasteboard_watcher.swift",
                "screen/libscreen.swift",
                "screen/libscreen_watcher.swift",
                "serial/libserial.swift",
                "sharing/libsharing.swift",
                "shortcuts/libshortcuts.swift",
                "socket/libsocket.swift",
                "socket/libsocket_udp.swift",
                "spotlight/libspotlight.swift",
                "usb/libusb_watcher.swift",
                "websocket/libwebsocket.swift",
                "wifi/libwifi_watcher.swift",
                "audiodevice/libaudiodevice.swift",
                "audiodevice/libaudiodevice_watcher.swift",
                "menubar/libmenubar.swift",
                "application/libapplication.swift",
                "application/libapplication_watcher.swift",
                "axuielement/libaxuielement.swift",
                "axuielement/libaxuielement_new.swift",
                "uielement/libuielement.swift",
                "uielement/libuielement_watcher.swift",
                "window/libwindow.swift",
                "chooser/libchooser.swift",
                "chooser/libchooser_new.swift",
                "webview/libwebview.swift",
                "webview/libwebview_datastore.swift",
                "webview/libwebview_toolbar.swift",
                "webview/libwebview_usercontent.swift",
                "canvas/libcanvas.swift",
                "image/libimage.swift",
                "razer/librazer_new.swift",
                "styledtext/libstyledtext.swift",
                "speech/libspeech.swift",
                "speech/libspeech_listener.swift",
                "doc/libdoc.swift",
                "doc/markdown.swift",
                "hash/libhash.swift",
                "noises/libnoises.swift",
                "network/ping/libnetwork_ping.swift",
                "network/ping/SimplePing.swift",
                "eventtap/libeventtap.swift",
                "eventtap/libeventtap_event.swift",
                "httpserver/libhttpserver.swift",
                "httpserver/MYAnonymousIdentity.swift",
                "hid/libhid.swift",
                "hints/internal.swift",
                "location/EDSunriseSet.swift",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_COMPAT_5_3"),
                // Header search paths so #import "Foo.h" resolves for extensions
                // that include sibling files relatively or that share helper
                // headers under the main app source tree.
                .headerSearchPath("CosmicHammer"),
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
                // Private frameworks for brightness/screen/spaces extensions.
                // The framework search path is passed via -Xlinker in the
                // justfile build recipe so we don't hardcode the SDK path.
                .linkedFramework("SkyLight"),
                .linkedFramework("DisplayServices"),
                .linkedFramework("CoreDisplay"),
            ]
        ),
        // ---------------------------------------------------------------
        // HSSwiftExtensions — Swift sources that live alongside ObjC
        // extensions.  SPM requires a separate target for Swift because
        // it cannot compile mixed ObjC + Swift in one target.
        // ---------------------------------------------------------------
        .target(
            name: "HSSwiftExtensions",
            dependencies: [
                "LuaSkin",
                "CocoaHTTPServer",
                "CocoaAsyncSocket",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
                .product(name: "CocoaLumberjack", package: "CocoaLumberjack"),
            ],
            path: "HSSwiftExtensions/Sources/HSSwiftExtensions",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // ---------------------------------------------------------------
        // HSApp — thin executable wrapper.  main() lives here so
        // HSExtensions can be a regular .target (usable in both the
        // executable product and the CosmicHammerLibs library product).
        // ---------------------------------------------------------------
        .executableTarget(
            name: "HSApp",
            dependencies: ["HSExtensions"],
            path: "HSApp/Sources/HSApp"
        ),
        // ---------------------------------------------------------------
        // CosmicHammerTests — Swift Testing suite for all Lua-bridged tests.
        // Uses MJLuaInitWithPaths to bootstrap a Lua state without the
        // full app, then delegates to the same Lua test functions the
        // old XCTest suite used.
        // ---------------------------------------------------------------
        .testTarget(
            name: "CosmicHammerTests",
            dependencies: ["HSExtensions", "HSSwiftExtensions", "LuaSkin"],
            path: "CosmicHammerTests",
            exclude: ["lsunit.lua", "testinit.lua"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
