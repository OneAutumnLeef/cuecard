// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchPrompter",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotchPrompter", targets: ["NotchPrompter"]),
        .executable(name: "prompter-bench", targets: ["PrompterBench"]),
    ],
    targets: [
        // Pure logic: script parsing, pacing, line layout, settings. No AppKit, fully unit-tested.
        .target(name: "PrompterCore"),
        // Microphone / file audio → Apple's on-device SpeechAnalyzer → heard text and levels.
        .target(name: "PrompterSpeech", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Replays recordings through the real recogniser and scores the voice tracker.
        .executableTarget(
            name: "PrompterBench",
            dependencies: ["PrompterCore", "PrompterSpeech"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app: notch panel, menus, hotkeys, editor and settings windows.
        .executableTarget(
            name: "NotchPrompter",
            dependencies: ["PrompterCore", "PrompterSpeech"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore"]),
    ]
)
