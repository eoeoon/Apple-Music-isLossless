// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "isLossless",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IsLosslessCore", targets: ["IsLosslessCore"]),
        .executable(name: "isLossless", targets: ["isLossless"])
    ],
    targets: [
        .target(name: "IsLosslessCore"),
        .executableTarget(
            name: "isLossless",
            dependencies: ["IsLosslessCore"]
        ),
        .testTarget(
            name: "IsLosslessCoreTests",
            dependencies: ["IsLosslessCore"]
        )
    ]
)
