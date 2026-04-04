// swift-tools-version: 6.2

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "GhostOS",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "GhostOS", targets: ["GhostOS"]),
        .executable(name: "ghost", targets: ["ghost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/AXorcist.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "GhostOS",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
            ],
            path: "Sources/GhostOS",
            swiftSettings: concurrencySettings,
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .executableTarget(
            name: "ghost",
            dependencies: ["GhostOS"],
            path: "Sources/ghost",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "GhostOSTests",
            dependencies: ["GhostOS"],
            path: "Tests/GhostOSTests",
            swiftSettings: concurrencySettings + [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xfrontend", "-disable-cross-import-overlays",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
