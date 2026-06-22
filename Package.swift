// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Mimir",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mimir", targets: ["Mimir"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.17.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
    ],
    targets: [
        // Pure (Foundation/SwiftUI only) code shared verbatim with the widget extension — the
        // App Group bridge, status colours, and time formatting. The widget's Xcode project
        // compiles these same files by path, so there is one source of truth, no drift.
        .target(name: "MimirShared"),
        .executableTarget(
            name: "Mimir",
            dependencies: [
                "MimirShared",
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            exclude: [
                // Code-signing entitlements consumed by the build scripts / CI, not SwiftPM.
                "Mimir.dev.entitlements"
            ],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "MimirTests",
            dependencies: ["Mimir"]
        )
    ]
)
