// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcmonad-core",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mcmonad-core",
            path: "Sources/MCMonadCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
