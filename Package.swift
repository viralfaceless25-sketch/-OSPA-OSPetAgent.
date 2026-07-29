// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AvatarCompanion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AvatarCore", targets: ["AvatarCore"]),
        .executable(name: "AvatarCompanion", targets: ["AvatarCompanion"])
    ],
    targets: [
        .target(name: "AvatarCore"),
        .executableTarget(
            name: "AvatarCompanion",
            dependencies: ["AvatarCore"]
        ),
        .testTarget(
            name: "AvatarCoreTests",
            dependencies: ["AvatarCore"]
        )
    ]
)
