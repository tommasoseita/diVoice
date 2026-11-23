// swift-tools-version: 6.0
import PackageDescription

// Sparkle 2.10.1 as a local xcframework, downloaded and verified by scripts/fetch-sparkle.sh
// (build-app.sh and test-app.sh run it on their own if it is missing).
let appDependencies: [Target.Dependency] = ["DiVoiceCore", "DiVoiceEngine", "DiVoiceKit", "DiVoiceObjC", "Sparkle"]
let appLinker: [LinkerSetting] = [
  .linkedFramework("AppKit"),
  .linkedFramework("AVFoundation"),
  .linkedFramework("ApplicationServices"),
  .linkedFramework("Carbon"),
  .linkedFramework("CoreAudio"),
  .linkedFramework("ServiceManagement"),
  // Sparkle.framework lives in DiVoice.app/Contents/Frameworks.
  .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]

let package = Package(
  name: "DiVoice",
  platforms: [.macOS(.v14)],
  targets: [
    // Pure, testable logic: hotkeys, PCM audio, protocol, timing, spacing.
    .target(name: "DiVoiceCore", path: "Sources/DiVoiceCore"),
    // AI pipeline (transcription, cleanup, Scribe) and Mistral/OpenAI providers: Foundation only, testable.
    .target(name: "DiVoiceEngine", dependencies: ["DiVoiceCore"], path: "Sources/DiVoiceEngine"),
    // AppKit components testable without the app (main menu, ...).
    .target(name: "DiVoiceKit", path: "Sources/DiVoiceKit", linkerSettings: [.linkedFramework("AppKit")]),
    // Objective-C exceptions from AVAudioEngine, caught instead of quitting the app.
    .target(name: "DiVoiceObjC", path: "Sources/DiVoiceObjC"),
    // AppKit/SwiftUI app. Swift 5 mode to coexist with the C callbacks of
    // CGEventTap, Core Audio and Accessibility without concurrency annotations everywhere.
    .executableTarget(
      name: "DiVoice",
      dependencies: appDependencies,
      path: "Sources/DiVoice",
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: appLinker
    ),
    // Latency and accuracy bench with the same engine (scripts/bench.sh).
    .executableTarget(name: "DiVoiceBench", dependencies: ["DiVoiceCore", "DiVoiceEngine"], path: "Sources/DiVoiceBench"),
    .testTarget(name: "DiVoiceCoreTests", dependencies: ["DiVoiceCore"], path: "Tests/DiVoiceCoreTests"),
    .testTarget(name: "DiVoiceBenchTests", dependencies: ["DiVoiceBench"], path: "Tests/DiVoiceBenchTests"),
    .testTarget(name: "DiVoiceEngineTests", dependencies: ["DiVoiceEngine"], path: "Tests/DiVoiceEngineTests"),
    .testTarget(name: "DiVoiceKitTests", dependencies: ["DiVoiceKit"], path: "Tests/DiVoiceKitTests"),
    .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),
  ]
)
