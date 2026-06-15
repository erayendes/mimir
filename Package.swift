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
    ],
    targets: [
        .executableTarget(
            name: "Mimir",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
