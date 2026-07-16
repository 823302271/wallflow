// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Wallflow",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Wallflow",
            resources: [.process("Resources")]
        )
    ]
)
