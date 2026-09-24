// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scivane",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "Scivane",
            path: "Sources/Scivane",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
