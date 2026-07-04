// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ICloudGuard",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ICloudGuardCore", targets: ["ICloudGuardCore"]),
        .executable(name: "ICloudGuard", targets: ["ICloudGuardApp"]),
    ],
    targets: [
        .target(
            name: "ICloudGuardCore"
        ),
        .executableTarget(
            name: "ICloudGuardApp",
            dependencies: ["ICloudGuardCore"],
        ),
        .testTarget(
            name: "ICloudGuardCoreTests",
            dependencies: ["ICloudGuardCore"]
        ),
    ]
)
