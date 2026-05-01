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
    targets: [
        .executableTarget(
            name: "Mimir",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
