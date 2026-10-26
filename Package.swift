// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FishAi",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "FishAi",
            path: "Sources/FishAi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
