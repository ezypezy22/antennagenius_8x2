// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AntennaGenius",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AntennaGenius",
            path: "Sources/AntennaGenius",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AntennaGeniusTests",
            dependencies: ["AntennaGenius"],
            path: "Tests/AntennaGeniusTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
