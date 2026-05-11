// swift-tools-version:5.9
import PackageDescription

// Sources are kept here in a flat list so the generator script and downstream
// scripts can edit them mechanically. Each entry is a path relative to
// Sources/HSExtensions/. Extension directories are symlinked into that folder
// so the source-of-truth remains under extensions/<name>/.
let extensionSourcePaths: [String] = [
    "HSExtensions.m",
    "base64/libbase64.m",
    "math/libmath.m",
    "window/libwindow.m",
]

let package = Package(
    name: "HSExtensions",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HSExtensions", type: .static, targets: ["HSExtensions"]),
    ],
    dependencies: [
        .package(path: "../LuaSkin"),
    ],
    targets: [
        .target(
            name: "HSExtensions",
            dependencies: [
                "LuaSkin",
            ],
            path: "Sources/HSExtensions",
            sources: extensionSourcePaths,
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_COMPAT_5_3"),
                // Headers for HSuicore.h and other main-app headers referenced by extensions.
                .headerSearchPath("Hammerspoon"),
                .unsafeFlags([
                    "-Wno-everything",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
    ]
)
