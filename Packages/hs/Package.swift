// swift-tools-version:6.2
import PackageDescription

// The `hs` command-line tool. A self-contained Objective-C executable that
// talks to a running Hammerspoon.app via CFMessagePort. It has no LuaSkin
// dependency.
//
// The source-of-truth lives at extensions/ipc/cli/hs.m. Sources/hs is a
// symlink to that directory (same pattern as Packages/HSExtensions) so SPM
// (which forbids `..` in source paths) can compile it in place.

let package = Package(
    name: "hs",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "hs", targets: ["hs"]),
    ],
    targets: [
        .executableTarget(
            name: "hs",
            path: "Sources/hs",
            exclude: ["hs.man"],
            sources: ["hs.m"],
            cSettings: [
                .unsafeFlags([
                    "-Wno-everything",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("edit"),
            ]
        ),
    ]
)
