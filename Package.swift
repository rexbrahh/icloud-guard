// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ICloudGuard",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ICloudGuardCore", targets: ["ICloudGuardCore"]),
        .executable(name: "icloud-guard", targets: ["ICloudGuardCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ICloudGuardCore"
        ),
        .target(
            name: "ICloudGuardApp",
            dependencies: ["ICloudGuardCore"],
        ),
        .executableTarget(
            name: "ICloudGuardCLI",
            dependencies: [
                "ICloudGuardCore",
                "ICloudGuardApp",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
        ),
        .testTarget(
            name: "ICloudGuardCoreTests",
            dependencies: ["ICloudGuardCore"]
        ),
    ]
)
