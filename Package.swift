// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RaindropShot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RaindropShot", targets: ["RaindropShot"]),
        .executable(name: "RaindropShotWorker", targets: ["RaindropShotWorker"]),
    ],
    targets: [
        // All logic that matters lives here. Foundation + Security only — no AppKit,
        // so the worker never pays for UI frameworks.
        .target(name: "RaindropShotCore"),

        // One-shot background worker launched by launchd. Does one pass and exits.
        .executableTarget(name: "RaindropShotWorker", dependencies: ["RaindropShotCore"]),

        // Optional menu bar controller + settings. Quitting it never stops uploads.
        .executableTarget(name: "RaindropShot", dependencies: ["RaindropShotCore"]),

        .testTarget(name: "RaindropShotCoreTests", dependencies: ["RaindropShotCore"]),
    ]
)
