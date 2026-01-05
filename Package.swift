// swift-tools-version: 5.9
// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import PackageDescription

let package = Package(
    name: "KQueue",
    // Apple platforms minimum versions (FreeBSD also supported)
    platforms: [
        .macOS("15.0"),
        .iOS("18.0"),
        .tvOS("18.0"),
        .watchOS("11.0"),
        .visionOS("2.0")
    ],
    products: [
        .library(
            name: "KQueue",
            targets: ["KQueue"]
        )
    ],
    targets: [
        .target(name: "KQueue"),
        .testTarget(
            name: "KQueueTests",
            dependencies: ["KQueue"]
        )
    ]
)
