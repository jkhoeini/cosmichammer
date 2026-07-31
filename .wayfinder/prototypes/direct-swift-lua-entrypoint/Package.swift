// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DirectSwiftLuaEntrypointPrototype",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/tomsci/LuaSwift.git", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "DirectSwiftLuaEntrypointPrototype",
            dependencies: [.product(name: "Lua", package: "LuaSwift")],
            path: "Sources",
            swiftSettings: [
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
