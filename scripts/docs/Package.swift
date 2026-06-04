// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BuildDocs",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "BuildDocsCore",
            path: "Sources/BuildDocsCore"
        ),
        .executableTarget(
            name: "BuildDocs",
            dependencies: [
                "BuildDocsCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BuildDocs"
        ),
        .testTarget(
            name: "BuildDocsTests",
            dependencies: ["BuildDocsCore"],
            path: "Tests/BuildDocsTests",
            exclude: ["Fixtures"]
        ),
    ]
)
