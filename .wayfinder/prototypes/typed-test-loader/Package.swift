// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TypedTestLoaderPrototype",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/tomsci/LuaSwift.git", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "TypedTestLoaderPrototype",
            dependencies: [.product(name: "Lua", package: "LuaSwift")],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("PROTOTYPE_DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-dead_strip"],
                    .when(platforms: [.macOS], configuration: .release)
                ),
            ]
        ),
    ]
)
