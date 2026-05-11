// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CocoaHTTPServer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CocoaHTTPServer", targets: ["CocoaHTTPServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", exact: "7.6.5"),
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack", exact: "3.9.0"),
    ],
    targets: [
        .target(
            name: "CocoaHTTPServer",
            dependencies: ["CocoaAsyncSocket", "CocoaLumberjack"],
            path: ".",
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
    ]
)
