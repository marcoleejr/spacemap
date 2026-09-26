// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceMap",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaceMapCore", targets: ["SpaceMapCore"]),
        .executable(name: "SpaceMap", targets: ["SpaceMap"]),
        .executable(name: "spacemap-bench", targets: ["SpaceMapBench"])
    ],
    targets: [
        .target(name: "SpaceMapCore"),
        .executableTarget(
            name: "SpaceMap",
            dependencies: ["SpaceMapCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "SpaceMapBench", dependencies: ["SpaceMapCore"]),
        .testTarget(name: "SpaceMapCoreTests", dependencies: ["SpaceMapCore"])
    ],
    swiftLanguageModes: [.v5]
)
