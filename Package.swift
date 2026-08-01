// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AvatarCompanion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AvatarCore", targets: ["AvatarCore"]),
        .library(name: "AvatarPlatform", targets: ["AvatarPlatform"]),
        .executable(name: "AvatarCompanion", targets: ["AvatarCompanion"])
    ],
    targets: [
        .target(name: "AvatarCore"),
        .target(
            name: "AvatarPlatform",
            dependencies: ["AvatarCore"]
        ),
        .executableTarget(
            name: "AvatarCompanion",
            dependencies: ["AvatarCore", "AvatarPlatform"]
        ),
        .testTarget(
            name: "AvatarCoreTests",
            dependencies: ["AvatarCore"]
        ),
        .testTarget(
            name: "AvatarPlatformTests",
            dependencies: ["AvatarCore", "AvatarPlatform"]
        ),
        .testTarget(
            name: "AvatarCompanionTests",
            dependencies: ["AvatarCompanion", "AvatarCore", "AvatarPlatform"]
        )
    ]
)
