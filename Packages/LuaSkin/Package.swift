// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LuaSkin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LuaSkin", targets: ["LuaSkin"]),
    ],
    targets: [
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
    ]
)
