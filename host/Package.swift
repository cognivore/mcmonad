// swift-tools-version: 6.0
// AI-generated file: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
import PackageDescription

// Built by `cargo build --release -p awake_ffi`. Passed by path, so ld can never pick a dylib instead.
let rustLib = "\(Context.packageDirectory)/../target/release/libawake_ffi.a"

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    targets: [
        // Generated C half: header + module.modulemap.
        .systemLibrary(name: "awake_ffiFFI"),
        // Generated Swift half, Swift 5 mode: UniFFI 0.32's async callback glue fails Swift 6 checks.
        .target(
            name: "AwakeFFI",
            dependencies: ["awake_ffiFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags([rustLib])]
        ),
        // Hand-written, Swift 6: the macOS interpreter and the menu.
        .executableTarget(name: "Awake", dependencies: ["AwakeFFI"]),
    ]
)
