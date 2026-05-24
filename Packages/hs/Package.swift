// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "hs",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "hs", targets: ["hs"]),
    ],
    targets: [
        .systemLibrary(
            name: "CEditline",
            path: "Sources/CEditline"
        ),
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
    ]
)
