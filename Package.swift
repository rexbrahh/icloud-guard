// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ICloudGuard",
    platforms: [
        .macOS("15.0"),
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
            exclude: ["Resources"]
        ),
        .target(
            name: "ICloudGuardCLIKit",
            dependencies: [
                "ICloudGuardCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ICloudGuardCLI",
            dependencies: [
                "ICloudGuardApp",
                "ICloudGuardCLIKit",
            ]
        ),
        .testTarget(
            name: "ICloudGuardCoreTests",
            dependencies: ["ICloudGuardCore", "ICloudGuardApp", "ICloudGuardCLIKit"],
            resources: [.process("Fixtures")]
        ),
    ]
)
