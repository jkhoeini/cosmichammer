// swift-tools-version:5.9
import PackageDescription

// Sources are kept here in a flat list so the generator script and downstream
// scripts can edit them mechanically. Each entry is a path relative to
// Sources/HSExtensions/. Extension directories are symlinked into that folder
// so the source-of-truth remains under extensions/<name>/.
let extensionSourcePaths: [String] = [
    "HSExtensions.m",
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
                .unsafeFlags([
                    "-Wno-everything",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
