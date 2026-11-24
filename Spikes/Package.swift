// swift-tools-version: 6.2
// Phase 0 spikes: throwaway prototypes that answer feasibility questions.
import PackageDescription

let package = Package(
    name: "Spikes",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "NotchSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SpeechSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
