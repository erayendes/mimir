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
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.16.1"),
    ],
    targets: [
        .executableTarget(
            name: "Mimir",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
