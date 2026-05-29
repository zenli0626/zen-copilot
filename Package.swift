// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchPilot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "NotchPilot",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ]
        )
    ]
)
