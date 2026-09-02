// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode: this app crosses many non-Sendable AppKit/CoreAudio
// boundaries (CGEventTap C callback, AVAudioEngine tap block, Process
// termination handler). Fighting Swift 6 strict concurrency there buys
// nothing for a single-process menu-bar app, so opt the whole target back to
// Swift 5 checking instead of sprinkling @unchecked Sendable everywhere.
let package = Package(
    name: "OpenVox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenVox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
