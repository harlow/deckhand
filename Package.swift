// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Deckhand",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "deckhand", targets: ["deckhand"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // SQLCipher from Homebrew (`brew install sqlcipher`).
        .systemLibrary(
            name: "CSQLCipher",
            pkgConfig: "sqlcipher",
            providers: [.brew(["sqlcipher"])]
        ),
        .target(name: "DeckhandCore"),
        .target(
            name: "OneLibrary",
            dependencies: ["DeckhandCore", "CSQLCipher"]
        ),
        // Vendored qm-dsp (GPL) for beat tracking and key detection.
        .target(
            name: "CQMDSP",
            exclude: ["COPYING", "qm-dsp-revision.txt", "qm-dsp/ext/kissfft/COPYING"],
            cSettings: [
                .headerSearchPath("qm-dsp"),
                .headerSearchPath("qm-dsp/ext/kissfft"),
                .headerSearchPath("qm-dsp/ext/kissfft/tools"),
                .define("kiss_fft_scalar", to: "double"),
                .unsafeFlags(["-O3", "-w"]),
            ],
            cxxSettings: [
                .headerSearchPath("qm-dsp"),
                .headerSearchPath("qm-dsp/ext/kissfft"),
                .headerSearchPath("qm-dsp/ext/kissfft/tools"),
                .define("kiss_fft_scalar", to: "double"),
                .unsafeFlags(["-O3", "-w"]),
            ]
        ),
        // Vendored libKeyFinder (GPL) for key detection, with an Accelerate FFT backend.
        .target(
            name: "CKeyFinder",
            exclude: ["LICENSE", "libkeyfinder-revision.txt"],
            cxxSettings: [
                .headerSearchPath("libkeyfinder"),
                .unsafeFlags(["-O3", "-w"]),
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "Analysis",
            dependencies: ["DeckhandCore", "CQMDSP", "CKeyFinder"],
            resources: [.copy("Resources/SKeyChromaNet.mlmodelc")]
        ),
        // Evaluation-only readers for reference labels (Mixed In Key's database, file tags).
        // Only the deckhand-*-eval tools depend on this; sync and the app never do.
        .target(
            name: "EvalSupport",
            dependencies: ["DeckhandCore", "CSQLCipher"]
        ),
        .executableTarget(
            name: "deckhand-eval",
            dependencies: ["Analysis", "CKeyFinder", "EvalSupport"]
        ),
        .executableTarget(
            name: "deckhand-cue-eval",
            dependencies: ["Analysis", "EvalSupport"]
        ),
        .executableTarget(
            name: "deckhand-structure-eval",
            dependencies: ["Analysis", "EvalSupport"]
        ),
        .executableTarget(
            name: "deckhand-grid-eval",
            dependencies: ["Analysis"]
        ),
        .target(
            name: "MusicSource",
            dependencies: ["DeckhandCore"]
        ),
        .target(
            name: "Sync",
            dependencies: ["DeckhandCore", "OneLibrary", "Analysis", "MusicSource"]
        ),
        .executableTarget(
            name: "deckhand",
            dependencies: [
                "Sync",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The app's state logic that doesn't need a UI: sync status from the engine, Music's serial event queue,
        // overlays and result parsing. Tested by DeckhandAppCoreTests.
        .target(
            name: "DeckhandAppCore",
            dependencies: ["Sync", "MusicSource", "DeckhandCore"]
        ),
        // Native Mac app (SwiftUI). `Scripts/build-app.sh` bundles it as Deckhand.app.
        .executableTarget(
            name: "DeckhandApp",
            dependencies: ["Sync", "DeckhandAppCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "OneLibraryTests", dependencies: ["OneLibrary"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "DeckhandAppCore", "MusicSource"]),
        .testTarget(name: "EvalSupportTests", dependencies: ["EvalSupport"]),
        .testTarget(name: "DeckhandAppTests", dependencies: ["DeckhandApp"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeckhandAppCoreTests", dependencies: ["DeckhandAppCore", "Sync", "MusicSource"]),
    ]
)
