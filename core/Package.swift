// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcmonad-core",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mcmonad-core",
            path: "Sources/MCMonadCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                // Embed an Info.plist into the bare binary's __TEXT,__info_plist
                // section. mcmonad-core is exec'd directly by the launcher (not
                // via `open MCMonad.app`), so macOS does NOT associate it with
                // the bundle's Info.plist — without this the daemon carries no
                // NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription
                // and TCC denies mic/speech without ever prompting. Path is
                // relative to the package root (the swift-build CWD).
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks", "-framework", "SkyLight",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MCMonadCore/Resources/Info.plist",
                ])
            ]
        )
    ]
)
