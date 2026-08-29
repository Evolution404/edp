// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EDPCore",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "EDPCore", type: .static, targets: ["EDPCore"]),
        .executable(name: "edp-core-bench", targets: ["EDPCoreBench"]),
    ],
    targets: [
        .target(
            name: "CEDPCore",
            publicHeadersPath: "include"
        ),
        .target(
            name: "EDPCore",
            dependencies: ["CEDPCore"]
        ),
        .executableTarget(
            name: "EDPCoreBench",
            dependencies: ["EDPCore"]
        ),
        .testTarget(
            name: "EDPCoreTests",
            dependencies: ["EDPCore"]
        ),
    ]
)
